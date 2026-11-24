import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле
#endif
import Combine

// MARK: - Политика автоподбора

/// Константы автоподбора и preflight-проверки HTML-плеера.
///
/// Вынесены из `SourceFallbackService` на уровень файла: класс помечен `@MainActor`,
/// а его статические свойства унаследовали бы изоляцию актора, и чистые функции для
/// XCTest (`looksLikeProviderError`, `candidateOrder`) не смогли бы их читать
/// из не-главного актора.
private enum SourceFallbackPolicy {

    /// Сколько альтернатив максимум проверяем за один подбор.
    ///
    /// Каждая альтернатива — это два запроса к API и один-два запроса к плееру,
    /// причём последовательно. Четыре кандидата хватает, чтобы пережить пару битых
    /// источников, и при этом не превращает отказ в долгий перебор.
    static let maxCandidates = 4

    /// Таймаут одного preflight-запроса к странице плеера — 12 с, как в контракте.
    ///
    /// Тот же таймаут ставится в `URLSessionConfiguration`, чтобы ограничение
    /// действовало и на запрос в целом, и на отдельную попытку.
    static let preflightTimeout: TimeInterval = 12

    /// Сколько тела ответа плеера читаем при preflight — 64 КБ.
    ///
    /// Для решения «это страница плеера или страница ошибки» хватает первых
    /// килобайтов; лимит защищает от того, чтобы случайно скачать в память
    /// весь файл, если сервер отдаст видео вместо HTML.
    static let preflightBodyByteLimit = 64 * 1024

    /// Мобильный Safari UA — с ним плееры отдают мобильную версию страницы.
    ///
    /// Тот же UA использует `SibnetResolver` для `shell.php`; в оригинальном
    /// приложении UA приходит с сервера, здесь — захардкоженная эвристика iOS-порта.
    static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    /// Маркеры страницы ошибки в теле ответа, уже в нижнем регистре.
    ///
    /// * `Error code` — заглушка плееров Anixart на пустую/битую ссылку;
    /// * «Извините, но данной странице не существует» — 404-страница прокси;
    /// * «не поддерживается» — провайдер не умеет отдавать эту серию.
    static let errorBodyMarkers = [
        "error code",
        "извините, но данной странице не существует",
        "не поддерживается"
    ]

    /// Подстрока, по которой отказ классифицируется как `.unsupported`, а не как
    /// общая ошибка страницы. Провайдер жив, но конкретный источник им не поддержан.
    static let unsupportedMarker = "не поддерживается"
}

// MARK: - Сервис

/// Автоматический подбор рабочего источника, когда основной не заработал.
///
/// Зачем отдельный сервис: `PlayerView` не должен знать ни про список источников
/// (`episode/{releaseId}/{typeId}`), ни про то, как проверять HTML-плеер. Экран
/// сообщает только «этот источник не открылся», а сервис последовательно пробует
/// остальные озвучки того же релиза и возвращает первую, которая действительно
/// отвечает страницей плеера или готовым потоком.
///
/// Почему проверка нужна: `PlaybackResolver.resolve(...)` разбирает ссылку по
/// формату, но ничего не знает о состоянии провайдера. Kodik с прямой ссылкой
/// отдаёт `500`, битая подпись — страницу «Error code», и всё это выясняется
/// только запросом. Поэтому для `.web` перед выдачей кандидата выполняется
/// preflight: GET с мобильным Safari UA и `Referer` из цели, таймаут 12 с,
/// чтение не больше 64 КБ. Ответ `>= 400` или страница ошибки — кандидат
/// отбрасывается и проверяется следующий источник.
///
/// Кандидаты проверяются последовательно, а не параллельно: это лишние запросы
/// к чужому API и чужим плеерам, а пользователю важен только первый рабочий.
///
/// Экземпляр один на приложение — `SourceFallbackService.shared`. Класс
/// `@MainActor`, как остальные сервисы плеера: `lastReason` читает UI, а результат
/// нужен на главном акторе. Сеть внутри — обычные `async`-вызовы `APIClient` и
/// `URLSession`, поэтому главный актор они не блокируют.
///
/// Причина последнего отказа складывается в `lastReason`: по ней экран может
/// показать подсказку (`lastReason.userHint`), если альтернатив не нашлось.
@MainActor
final class SourceFallbackService: ObservableObject {
    static let shared = SourceFallbackService()

    /// Почему последний автоподбор не дал результата.
    ///
    /// Обновляется на каждой неудачной попытке внутри `findWorkingAlternative(...)`
    /// и сбрасывается в `nil`, когда кандидат найден или подбор ещё не запускался.
    /// Если подходящих источников не оказалось вовсе (пустой список или все
    /// отфильтрованы), причину назвать нечем и `lastReason` остаётся `nil`.
    /// При вызове `probe(...)` напрямую это свойство не меняется.
    @Published private(set) var lastReason: PlaybackFallbackReason?

    private let api: APIClient

    /// Сессия preflight-запросов: без кэша и куки, свой таймаут.
    private let preflightSession: URLSession

    private init(api: APIClient = .shared) {
        self.api = api

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SourceFallbackPolicy.preflightTimeout
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        preflightSession = URLSession(configuration: configuration)
    }

    // MARK: - Автоподбор

    /// Найти первый рабочий источник того же релиза, кроме указанного.
    ///
    /// Порядок действий для каждого кандидата (последовательно):
    /// 1. `episode/target/...` — свежая подписанная ссылка серии. Ошибка API или
    ///    пустой `url` — следующий источник.
    /// 2. `PlaybackResolver.resolve(...)` — разбор ссылки по формату провайдера.
    /// 3. Для `.web` — preflight страницы: HTTP `>= 400` или страница ошибки
    ///    означает неработающего провайдера, иначе кандидат найден.
    ///    Для `.hls` и `.youtube` кандидат возвращается сразу: нативный резолвер
    ///    уже отработал, а прямому потоку preflight не нужен (иначе скачаем видео).
    ///
    /// - Parameters:
    ///   - releaseId: релиз, в котором ищем альтернативу.
    ///   - typeId: озвучка из `ReleaseViewModel.selectedTypeId`; в ней лежит список
    ///     источников (`episode/{releaseId}/{typeId}`).
    ///   - position: позиция текущей серии (нумерация Anixart с 1).
    ///   - sourceId: источник, который не сработал; из списка исключается.
    ///   - title: заголовок для экрана плеера (попадёт в `PlaybackTarget.title`).
    /// - Returns: первый работающий кандидат или `nil`, если рабочих альтернатив нет.
    ///   Причина отказа — в `lastReason`.
    func findWorkingAlternative(
        releaseId: Int,
        typeId: Int,
        position: Int,
        excluding sourceId: Int,
        title: String
    ) async -> PlaybackCandidate? {
        lastReason = nil

        let sources: [EpisodeSource]
        do {
            sources = try await api.episodeSources(releaseId: releaseId, typeId: typeId)
        } catch {
            // Даже список источников не загрузился — подбирать не из чего.
            lastReason = Self.reason(for: error)
            return nil
        }

        let ordered = Self.candidateOrder(
            sources: sources,
            excluding: sourceId,
            limit: SourceFallbackPolicy.maxCandidates
        )
        guard !ordered.isEmpty else { return nil }

        for source in ordered {
            if Task.isCancelled { return nil }

            // 1. Свежая подписанная ссылка именно этого источника.
            let episode: Episode
            do {
                episode = try await api.episodeTarget(
                    releaseId: releaseId,
                    sourceId: source.id,
                    position: position
                )
            } catch {
                lastReason = Self.reason(for: error)
                continue
            }

            let rawURL = episode.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawURL.isEmpty else {
                lastReason = .emptyURL
                continue
            }

            // 2. Разбор ссылки по формату провайдера.
            let target: PlaybackTarget
            do {
                target = try PlaybackResolver.resolve(
                    episode: episode,
                    sourceName: source.displayName,
                    title: title
                )
            } catch {
                lastReason = Self.reason(for: error)
                continue
            }

            // 3. Проверка: прямой поток и YouTube не проверяем запросом,
            //    HTML-страницу плеера — обязательно.
            switch target.kind {
            case .hls, .youtube:
                lastReason = nil
                return PlaybackCandidate(
                    sourceId: source.id,
                    sourceName: source.displayName,
                    target: target
                )
            case .web:
                switch await preflight(effectiveWebTarget(target)) {
                case .passed:
                    lastReason = nil
                    return PlaybackCandidate(
                        sourceId: source.id,
                        sourceName: source.displayName,
                        target: target
                    )
                case .failed(let reason):
                    lastReason = reason
                    continue
                }
            }
        }

        return nil
    }

    // MARK: - Публичная проверка

    /// Проверить, годится ли уже разобранная цель для воспроизведения.
    ///
    /// Публичный вариант preflight для тестов и повторного использования: экран
    /// может проверить основную цель (`probe`) и только при `false` звать
    /// `findWorkingAlternative(...)`.
    ///
    /// `.hls` и `.youtube` считаются рабочими без сетевого запроса: это готовый
    /// поток или встраивание, которое проверит `AVPlayer`/`WKWebView`. Для `.web`
    /// выполняется GET-проверка страницы (12 с, 64 КБ, мобильный Safari UA,
    /// `Referer` из цели).
    ///
    /// - Parameter target: цель, полученная из `PlaybackResolver`.
    /// - Returns: `true`, если страница плеера отвечает не ошибкой.
    func probe(_ target: PlaybackTarget) async -> Bool {
        switch await preflight(effectiveWebTarget(target)) {
        case .passed:
            return true
        case .failed:
            return false
        }
    }

    /// Для Kodik/Libria цель — страница-прокси `anixmirai.com/iframe?url=...`.
    /// Сама прокси-страница всегда отвечает 200, поэтому проверяем **исходную** ссылку
    /// плеера (её параметр `url`): Kodik на прямой запрос отдаёт 500.
    nonisolated func effectiveWebTarget(_ target: PlaybackTarget) -> PlaybackTarget {
        guard case .web(let proxyURL) = target.kind,
              proxyURL.host?.contains("anixmirai") == true,
              let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let original = URL(string: raw) else {
            return target
        }
        return PlaybackTarget(
            kind: .web(original),
            title: target.title,
            providerName: target.providerName,
            referer: target.referer
        )
    }

    // MARK: - Чистые функции

    /// Похож ли ответ плеера на страницу ошибки.
    ///
    /// Чистая функция без сети — её проверяют XCTest'ы (`PlaybackTests`).
    ///
    /// - Parameters:
    ///   - status: HTTP-статус ответа; любой `>= 400` уже ошибка (Kodik на прямой
    ///     запрос отдаёт `500`).
    ///   - body: прочитанное начало тела (до 64 КБ); регистр не важен.
    /// - Returns: `true`, если статус `>= 400` или в теле есть маркер ошибки
    ///   (`Error code`, «Извините, но данной странице не существует»,
    ///   «не поддерживается»).
    nonisolated static func looksLikeProviderError(status: Int, body: String) -> Bool {
        if status >= 400 { return true }

        let normalized = body.lowercased()
        return SourceFallbackPolicy.errorBodyMarkers.contains { normalized.contains($0) }
    }

    /// Порядок кандидатов на автоподбор: порядок сервера, без исключённого,
    /// не больше `limit`.
    ///
    /// Чистая функция без сети и без UI — её проверяют XCTest'ы. Порядок списка
    /// источников сохраняется: сервер уже сортирует озвучки по предпочтительности.
    ///
    /// - Parameters:
    ///   - sources: источники из `episodeSources(...)`.
    ///   - excluding: `id` источника, который не сработал; исключается из списка.
    ///   - limit: максимум кандидатов; `<= 0` даёт пустой список.
    /// - Returns: отфильтрованный список в исходном порядке.
    nonisolated static func candidateOrder(
        sources: [EpisodeSource],
        excluding: Int,
        limit: Int
    ) -> [EpisodeSource] {
        guard limit > 0 else { return [] }
        return Array(sources.lazy.filter { $0.id != excluding }.prefix(limit))
    }

    // MARK: - Preflight

    /// Итог проверки цели.
    private enum PreflightOutcome {
        /// Цель пригодна для показа.
        case passed
        /// Цель не пригодна; причина — для `lastReason`.
        case failed(PlaybackFallbackReason)
    }

    /// Проверка цели: `.hls`/`.youtube` — без запроса, `.web` — GET страницы плеера.
    private func preflight(_ target: PlaybackTarget) async -> PreflightOutcome {
        switch target.kind {
        case .hls, .youtube:
            return .passed
        case .web(let url):
            return await checkWebPage(
                url: url,
                referer: target.referer,
                providerName: target.providerName
            )
        }
    }

    /// GET страницы плеера: статус, затем первые 64 КБ тела на маркеры ошибки.
    ///
    /// Таймаут 12 с, мобильный Safari UA и `Referer` из цели — так открывается
    /// мобильная версия Kodik/Sibnet/AniLibria. На iOS тело читается потоково
    /// (`URLSession.bytes(for:)`) и обрывается на 64 КБ: если ссылка ведёт на
    /// видео, мы его не скачиваем. На Linux (только стаб-проверка CI) потокового
    /// API в corelibs нет, поэтому там тело ограничивается уже после `data(for:)`;
    /// в релизной сборке этот путь не используется.
    private func checkWebPage(
        url: URL,
        referer: URL?,
        providerName: String
    ) async -> PreflightOutcome {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: SourceFallbackPolicy.preflightTimeout
        )
        request.setValue(SourceFallbackPolicy.mobileSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        do {
            let status: Int
            let received: Data
            #if canImport(FoundationNetworking)
            // Linux: у corelibs-Foundation нет URLSession.bytes(for:).
            let (data, response) = try await preflightSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.resolutionFailed("Плеер ответил не по HTTP"))
            }
            status = http.statusCode
            received = data.prefix(SourceFallbackPolicy.preflightBodyByteLimit)
            #else
            let (bytes, response) = try await preflightSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.resolutionFailed("Плеер ответил не по HTTP"))
            }
            status = http.statusCode
            if status >= 400 {
                // Сразу отбрасываем страницу ошибки и не читаем её тело.
                return .failed(.providerHTTP(status))
            }

            var body = Data()
            body.reserveCapacity(SourceFallbackPolicy.preflightBodyByteLimit)
            for try await byte in bytes {
                body.append(byte)
                if body.count >= SourceFallbackPolicy.preflightBodyByteLimit { break }
            }
            received = body
            #endif

            // Проверка статуса общая: на iOS сюда попадаем уже после раннего
            // возврата выше, на Linux — это единственная проверка статуса.
            if status >= 400 {
                return .failed(.providerHTTP(status))
            }

            let text = String(decoding: received, as: UTF8.self)
            if Self.looksLikeProviderError(status: status, body: text) {
                return .failed(Self.reason(status: status, body: text, providerName: providerName))
            }
            return .passed
        } catch is CancellationError {
            return .failed(.resolutionFailed("Проверка плеера отменена"))
        } catch {
            // Нет сети, таймаут, DNS — провайдер для нас не работает.
            return .failed(.resolutionFailed(error.localizedDescription))
        }
    }

    // MARK: - Причины отказа

    /// Причина отказа по HTTP-статусу и началу тела ответа.
    ///
    /// Статус `>= 400` — `.providerHTTP`; маркер «не поддерживается» — `.unsupported`
    /// с именем плеера; остальные страницы ошибок — `.resolutionFailed`.
    private nonisolated static func reason(
        status: Int,
        body: String,
        providerName: String
    ) -> PlaybackFallbackReason {
        if status >= 400 { return .providerHTTP(status) }

        if body.lowercased().contains(SourceFallbackPolicy.unsupportedMarker) {
            return .unsupported(providerName)
        }
        return .resolutionFailed("Плеер «\(providerName)» вернул страницу ошибки")
    }

    /// Причина отказа по ошибке `APIClient`/`PlaybackResolver`.
    ///
    /// Ошибки разбора (`PlaybackError`) уже несут русский текст для UI, поэтому
    /// переносятся в `lastReason` без изменений. `APIError.empty` — это тот же
    /// пустой ответ, что и `.emptyURL`, остальные ошибки API — `.resolutionFailed`.
    private nonisolated static func reason(for error: Error) -> PlaybackFallbackReason {
        if let playbackError = error as? PlaybackError {
            switch playbackError {
            case .emptyURL:
                return .emptyURL
            case .unsupportedProvider(let name):
                return .unsupported(name)
            case .resolutionFailed(let text):
                return .resolutionFailed(text)
            case .playbackUnavailable:
                return .resolutionFailed(playbackError.localizedDescription)
            }
        }

        if let apiError = error as? APIError, apiError == .empty {
            return .emptyURL
        }

        return .resolutionFailed(error.localizedDescription)
    }
}
