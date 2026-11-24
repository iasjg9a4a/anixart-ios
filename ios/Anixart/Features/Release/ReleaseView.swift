import SwiftUI

/// Запрос на воспроизведение: подписанная ссылка на плеер, полученная с сервера.
///
/// `target` — уже разобранный `PlaybackTarget` (web/Kodik, HLS, YouTube), чтобы экран
/// плеера не повторял разбор. Остальные поля описывают серию: по ним `PlayerView`
/// сможет продолжить просмотр с сохранённого места и отметить серию просмотренной.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    /// Идентификатор релиза — ключ прогресса просмотра.
    let releaseId: Int?
    /// Идентификатор источника (озвучки): позиция серии уникальна только внутри него.
    let sourceId: Int?
    /// Позиция серии в источнике.
    let position: Int?
    /// Идентификатор озвучки (typeId) — нужен для «следующей серии».
    let typeId: Int?
    /// Имя провайдера («Kodik», «Sibnet», «YouTube»…) для подписи на экране плеера.
    let providerName: String?
    /// Готовый разбор ссылки; `nil` означает «разобрать по `url`» (старые вызовы).
    let target: PlaybackTarget

    init(
        url: URL,
        title: String,
        releaseId: Int? = nil,
        sourceId: Int? = nil,
        position: Int? = nil,
        typeId: Int? = nil,
        providerName: String? = nil,
        target: PlaybackTarget? = nil
    ) {
        self.url = url
        self.title = title
        self.releaseId = releaseId
        self.sourceId = sourceId
        self.position = position
        self.typeId = typeId
        self.providerName = providerName
        self.target = target ?? PlaybackResolver.fallbackTarget(for: url, title: title)
    }
}

/// Ошибка основного источника, после которой включается автоподбор.
///
/// Для «плеер не ответил» в `PlaybackError` нет подходящего случая, а менять
/// контракт чужого типа нельзя — поэтому локальная ошибка экрана релиза.
/// Её текст попадает в `errorMessage`, только если автоподбор не нашёл замену.
private enum ReleasePlaybackError: LocalizedError {
    case preflightFailed(String)

    var errorDescription: String? {
        switch self {
        case .preflightFailed(let providerName):
            return "Плеер \(providerName) не отвечает"
        }
    }
}

@MainActor
final class ReleaseViewModel: ObservableObject {
    let releaseId: Int

    @Published private(set) var release: Release?
    @Published private(set) var types: [EpisodeType] = []
    @Published private(set) var sources: [EpisodeSource] = []
    /// Источники, у которых сервер сообщает `episodes_count == 0`.
    ///
    /// `episode/{releaseId}/{typeId}` отдаёт их наравне с рабочими, но
    /// `episode/{releaseId}/{typeId}/{sourceId}` для них возвращает пустой список
    /// (например Sibnet у релиза 5). Поэтому в меню такие источники помечаются
    /// «(нет серий)» и уезжают в конец, а по умолчанию выбирается первый источник
    /// с сериями. Набор заполняется при загрузке источников и уточняется после
    /// загрузки серий: пустой список означает, что серий у источника нет.
    @Published private(set) var sourcesWithoutEpisodes: Set<Int> = []
    @Published private(set) var episodes: [Episode] = []

    /// Все источники релиза по озвучкам — данные экрана «Все источники».
    ///
    /// `episode/{releaseId}/{typeId}` отдаёт плееры только выбранной озвучки
    /// (у AniDUB — Kodik, у AniLibria — Libria), поэтому в секции «Серии»
    /// пользователь видит один-два плеера и решает, что других у релиза нет.
    /// Здесь — сводка по всем озвучкам: тип и его источники в порядке сервера.
    /// Заполняется фоном после первой загрузки (`loadAllSources`).
    @Published private(set) var allSourcesByType: [(type: EpisodeType, sources: [EpisodeSource])] = []
    /// Идёт загрузка сводки источников; страница релиза её не ждёт (грузим фоном).
    @Published private(set) var isLoadingAllSources = false

    /// Озвучки, для которых не удалось получить источники (диагностика + подсказка в шите).
    @Published private(set) var allSourceFailures: [String] = []

    @Published private(set) var selectedTypeId: Int?
    @Published private(set) var selectedSourceId: Int?

    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingEpisodes = false
    @Published private(set) var errorMessage: String?

    /// Уведомление автоподбора: «Источник X недоступен — включён Y».
    ///
    /// Показывается плашкой под блоками действий; `nil` — подмены не было либо
    /// пользователь уже закрыл плашку кнопкой «ОК».
    @Published var fallbackNotice: String?

    @Published var playback: PlaybackRequest?

    /// Серия, для которой сейчас идёт подготовка воспроизведения.
    ///
    /// Между тапом по серии и открытием плеера проходит от нескольких десятых
    /// секунды до нескольких секунд: `episode/target`, разбор ссылки, у Kodik
    /// ещё `ftor` и preflight страницы. Раньше интерфейс в это время молчал,
    /// и выглядело, будто тап не сработал. Теперь строка серии показывает
    /// индикатор, а повторные нажатия игнорируются (`play(_:)`).
    @Published private(set) var preparingEpisodePosition: Int?

    private let api = APIClient.shared

    init(releaseId: Int) {
        self.releaseId = releaseId
    }

    func load() async {
        if isLoading || release != nil { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let releaseTask = api.release(id: releaseId)
            async let typesTask = api.episodeTypes(releaseId: releaseId)

            let loadedRelease = try await releaseTask
            release = loadedRelease

            let loadedTypes = try await typesTask
            types = loadedTypes
            if let first = loadedTypes.first {
                await selectType(first)
            }

            // Сводку по всем озвучкам грузим фоном: экран не должен ждать до пяти
            // последовательных запросов, чтобы показать серии. Ошибки здесь не
            // всплывают — при неудаче строка «Источники» просто не появится.
            // В отладочном режиме CI-скриншотов не запускаем: маршрут сам вызовет
            // принудительную перезагрузку, а два параллельных обхода дерутся за API.
            if !ProcessInfo.processInfo.arguments.contains("-anixart-open-sources") {
                Task { await self.loadAllSources() }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectType(_ type: EpisodeType) async {
        guard selectedTypeId != type.id else { return }
        selectedTypeId = type.id
        // Плашка автоподбора относится к прошлой серии/озвучке — после смены типа она устарела.
        fallbackNotice = nil
        sources = []
        sourcesWithoutEpisodes = []
        episodes = []
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }

        do {
            let loaded = try await api.episodeSources(releaseId: releaseId, typeId: type.id)
            sources = loaded
            // `episodes_count == 0` — источник без серий: сервер предлагает его
            // в списке, но запрос серий по нему вернёт пустой список. Помечаем для меню.
            sourcesWithoutEpisodes = Set(loaded.filter { $0.episodesCount == 0 }.map(\.id))
            // По умолчанию — первый источник с сериями, а не просто первый в списке:
            // иначе сразу открывается заведомо пустой список (Sibnet и подобные).
            if let preferred = Self.defaultSource(from: loaded) {
                await selectSource(preferred)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSource(_ source: EpisodeSource) async {
        guard let typeId = selectedTypeId else { return }
        selectedSourceId = source.id
        // Новый выбор озвучки — прошлое уведомление о подмене источника больше не актуально.
        fallbackNotice = nil
        episodes = []
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }

        do {
            let loaded = try await api.episodes(releaseId: releaseId, typeId: typeId, sourceId: source.id)
            episodes = loaded
            // Уточняем пометку по факту: сервер может не прислать `episodes_count`
            // (`nil`), а пустой список однозначно говорит, что серий у источника нет.
            if loaded.isEmpty {
                sourcesWithoutEpisodes.insert(source.id)
            } else {
                sourcesWithoutEpisodes.remove(source.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Все источники релиза
    //
    // Источники привязаны к озвучке: запрос `episode/{releaseId}/{typeId}` отдаёт
    // плееры только выбранного типа, поэтому в секции «Серии» виден Kodik у AniDUB,
    // Libria у AniLibria и т.д. Сводка ниже собирает источники всех озвучек, чтобы
    // пользователь мог увидеть и выбрать любой плеер релиза (экран «Все источники»).

    /// Сколько озвучек максимум обходим: у релиза их обычно 1–4, дальше — шум.
    private static let maxAllSourcesTypes = 10

    /// Загрузить источники всех озвучек релиза.
    ///
    /// Запросы последовательные: сервер плохо переносит пачку параллельных
    /// `episode/…`, а скорость здесь не критична — сводка грузится фоном и
    /// рисуется только на отдельном экране. Ошибку одной озвучки пропускаем:
    /// остальные её источники всё равно должны быть видны.
    func loadAllSources() async {
        guard allSourcesByType.isEmpty, !isLoadingAllSources else { return }

        // Типы уже пришли в `load()` — второй раз не запрашиваем.
        if !types.isEmpty {
            await loadAllSources(types: types)
            return
        }

        do {
            let loadedTypes = try await api.episodeTypes(releaseId: releaseId)
            await loadAllSources(types: loadedTypes)
        } catch {
            // Без списка озвучек сводку не собрать: строка «Источники» останется скрытой.
        }
    }

    private func loadAllSources(types loadedTypes: [EpisodeType]) async {
        guard allSourcesByType.isEmpty, !isLoadingAllSources else { return }
        isLoadingAllSources = true
        defer { isLoadingAllSources = false }

        var result: [(type: EpisodeType, sources: [EpisodeSource])] = []
        for type in loadedTypes.prefix(Self.maxAllSourcesTypes) {
            guard let sources = try? await api.episodeSources(releaseId: releaseId, typeId: type.id) else {
                continue
            }
            result.append((type: type, sources: sources))
        }
        allSourcesByType = result
    }

    /// Принудительно перезагрузить сводку (кнопка «Обновить», отладочные маршруты CI).
    ///
    /// В отличие от `loadAllSources()` не отказывается от работы, если фоновая
    /// загрузка уже идёт: она могла стартовать раньше и закончиться не тем набором.
    func reloadAllSources() async {
        isLoadingAllSources = true
        defer { isLoadingAllSources = false }

        var loadedTypes = types
        if loadedTypes.isEmpty {
            loadedTypes = (try? await api.episodeTypes(releaseId: releaseId)) ?? []
        }
        guard !loadedTypes.isEmpty else {
            allSourcesByType = []
            return
        }

        var result: [(type: EpisodeType, sources: [EpisodeSource])] = []
        var failures: [String] = []
        for type in loadedTypes.prefix(Self.maxAllSourcesTypes) {
            var lastError: Error?
            var loaded: [EpisodeSource]?
            for attempt in 0..<3 {
                do {
                    loaded = try await api.episodeSources(releaseId: releaseId, typeId: type.id)
                    break
                } catch {
                    lastError = error
                    // Повтор после короткой паузы: сервер иногда сбоит на пачке запросов.
                    try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
                }
            }
            if let loaded {
                result.append((type: type, sources: loaded))
            } else if let lastError {
                failures.append("\(type.displayName): \(lastError.localizedDescription)")
            }
            // Сервер не любит пачку параллельных `episode/…` — держим маленькую паузу.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        allSourcesByType = result
        allSourceFailures = failures
    }

    /// Всего источников у релиза во всех озвучках.
    var allSourcesCount: Int {
        allSourcesByType.reduce(0) { total, group in total + group.sources.count }
    }

    /// Показывать ли строку «Источники»: при единственном источнике меню в секции
    /// «Серии» уже содержит всё нужное, а отдельный экран — лишний шум.
    var hasMultipleSources: Bool { allSourcesCount > 1 }

    /// Плееры одной строкой: «Kodik · Libria · Sibnet». Без иконок и карточек —
    /// чтобы прямо на странице релиза было видно, что плееров у релиза больше одного.
    var allSourcesSummary: String {
        var names: [String] = []
        for group in allSourcesByType {
            for source in group.sources where !names.contains(source.displayName) {
                names.append(source.displayName)
            }
        }
        return names.joined(separator: " · ")
    }

    // MARK: - Источники без серий

    /// Источники для меню: сначала с сериями, затем без; порядок сервера сохранён.
    ///
    /// Пустые источники остаются выбираемыми — просто в конце списка и с пометкой:
    /// пользователь должен видеть, что сервер их предлагает, но серий там нет.
    var menuSources: [EpisodeSource] {
        let available = sources.filter { !isSourceWithoutEpisodes($0) }
        let empty = sources.filter { isSourceWithoutEpisodes($0) }
        // Нативные плееры — первыми: они надёжнее web-плеера Kodik.
        let native = available.filter { Self.isNativeSource($0) }
        let rest = available.filter { !Self.isNativeSource($0) }
        return native + rest + empty
    }

    /// Помечен ли источник как «без серий» (`episodes_count == 0` или пустой ответ серий).
    func isSourceWithoutEpisodes(_ source: EpisodeSource) -> Bool {
        sourcesWithoutEpisodes.contains(source.id)
    }

    /// Подпись источника в меню: у пустых — пометка «(нет серий)».
    func menuTitle(for source: EpisodeSource) -> String {
        isSourceWithoutEpisodes(source)
            ? "\(source.displayName) (нет серий)"
            : source.displayName
    }

    /// Другой источник с сериями — на него предлагаем переключиться из пустого списка.
    ///
    /// `nil`, если рабочих альтернатив нет: тогда показываем только подсказку.
    var alternativeSourceWithEpisodes: EpisodeSource? {
        menuSources.first {
            $0.id != selectedSourceId
                && !isSourceWithoutEpisodes($0)
                && ($0.episodesCount ?? 0) > 0
        }
    }

    /// Плееры, которые играем нативно (AVPlayer/HLS) — их предпочитаем Kodik-WebView.
    private static let nativeProviderMarkers = ["libria", "liberty", "sibnet", "rutube", "tsm", "anixplayer", "anix player"]

    /// Провайдер требует WebView (Kodik и подобные) — нативный резолв для него не работает.
    private static func isWebOnlySource(_ source: EpisodeSource) -> Bool {
        let name = (source.name ?? "").lowercased()
        return name.contains("kodik")
    }

    /// Есть ли у источника известный нативный резолвер.
    private static func isNativeSource(_ source: EpisodeSource) -> Bool {
        let name = (source.name ?? "").lowercased()
        return nativeProviderMarkers.contains { name.contains($0) }
    }

    /// Источник по умолчанию: сначала нативный провайдер с сериями, затем любой с сериями,
    /// затем первый в списке. Kodik уходит в конец: web-плеер чаще ломается, а нативные
    /// источники (Libria/Sibnet/AnixPlayer) играются AVPlayer'ом.
    private static func defaultSource(from sources: [EpisodeSource]) -> EpisodeSource? {
        let playable = sources.filter { ($0.episodesCount ?? 0) > 0 }
        if let native = playable.first(where: { isNativeSource($0) }) {
            return native
        }
        if let nonWeb = playable.first(where: { !isWebOnlySource($0) }) {
            return nonWeb
        }
        return playable.first ?? sources.first
    }

    // MARK: - Воспроизведение и автоподбор источника
    //
    // Сначала пробуем выбранную озвучку. Если сервер не отдал ссылку, резолвер
    // упал или web-плеер Kodik не прошёл preflight — включаем автоподбор:
    // `SourceFallbackService` ищет следующую рабочую озвучку и отдаёт готовый
    // `PlaybackCandidate`. Плеер открывается сразу с неё, а под действиями
    // появляется плашка о подмене источника; ошибку в этом случае не показываем.
    // Если альтернативы нет — показываем основную ошибку с подсказкой.

    func play(_ episode: Episode) async {
        guard let sourceId = episode.sourceId ?? selectedSourceId else { return }
        // Пока готовится одна серия, повторные тапы (в том числе по другой
        // строке) ничего не делают: иначе два резолва гонялись бы за одним
        // `playback`, и открывалась бы «та, что успела».
        guard preparingEpisodePosition == nil else { return }
        errorMessage = nil
        fallbackNotice = nil
        preparingEpisodePosition = episode.position
        defer { preparingEpisodePosition = nil }

        let sourceName = sources.first(where: { $0.id == sourceId })?.displayName
        let title = "\(release?.displayTitle ?? "Просмотр") — \(episode.displayName)"

        do {
            let resolved = try await resolvePlaybackTarget(
                for: episode,
                sourceId: sourceId,
                sourceName: sourceName,
                title: title
            )
            playback = PlaybackRequest(
                url: resolved.url,
                title: title,
                releaseId: releaseId,
                sourceId: sourceId,
                position: episode.position,
                typeId: selectedTypeId,
                providerName: resolved.target.providerName,
                target: resolved.target
            )
        } catch {
            await openFallback(
                for: episode,
                failedSourceId: sourceId,
                failedSourceName: sourceName,
                title: title,
                primaryError: error.localizedDescription
            )
        }
    }

    /// Шаг 1: подписанная ссылка серии, её разбор и проверка web-плеера Kodik.
    ///
    /// Для Kodik сначала пробуется прямой резолв в HLS (`KodikDirectResolver`):
    /// подписанная страница через WebView-прокси отвечает «Error code: ds», а `ftor`
    /// отдаёт ссылки на CDN Kodik, которые играет нативный `AVPlayer`. Только если
    /// прямой путь не сложился, работает прежняя логика: preflight web-страницы
    /// и автоподбор другого источника.
    ///
    /// Бросает, если играть нечем: серия без ссылки, ошибка резолвера или
    /// Kodik, чья страница не отвечает на preflight. Ловится в `play(_:)` —
    /// оттуда управление уходит в автоподбор.
    private func resolvePlaybackTarget(
        for episode: Episode,
        sourceId: Int,
        sourceName: String?,
        title: String
    ) async throws -> (target: PlaybackTarget, url: URL) {
        let episodeTarget = try await api.episodeTarget(
            releaseId: releaseId,
            sourceId: sourceId,
            position: episode.position
        )
        let target = try PlaybackResolver.resolve(
            episode: episodeTarget,
            sourceName: sourceName,
            title: title
        )

        // Kodik: прямой резолв в HLS до WebView. Цель Kodik — это прокси
        // `anixmirai.com/iframe?url=…`; резолвер сам разворачивает его в страницу
        // Kodik, отбрасывает подпись и спрашивает `ftor` про ссылки на CDN.
        if case .web(let webURL) = target.kind,
           Self.isKodikProvider(target),
           let direct = await Self.kodikDirectTarget(webURL: webURL, title: title) {
            return direct
        }

        guard let url = PlaybackResolver.externalURL(for: target) else {
            throw PlaybackError.emptyURL
        }
        // Kodik играется в WebView и иногда отдаёт битую страницу: проверяем её
        // до показа плеера, чтобы не открывать заведомо нерабочий экран.
        if Self.isKodikProvider(target) {
            let isReachable = await SourceFallbackService.shared.probe(target)
            guard isReachable else {
                throw ReleasePlaybackError.preflightFailed(target.providerName)
            }
        }
        return (target, url)
    }

    /// Автоподбор: пробуем другую озвучку релиза и открываем плеер уже с неё.
    ///
    /// `failedSourceId` исключается из перебора: `SourceFallbackService` не должен
    /// вернуть тот же битый источник. `primaryError` нужен только на случай,
    /// когда альтернативы не нашлось, — тогда он уходит в `errorMessage`.
    private func openFallback(
        for episode: Episode,
        failedSourceId: Int,
        failedSourceName: String?,
        title: String,
        primaryError: String
    ) async {
        let candidate = await SourceFallbackService.shared.findWorkingAlternative(
            releaseId: releaseId,
            typeId: selectedTypeId ?? 0,
            position: episode.position,
            excluding: failedSourceId,
            title: episode.displayName
        )
        guard let candidate else {
            errorMessage = Self.fallbackFailureMessage(primaryError)
            return
        }
        var target = candidate.target
        var url = PlaybackResolver.externalURL(for: target)
        // Автоподбор может вернуть Kodik: web-страница через прокси обычно отвечает
        // «Error code: ds», поэтому пробуем тот же прямой HLS, что и в `play`.
        // Так у Kodik сохраняется и нативное воспроизведение, и меню качества.
        if case .web(let webURL) = target.kind,
           Self.isKodikProvider(target),
           let direct = await Self.kodikDirectTarget(webURL: webURL, title: title) {
            target = direct.target
            url = direct.url
        }
        guard let url else {
            errorMessage = Self.fallbackFailureMessage(primaryError)
            return
        }

        // Альтернатива нашлась — ошибку основного источника не показываем:
        // пользователь просто смотрит подобранную озвучку, а о подмене сообщит плашка.
        errorMessage = nil
        fallbackNotice = Self.fallbackNoticeText(
            failedSourceName: failedSourceName,
            candidate: candidate
        )
        playback = PlaybackRequest(
            url: url,
            title: title,
            releaseId: releaseId,
            sourceId: candidate.sourceId,
            position: episode.position,
            typeId: selectedTypeId,
            providerName: candidate.sourceName,
            target: target
        )
    }

    /// Kodik: прямой HLS-цель с вариантами качества для меню плеера.
    ///
    /// Общий путь для основного воспроизведения (`play` → `resolvePlaybackTarget`)
    /// и автоподбора (`openFallback`): в обоих случаях из подписанной страницы Kodik
    /// получаются ссылки `ftor` и строится цель, где текущий URL — лучшее качество,
    /// а `variants` — все качества по убыванию (`KodikDirectResolver.variants(for:)`).
    ///
    /// - Returns: `nil`, если прямой резолв Kodik не сложился — вызывающий остаётся
    ///   на прежнем пути (WebView-прокси / preflight / другая озвучка).
    private static func kodikDirectTarget(
        webURL: URL,
        title: String
    ) async -> (target: PlaybackTarget, url: URL)? {
        guard let direct = await KodikDirectResolver.resolve(embedURL: webURL) else {
            return nil
        }
        let variants = KodikDirectResolver.variants(for: direct)
        let target = PlaybackTarget(
            kind: .hls(direct.bestURL),
            title: title,
            providerName: KodikDirectResolver.providerName,
            referer: direct.pageURL,
            variants: variants.isEmpty ? nil : variants
        )
        return (target, direct.bestURL)
    }

    /// Kodik — единственный провайдер с сетевым preflight: он играется в WebView.
    static func isKodikProvider(_ target: PlaybackTarget) -> Bool {
        VideoProvider.detect(sourceName: target.providerName, url: nil) == .kodik
    }

    /// Текст ошибки, когда рабочего источника для автоподбора не нашлось.
    private static func fallbackFailureMessage(_ primaryError: String) -> String {
        let trimmed = primaryError.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPeriod = trimmed.hasSuffix(".")
            ? String(trimmed.dropLast())
            : trimmed
        let reason = withoutPeriod.isEmpty ? "Не удалось воспроизвести серию" : withoutPeriod
        return "\(reason). Попробуйте другую озвучку."
    }

    /// Текст плашки: какую озвучку заменили на какую.
    private static func fallbackNoticeText(
        failedSourceName: String?,
        candidate: PlaybackCandidate
    ) -> String {
        let failed = failedSourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !failed.isEmpty else {
            return "Источник недоступен — включён \(candidate.sourceName)"
        }
        return "Источник \(failed) недоступен — включён \(candidate.sourceName)"
    }

    // MARK: - Офлайн-скачивание
    //
    // Офлайн доступен только нативным HLS-источникам (`docs/OFFLINE.md`): AniLibria/Libria,
    // RuTube и AnixPlayer/StudioMir. Kodik отдаёт HTML-плеер, Sibnet — подписанный shell.php,
    // YouTube — встраивание: в `AVAssetDownloadTask` их не положить. Поэтому кнопку
    // показываем только для источников, которые умеют отдать прямой `.m3u8`.

    /// Поддерживает ли источник офлайн-скачивание (по имени источника из `episode/…`).
    ///
    /// Сравнение регистронезависимое и по подстроке: сервер называет одни и те же плееры
    /// по-разному — «Libria», «AniLibria», «Liberty», «AnixPlayer», «StudioMir», «TSM».
    static func supportsOfflineDownload(sourceName: String?) -> Bool {
        let name = (sourceName ?? "").lowercased()
        guard !name.isEmpty else { return false }
        return name.contains("libria")
            || name.contains("liberty")
            || name.contains("rutube")
            || name.contains("anixplayer")
            || name.contains("studiomir")
            || name.contains("tsm")
    }

    /// Имя выбранного источника: подпись в меню и признак офлайн-поддержки.
    var selectedSourceName: String {
        sources.first(where: { $0.id == selectedSourceId })?.displayName ?? "Источник"
    }

    /// Показывать ли в строках серий кнопку скачивания для выбранного источника.
    var selectedSourceSupportsDownload: Bool {
        Self.supportsOfflineDownload(sourceName: selectedSourceName)
    }

    /// Запись `DownloadManager` для серии (`nil` — серию ещё не ставили в загрузку).
    func downloadItem(for episode: Episode) -> DownloadItem? {
        guard let sourceId = episode.sourceId ?? selectedSourceId else { return nil }
        return DownloadManager.shared.items.first {
            $0.releaseId == releaseId && $0.sourceId == sourceId && $0.position == episode.position
        }
    }

    /// Скачать серию для офлайн-просмотра.
    ///
    /// Путь тот же, что у `play`: `episode/target` отдаёт подписанную страницу источника,
    /// резолвер превращает её в прямой HLS, и уже готовый `.m3u8` уходит в
    /// `DownloadManager` (он `@MainActor`, вызов из модели безопасен). Ошибки не бросаем,
    /// а кладём в `errorMessage` — как у остальных действий экрана.
    func download(_ episode: Episode) async {
        guard let sourceId = episode.sourceId ?? selectedSourceId else { return }
        let sourceName = sources.first(where: { $0.id == sourceId })?.displayName
        errorMessage = nil

        guard Self.supportsOfflineDownload(sourceName: sourceName) else {
            errorMessage = Self.unsupportedMessage(sourceName: sourceName)
            return
        }

        // Уже качается или готово — повторный тап не должен повторять резолв:
        // `beginDownload` всё равно проигнорирует такую запись.
        if let existing = downloadItem(for: episode) {
            switch existing.state {
            case .queued, .downloading, .completed:
                return
            case .failed:
                break   // провалившуюся загрузку перезапускаем
            }
        }

        do {
            let target = try await api.episodeTarget(
                releaseId: releaseId,
                sourceId: sourceId,
                position: episode.position
            )
            guard let raw = target.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let url = URL(string: raw) else {
                throw DownloadError.emptyURL
            }
            guard let provider = Self.offlineProvider(sourceName: sourceName, url: url) else {
                throw DownloadError.unsupportedProvider(sourceName ?? "источник")
            }

            let title = "\(release?.displayTitle ?? "Аниме") — \(episode.displayName)"
            let resolved: PlaybackTarget
            switch provider {
            case .libria:
                resolved = try await AniLibriaResolver.resolve(url: url, title: title)
            case .rutube:
                resolved = try await RutubeResolver.resolve(url: url, title: title)
            case .anixplayer:
                resolved = try await AnixPlayerResolver.resolve(url: url, title: title)
            default:
                throw DownloadError.unsupportedProvider(sourceName ?? "источник")
            }

            guard case .hls(let streamURL) = resolved.kind else {
                throw DownloadError.emptyURL
            }
            try DownloadManager.shared.beginDownload(
                releaseId: releaseId,
                sourceId: sourceId,
                position: episode.position,
                title: title,
                url: streamURL
            )
        } catch {
            errorMessage = Self.downloadMessage(for: error, sourceName: sourceName)
        }
    }

    /// Провайдер, ссылку которого умеет скачать `DownloadManager`; `nil` — офлайн нельзя.
    private static func offlineProvider(sourceName: String?, url: URL) -> VideoProvider? {
        let detected = VideoProvider.detect(sourceName: sourceName, url: url)
        switch detected {
        case .libria, .rutube, .anixplayer:
            return detected
        default:
            // «TSM» — нативный источник, но `detect` знает только AnixPlayer/StudioMir:
            // резолвер у них общий, поэтому имя источника решает.
            let name = (sourceName ?? "").lowercased()
            return name.contains("tsm") ? .anixplayer : nil
        }
    }

    /// Человеческий текст ошибки: `DownloadError` уже локализован, но для
    /// `.unsupportedProvider` вместо невнятного имени подставляем подсказку.
    private static func downloadMessage(for error: Error, sourceName: String?) -> String {
        if let downloadError = error as? DownloadError,
           case .unsupportedProvider(_) = downloadError {
            return unsupportedMessage(sourceName: sourceName)
        }
        return error.localizedDescription
    }

    private static func unsupportedMessage(sourceName: String?) -> String {
        let name = (sourceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = name.isEmpty ? "этого источника" : "источника «\(name)»"
        return "Офлайн-скачивание для \(subject) недоступно. "
            + "Скачать можно с AniLibria, RuTube или AnixPlayer."
    }

    // MARK: - Действия со списком, избранным и оценкой
    //
    // `release` — единственный источник правды для кнопок. После успешного запроса
    // правим её точечно (`updateRelease`), без перезагрузки всего экрана; ошибку
    // пробрасываем наверх — показывает её вьюха своим алертом.

    /// Голос пользователя: 0 — не голосовал.
    var vote: Int { release?.yourVote ?? 0 }

    /// Лежит ли релиз в избранном.
    var isFavorite: Bool { release?.isFavorite == true }

    /// Статус релиза в списке профиля (`nil` — не в списке или статус неизвестен).
    var listStatus: ProfileListStatus? {
        guard let raw = release?.profileListStatus else { return nil }
        return ProfileListStatus(rawValue: raw)
    }

    /// Добавить релиз в список профиля с выбранным статусом.
    func addToList(_ status: ProfileListStatus) async throws {
        try await api.addToList(releaseId: releaseId, status: status)
        updateRelease { $0.profileListStatus = status.rawValue }
    }

    /// Убрать релиз из текущего списка профиля.
    func removeFromList() async throws {
        guard let status = listStatus else { return }
        try await api.removeFromList(releaseId: releaseId, status: status)
        updateRelease { $0.profileListStatus = nil }
    }

    /// Переключить избранное.
    func toggleFavorite() async throws {
        if isFavorite {
            try await api.removeFromFavorites(releaseId: releaseId)
            updateRelease { $0.isFavorite = false }
        } else {
            try await api.addToFavorites(releaseId: releaseId)
            updateRelease { $0.isFavorite = true }
        }
    }

    /// Поставить оценку; повторный голос за ту же оценку отзывает его.
    func setVote(_ value: Int) async throws {
        if vote == value {
            try await api.deleteVote(releaseId: releaseId)
            updateRelease { $0.yourVote = 0 }
        } else {
            try await api.vote(releaseId: releaseId, vote: value)
            updateRelease { $0.yourVote = value }
        }
    }

    /// Точечное обновление уже загруженного релиза после успешного запроса.
    private func updateRelease(_ change: (inout Release) -> Void) {
        guard var updated = release else { return }
        change(&updated)
        release = updated
    }
}

struct ReleaseView: View {
    let releaseId: Int

    @EnvironmentObject private var session: Session
    @StateObject private var model: ReleaseViewModel
    /// Загрузки нужны только для иконок в строках серий, но прогресс меняется на ходу —
    /// поэтому вьюха подписана на менеджер и перерисовывает строки.
    @ObservedObject private var downloads = DownloadManager.shared

    @State private var showsAllComments = false
    /// Открыт экран «Все источники»: сводка плееров по всем озвучкам релиза.
    @State private var showsAllSources = false
    /// Видео с секции релиза: открывается тем же полноэкранным плеером, что и серии,
    /// но без контекста серии (`releaseId/sourceId/position` у видео нет).
    @State private var videoPlayback: VideoPlaybackPresentation?
    /// Ошибка последнего действия со списком/избранным/оценкой — показывается алертом.
    @State private var actionError: String?
    /// Пока изменяющий запрос в полёте, повторные нажатия блокируются.
    @State private var isPerformingAction = false

    init(releaseId: Int) {
        self.releaseId = releaseId
        _model = StateObject(wrappedValue: ReleaseViewModel(releaseId: releaseId))
    }

    var body: some View {
        ScrollView {
            content
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load()
            // Отладочный маршрут для CI-скриншотов: открыть сразу сводку источников.
            if ProcessInfo.processInfo.arguments.contains("-anixart-open-sources") {
                await model.reloadAllSources()
                await MainActor.run {
                    if !model.allSourcesByType.isEmpty {
                        showsAllSources = true
                    }
                }
            }
        }
        .fullScreenCover(item: $model.playback) { request in
            PlayerView(
                target: request.target,
                releaseId: request.releaseId,
                sourceId: request.sourceId,
                position: request.position,
                typeId: request.typeId,
                onClose: { model.playback = nil }
            )
        }
        // Видео релиза — тот же плеер, но без контекста серии.
        .fullScreenCover(item: $videoPlayback) { presentation in
            PlayerView(target: presentation.target, onClose: { videoPlayback = nil })
        }
        .sheet(isPresented: $showsAllComments) {
            CommentsView(releaseId: releaseId)
        }
        .sheet(isPresented: $showsAllSources) {
            AllSourcesView(
                sourcesByType: model.allSourcesByType,
                failures: model.allSourceFailures,
                isLoading: model.isLoadingAllSources,
                selectedTypeId: model.selectedTypeId,
                selectedSourceId: model.selectedSourceId,
                onPick: { type, source in
                    // Сначала закрываем шит, затем переключаем озвучку и источник:
                    // страница релиза сама перезагрузит серии под выбранный источник.
                    showsAllSources = false
                    Task { @MainActor in
                        await model.selectType(type)
                        await model.selectSource(source)
                    }
                }
            )
        }
        .alert("Ошибка", isPresented: isActionAlertPresented) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(actionError ?? "Не удалось выполнить действие")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let release = model.release {
            VStack(alignment: .leading, spacing: 0) {
                header(release)
                meta(release)
                actions(release)
                fallbackBanner
                genres(release)
                description(release)
                // Группируем доп. секции: у ViewBuilder лимит 10 детей на контейнер.
                Group {
                    ReleaseStreamingSourcesSection(releaseId: releaseId)
                    videosSection
                }
                commentsSection(release)
                // Группируем доп. секции: у ViewBuilder лимит 10 детей на контейнер.
                Group {
                    episodesSection
                    allSourcesSection
                }
                relatedSection(release)
            }
            .padding(.bottom, 32)
        } else if model.isLoading {
            LoadingView().frame(height: 400)
        } else if let message = model.errorMessage {
            ErrorStateView(message: message) {
                Task { await model.load() }
            }
            .frame(height: 400)
        }
    }

    private func header(_ release: Release) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urlString: release.image, contentMode: .fill)
                .frame(height: 300)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, Theme.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(release.displayTitle)
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !release.subtitle.isEmpty {
                    Text(release.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(16)
        }
        .frame(height: 300)
    }

    private func meta(_ release: Release) -> some View {
        HStack(spacing: 10) {
            StatBadge(value: release.gradeText, caption: "Рейтинг")
            StatBadge(value: "\(release.episodesTotal ?? 0)", caption: "Серий")
            StatBadge(value: "\(release.commentCount ?? 0)", caption: "Отзывов")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func genres(_ release: Release) -> some View {
        Group {
            if !release.genreList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(release.genreList, id: \.self) { genre in
                            ChipView(text: genre)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 14)
            }
        }
    }

    private func description(_ release: Release) -> some View {
        Group {
            if let text = release.summary, !text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Описание")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
        }
    }

    /// Секция видео релиза (трейлеры, опенинги, клипы).
    ///
    /// Загрузку, блоки по категориям и пустое состояние держит сама
    /// `ReleaseVideosSection`; экран только открывает плеер по выбранной вставке.
    private var videosSection: some View {
        ReleaseVideosSection(releaseId: releaseId) { video in
            presentVideo(video)
        }
    }

    /// Открыть видео в общем полноэкранном плеере.
    ///
    /// `playbackTarget` уже разобран моделью `ReleaseVideo`: YouTube — через iframe-API,
    /// VK/RuTube и прочие — через embed-страницу `player_url`. Если ссылку распознать
    /// нельзя, показываем ошибку тем же алертом, что и у действий.
    private func presentVideo(_ video: ReleaseVideo) {
        guard let target = video.playbackTarget else {
            actionError = "Не удалось открыть видео: ссылка не поддерживается"
            return
        }
        videoPlayback = VideoPlaybackPresentation(target: target)
    }

    private func commentsSection(_ release: Release) -> some View {
        Group {
            if let comments = release.comments, !comments.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Комментарии (\(release.commentCount ?? comments.count))")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)

                        Spacer(minLength: 8)

                        Button("Все") {
                            showsAllComments = true
                        }
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                    }

                    ForEach(comments.filter { $0.isVisible }) { comment in
                        if let authorId = comment.profile?.id {
                            NavigationLink {
                                UserProfileView(userId: authorId)
                            } label: {
                                CommentRow(comment: comment)
                            }
                            .buttonStyle(.plain)
                        } else {
                            CommentRow(comment: comment)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 22)
            }
        }
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Серии")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)

            if !model.types.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.types) { type in
                            Button {
                                Task { await model.selectType(type) }
                            } label: {
                                ChipView(text: type.displayName, selected: model.selectedTypeId == type.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            if !model.sources.isEmpty {
                Menu {
                    // Источники без серий — в конце и с пометкой «(нет серий)»,
                    // чтобы пользователь не выбирал их первыми.
                    ForEach(model.menuSources) { source in
                        Button(model.menuTitle(for: source)) {
                            Task { await model.selectSource(source) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.caption)
                        Text(model.selectedSourceName)
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                }
            }

            if model.isLoadingEpisodes {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(.horizontal, 16)
            } else if model.episodes.isEmpty {
                // Источник выбран, но серий в нём нет (сервер отдал `episodes_count == 0`).
                // Показываем объяснение и, если у озвучки есть другой рабочий источник,
                // кнопку переключения на него. Без выбранного источника оставляем
                // прежний нейтральный текст — объяснять «у этого источника» нечего.
                if model.selectedSourceId != nil {
                    episodesEmptyState
                } else {
                    Text("Список серий пуст")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 16)
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.episodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            supportsDownload: model.selectedSourceSupportsDownload,
                            downloadState: downloadState(for: episode),
                            isPreparing: model.preparingEpisodePosition == episode.position,
                            onPlay: {
                                Task { @MainActor in
                                    await model.play(episode)
                                    // Основную ошибку модель кладёт в `errorMessage` (в том числе
                                    // когда автоподбор не нашёл замену) — показываем её уже
                                    // существующим алертом экрана, как у скачивания.
                                    if let message = model.errorMessage {
                                        actionError = message
                                    }
                                }
                            },
                            onDownload: { download(episode) }
                        )

                        Divider()
                            .overlay(Theme.separator)
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .padding(.bottom, 24)
    }

    /// Пустое состояние серий: в выбранном источнике их нет.
    ///
    /// Вместо сухого «Список серий пуст» объясняем причину и, если у релиза есть
    /// другой источник с сериями, даём кнопку быстрого переключения на него —
    /// ровно те источники, что помечены в меню как рабочие.
    private var episodesEmptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "play.slash")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary)

            Text("У этого источника сейчас нет серий")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            Text("Выберите другую озвучку или источник")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let alternative = model.alternativeSourceWithEpisodes {
                Button {
                    Task { await model.selectSource(alternative) }
                } label: {
                    Text("Попробовать \(alternative.displayName)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Theme.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    /// Строка «Источники»: все плееры релиза, а не только выбранной озвучки.
    ///
    /// Источники привязаны к озвучке, поэтому секция «Серии» показывает плееры
    /// только текущего типа (AniDUB → Kodik, AniLibria → Libria), и кажется,
    /// что других у релиза нет. Заголовок с кнопкой «Все» открывает `AllSourcesView`
    /// со сводкой по озвучкам. При единственном источнике строку не показываем:
    /// меню в «Серии» уже покрывает весь выбор, а карточку засорять нечем.
    @ViewBuilder
    private var allSourcesSection: some View {
        if model.hasMultipleSources {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Источники")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    Spacer(minLength: 8)

                    Button("Все") {
                        showsAllSources = true
                        // Сводка могла ещё не прийти (или упасть) — пробуем снова.
                        Task { await model.loadAllSources() }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
                }

                if !model.allSourcesSummary.isEmpty {
                    Text(model.allSourcesSummary)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 22)
        }
    }

    private func relatedSection(_ release: Release) -> some View {
        Group {
            if let related = release.relatedReleases, !related.isEmpty {
                ShelfView(title: "Связанные", releases: related)
            }
        }
    }

    // MARK: - Действия с релизом

    /// Ряд действий под шапкой. Гостю кнопки не показываем: любой запрос без
    /// токена вернёт `APIError.unauthorized`, поэтому вместо них — подсказка о входе.
    @ViewBuilder
    private func actions(_ release: Release) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if session.isAuthorized {
                listMenu
                favoriteButton
                voteCard
                shareLink(release)
            } else {
                guestHint
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .disabled(isPerformingAction)
    }

    /// Плашка автоподбора: маленькое уведомление под блоками действий.
    ///
    /// Появляется, когда плеер открылся не на выбранной озвучке, а на подобранной
    /// автоматически. Кнопка «ОК» просто закрывает плашку — источник в меню
    /// остаётся прежним, чтобы пользователь мог выбрать другой сам.
    @ViewBuilder
    private var fallbackBanner: some View {
        if let notice = model.fallbackNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 1)

                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("ОК") {
                    model.fallbackNotice = nil
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
                .accessibilityLabel("Скрыть уведомление")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
    }

    /// «В список»: меню статусов профиля. Текущий статус подсвечен, а повторный
    /// выбор его же снимает релиз со списка — так в одном контроле есть add и remove.
    private var listMenu: some View {
        Menu {
            ForEach(ProfileListStatus.allCases) { status in
                Button {
                    selectStatus(status)
                } label: {
                    Label(
                        status.title,
                        systemImage: model.listStatus == status ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
        } label: {
            actionCard(
                icon: model.listStatus == nil ? "bookmark" : "bookmark.fill",
                title: model.listStatus?.title ?? "В список",
                active: model.listStatus != nil
            )
        }
        .accessibilityLabel("Добавить в список")
    }

    /// «Избранное»: сердечко-переключатель.
    private var favoriteButton: some View {
        Button {
            perform { try await model.toggleFavorite() }
        } label: {
            actionCard(
                icon: model.isFavorite ? "heart.fill" : "heart",
                title: "Избранное",
                active: model.isFavorite
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isFavorite ? "Убрать из избранного" : "Добавить в избранное")
    }

    /// «Оценить»: пять звёзд; тап по своей же оценке отзывает голос.
    private var voteCard: some View {
        VStack(spacing: 5) {
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        perform { try await model.setVote(star) }
                    } label: {
                        Image(systemName: star <= model.vote ? "star.fill" : "star")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(star <= model.vote ? Theme.accent : Theme.textTertiary)
                            .frame(width: 12, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Оценка \(star)")
                }
            }
            .frame(height: 20)

            Text(voteCaption(model.vote))
                .font(.caption2.weight(.medium))
                .foregroundStyle(model.vote > 0 ? Theme.accent : Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .cardSurface()
    }

    /// «Поделиться»: системный share sheet со ссылкой на страницу релиза.
    @ViewBuilder
    private func shareLink(_ release: Release) -> some View {
        if let url = URL(string: "https://anixart.link/release/\(release.id)") {
            ShareLink(item: url) {
                actionCard(icon: "square.and.arrow.up", title: "Поделиться")
            }
            .accessibilityLabel("Поделиться релизом")
        }
    }

    /// Гость: объясняем, что действия требуют входа (без перехода на экран входа).
    private var guestHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Войти, чтобы добавить в список")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Список, избранное и оценка доступны после входа в аккаунт.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Карточка действия: иконка и подпись; активное состояние — акцентная рамка.
    private func actionCard(icon: String, title: String, active: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                .frame(height: 20)

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .cardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(active ? Theme.accent : Theme.separator, lineWidth: 1)
        )
    }

    /// Выбор статуса: по текущему статусу — снятие, по другому — добавление.
    private func selectStatus(_ status: ProfileListStatus) {
        perform {
            if model.listStatus == status {
                try await model.removeFromList()
            } else {
                try await model.addToList(status)
            }
        }
    }

    /// Подпись под звёздами: текущая оценка или призыв поставить её.
    private func voteCaption(_ vote: Int) -> String {
        vote > 0 ? "Оценка \(vote)" : "Оценить"
    }

    /// Выполнить изменяющее действие: успех уже обновил модель, ошибку показываем
    /// алертом. Повторные нажатия блокируем, пока запрос в полёте.
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                try await action()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Алерт ошибки: пока в `actionError` есть текст, он показан; закрытие чистит его.
    private var isActionAlertPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { isPresented in
                if !isPresented { actionError = nil }
            }
        )
    }

    /// Состояние загрузки серии для иконки в строке.
    private func downloadState(for episode: Episode) -> DownloadItem.State? {
        model.downloadItem(for: episode)?.state
    }

    /// Тап по иконке скачивания: модель резолвит ссылку и ставит загрузку.
    ///
    /// Ошибку модель кладёт в `errorMessage`; показываем её уже существующим алертом
    /// экрана, чтобы не заводить второй канал сообщений.
    private func download(_ episode: Episode) {
        Task { @MainActor in
            await model.download(episode)
            if let message = model.errorMessage {
                actionError = message
            }
        }
    }
}

private struct StatBadge: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .cardSurface()
    }
}

/// Строка серии: номер, название, отметка просмотра, кнопка скачивания и иконка плеера.
///
/// Скачивание поддерживают только нативные HLS-источники, поэтому кнопка показывается
/// лишь когда `supportsDownload` — её состояние берётся из `DownloadManager`.
private struct EpisodeRow: View {
    let episode: Episode

    /// Источник поддерживает офлайн-скачивание (иначе кнопки нет).
    let supportsDownload: Bool
    /// Состояние загрузки этой серии (`nil` — ещё не скачивали).
    let downloadState: DownloadItem.State?

    /// Идёт подготовка воспроизведения именно этой серии: вместо иконки плеера
    /// крутится индикатор, тап повторно не срабатывает.
    let isPreparing: Bool

    /// Тап по серии — воспроизведение.
    let onPlay: () -> Void
    /// Тап по иконке скачивания (только у HLS-источников).
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            playContentButton

            if supportsDownload {
                downloadButton
            }

            playIconButton
        }
        // Высота строки фиксирована: 32 (кнопки в одну линию) + 8+8 отступов = 48 pt,
        // как было до добавления кнопки, — список серий не «прыгает».
        .frame(height: 32)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Воспроизведение

    /// Левая часть строки — одна кнопка: номер, название и отметка просмотра.
    /// `contentShape` делает нажимаемым и пустое место до правых иконок.
    private var playContentButton: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Text("\(episode.position)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 28, alignment: .trailing)

                Text(episode.displayName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if episode.isWatched == true {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Смотреть серию \(episode.position)")
    }

    /// Иконка плеера — отдельная кнопка (рядом с кнопкой скачивания), а не часть
    /// предыдущей: иначе кнопка скачивания оказалась бы после иконки плеера.
    private var playIconButton: some View {
        Button(action: onPlay) {
            Group {
                if isPreparing {
                    // Подготовка серии: ссылка запрашивается у API и резолвится
                    // у провайдера — пользователь должен видеть, что тап принят.
                    ProgressView()
                        .tint(Theme.accent)
                } else {
                    Image(systemName: "play.circle")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .accessibilityLabel(isPreparing
            ? "Готовим серию \(episode.position)"
            : "Воспроизвести серию \(episode.position)")
        .accessibilityIdentifier("episode-play-\(episode.position)")
    }

    // MARK: - Скачивание

    /// Кнопка 32×32: при обычном тапе запускает загрузку, иконка отражает её состояние.
    private var downloadButton: some View {
        Button(action: onDownload) {
            downloadIcon
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(downloadAccessibilityLabel)
    }

    /// Иконка состояния: стрелка — ещё не скачивали, кружок с процентом — идёт
    /// загрузка, галочка — готово, восклицательный знак — ошибка.
    @ViewBuilder
    private var downloadIcon: some View {
        switch downloadState {
        case .none:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textSecondary)
        case .some(.queued):
            progressBadge(0)
        case .some(.downloading(let progress)):
            progressBadge(progress)
        case .some(.completed):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
        case .some(.failed):
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
    }

    /// Прогресс загрузки: кружок с целыми процентами внутри.
    private func progressBadge(_ progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Theme.separator, lineWidth: 2)

            Text("\(percent(progress))%")
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
        }
        .frame(width: 24, height: 24)
    }

    private func percent(_ progress: Double) -> Int {
        Int((min(max(progress, 0), 1) * 100).rounded())
    }

    private var downloadAccessibilityLabel: String {
        switch downloadState {
        case .none:
            return "Скачать серию \(episode.position)"
        case .some(.queued), .some(.downloading):
            return "Серия скачивается"
        case .some(.completed):
            return "Серия скачана"
        case .some(.failed):
            return "Повторить скачивание серии"
        }
    }
}

private struct CommentRow: View {
    let comment: ReleaseComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(urlString: comment.profile?.avatar)
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.profile?.displayName ?? "Пользователь")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Text(dateText)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)

                    if comment.isEdited == true {
                        Text("изменён")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Text(comment.message ?? "")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let likes = comment.voteCount ?? comment.likesCount, likes > 0 {
                    Label("\(likes)", systemImage: "heart")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }

                if let replies = comment.replyCount, replies > 0 {
                    Text("Ответов: \(replies)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var dateText: String {
        guard let timestamp = comment.timestamp else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Обёртка для `.fullScreenCover(item:)` секции видео.
///
/// В отличие от серий, у видео нет `releaseId/sourceId/position` и прогресса
/// просмотра — плееру передаётся только уже разобранная цель воспроизведения.
private struct VideoPlaybackPresentation: Identifiable {
    let id = UUID()
    let target: PlaybackTarget
}
