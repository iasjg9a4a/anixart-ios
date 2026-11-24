import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле — как в APIClient.swift
#endif

// MARK: - Полный резолв серии

/// Единый конвейер «серия из API → цель воспроизведения».
///
/// ## Зачем
///
/// Раньше у плеера было два разных пути к видео:
///
/// 1. **Старт серии** (`ReleaseView.play` → `PlayerView.preparePlayback`) — полный:
///    `episode/target` → `PlaybackResolver` → для Kodik прямой HLS-резолв
///    (`KodikDirectResolver`), для Sibnet/AniLibria/RuTube/AnixPlayer — их нативные
///    резолверы. Так серия действительно играет.
/// 2. **Смена серии** (`PlayerView.startPlayback` → `NextEpisodeService.resolvedTarget`)
///    — упрощённый: только `PlaybackResolver`. У Kodik это оставляло web-прокси
///    (`Error code: ds` внутри iframe), а у нативных провайдеров — `.web`-цель,
///    которую `AVPlayer` бесконечно «грузит».
///
/// Пользовательский баг «нажимаешь следующая серия → Error: ds / бесконечная
/// загрузка» — ровно следствие второго пути. Теперь оба пути (и debug-маршрут
/// `-anixart-open-player=...` из `AnixartApp`) идут через `resolve(...)`.
///
/// ## Порядок работы
///
/// 1. `APIClient.episodeTarget(...)` — свежая подписанная ссылка серии (живёт
///    ограниченное время и привязана к IP, поэтому запрашивается в момент показа).
/// 2. `PlaybackResolver.resolve(episode:sourceName:title:)` — разбор ссылки:
///    прямой поток → `.hls`, YouTube → `.youtube`, известный HTML-плеер → `.web`.
///    Имя источника пока не запрашивается (`sourceName: nil`): провайдер
///    определяется по host ссылки, а лишний запрос списка источников на каждое
///    переключение серии только тормозил бы старт.
/// 3. Для `.web` — попытка поднять нативное воспроизведение (см. `upgraded(_:)`):
///    * Kodik — `KodikDirectResolver` (`ftor` → HLS на CDN Kodik, обход WebView
///      и его «Error code: ds»). Не вышло — остаёмся на web-цели;
///    * Sibnet/AniLibria/RuTube/AnixPlayer — соответствующий нативный резолвер
///      (`SibnetResolver`, `AniLibriaResolver`, `RutubeResolver`, `AnixPlayerResolver`).
///      Ошибка резолвера не бросается: возвращается исходная `.web`-цель, как
///      в `PlayerView.preparePlayback`.
///
/// ## Кэш и подогрев
///
/// Результат резолва живёт 5 минут в `EpisodeResolutionCache` — ровно чтобы
/// подписанная ссылка не успела истечь. Это даёт две вещи: `prefetch(...)`
/// подогревает следующую серию до нажатия кнопки (переход почти мгновенный),
/// а возврат к только что просмотренной серии не ходит в сеть. Кнопка
/// «Повторить» на экране ошибки резолвит с `ignoringCache: true`.
enum EpisodePlaybackService {

    // MARK: - Результат

    /// Готовая к показу цель и контекст источника.
    ///
    /// Тип объявлен в `EpisodeResolutionCache.swift` (`EpisodeResolution`):
    /// кэш хранит ровно его и не должен зависеть от сервиса с сетью.
    typealias Resolved = EpisodeResolution

    // MARK: - Резолв

    /// Полный резолв серии — тот же путь, что и при открытии плеера с релиза.
    ///
    /// - Parameters:
    ///   - releaseId: релиз, в котором находится серия.
    ///   - sourceId: источник серии (позиции уникальны только внутри источника).
    ///   - position: номер серии внутри источника (нумерация с 1).
    ///   - title: заголовок для экрана плеера; `nil`/пусто — `Episode.displayName`.
    ///   - typeId: озвучка. Пока не используется: имя источника не запрашивается
    ///     (`sourceName` в `PlaybackResolver` — `nil`). Зарезервировано под
    ///     автоподбор источника.
    ///   - ignoringCache: `true` — не брать готовый резолв из
    ///     `EpisodeResolutionCache` и сходить в сеть заново. Нужно кнопке
    ///     «Повторить»: серия не сыграла, и подписанная ссылка из кэша,
    ///     скорее всего, та же нерабочая.
    ///   - api: клиент API (для тестов и повторного использования).
    /// - Throws: ошибки `APIClient` (сеть/сервер) и `PlaybackError.emptyURL`,
    ///   если сервер не вернул пригодную ссылку. Ошибки нативных резолверов
    ///   не пробрасываются — вместо них возвращается `.web`-цель.
    static func resolve(
        releaseId: Int,
        sourceId: Int,
        position: Int,
        title: String?,
        typeId: Int? = nil,
        ignoringCache: Bool = false,
        api: APIClient = .shared
    ) async throws -> Resolved {
        let key = EpisodeResolutionCache.key(releaseId: releaseId, sourceId: sourceId, position: position)
        if ignoringCache {
            // Повторная попытка: протухшую запись убираем сразу, чтобы её не
            // подхватил параллельный подогрев.
            await EpisodeResolutionCache.shared.invalidate(forKey: key)
        } else if let cached = await EpisodeResolutionCache.shared.resolution(forKey: key) {
            // Серию уже подогрели (или смотрели минуту назад) — играем сразу.
            return cached
        }

        let resolved = try await resolveFresh(
            releaseId: releaseId,
            sourceId: sourceId,
            position: position,
            title: title,
            api: api
        )
        await EpisodeResolutionCache.shared.store(resolved, forKey: key)
        return resolved
    }

    /// Полный сетевой резолв без кэша: `episode/target` → разбор → нативный апгрейд.
    private static func resolveFresh(
        releaseId: Int,
        sourceId: Int,
        position: Int,
        title: String?,
        api: APIClient
    ) async throws -> Resolved {
        let episode = try await api.episodeTarget(
            releaseId: releaseId,
            sourceId: sourceId,
            position: position
        )

        let resolvedTitle = episodeTitle(title) ?? episode.displayName
        let target = try PlaybackResolver.resolve(
            episode: episode,
            sourceName: nil,
            title: resolvedTitle
        )
        let upgraded = await upgraded(target)

        return Resolved(
            target: upgraded,
            sourceId: sourceId,
            sourceName: nil
        )
    }

    // MARK: - Подогрев следующей серии

    /// Заранее резолвит серию в фоне, чтобы переход на неё был мгновенным.
    ///
    /// Вызывает `PlayerView` за `nextEpisodePrefetchLead` секунд до конца
    /// текущей серии: к моменту нажатия «Следующая серия» ссылка уже лежит в
    /// `EpisodeResolutionCache`, и плеер стартует без двух сетевых шагов
    /// (`episode/target` + нативный резолвер).
    ///
    /// Ошибки игнорируются: подогрев — оптимизация, а не обязательный шаг.
    /// Пользователь всё равно получит серию, просто резолв случится по нажатию.
    /// Повторный вызов того же ключа ничего не стоит: `beginPrefetch` не даст
    /// запустить вторую пару запросов и не полезет в сеть, если резолв уже есть.
    ///
    /// Задача намеренно неструктурированная (`Task { }`): подогрев не должен
    /// отменяться вместе с задачей экрана — иначе смысл теряется.
    nonisolated static func prefetch(
        releaseId: Int,
        sourceId: Int,
        position: Int,
        title: String?,
        typeId: Int? = nil,
        api: APIClient = .shared
    ) {
        let key = EpisodeResolutionCache.key(releaseId: releaseId, sourceId: sourceId, position: position)
        Task {
            guard await EpisodeResolutionCache.shared.beginPrefetch(forKey: key) else { return }
            let resolved = try? await resolveFresh(
                releaseId: releaseId,
                sourceId: sourceId,
                position: position,
                title: title,
                api: api
            )
            if let resolved {
                await EpisodeResolutionCache.shared.store(resolved, forKey: key)
            }
            await EpisodeResolutionCache.shared.endPrefetch(forKey: key)
        }
    }

    // MARK: - Заголовок

    /// Заголовок серии: переданный экраном или `displayName` серии.
    private static func episodeTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Нативное апгрейд .web-цели

    /// Пробует превратить `.web`-цель в нативный HLS-поток.
    ///
    /// `.hls`/`.youtube` возвращаются как есть: первый уже играет `AVPlayer`,
    /// второй намеренно уходит в ошибку «только во внешнем плеере».
    ///
    /// Для известных провайдеров ошибка резолвера не пробрасывается: вызывающий
    /// получает исходную web-цель (старое поведение `PlayerView.preparePlayback`),
    /// а не «вечную загрузку». Так серия хотя бы попробует открыться в `WKWebView`.
    private static func upgraded(_ target: PlaybackTarget) async -> PlaybackTarget {
        guard case .web = target.kind else { return target }
        guard let playableURL = originalWebURL(for: target) else { return target }

        switch provider(for: target) {
        case .kodik:
            // Прямой HLS Kodik: подписанная страница → `ftor` → CDN-ссылки.
            guard let direct = await KodikDirectResolver.resolve(embedURL: playableURL) else {
                return target
            }
            return directTarget(from: direct, title: target.title)

        case .sibnet, .libria, .rutube, .anixplayer:
            guard let resolved = await nativeTarget(for: provider(for: target),
                                                    url: playableURL,
                                                    title: target.title) else {
                return target
            }
            return resolved

        case .youtube, .unknown:
            return target
        }
    }

    /// Нативный резолвер конкретного провайдера; `nil` — не получилось или
    /// резолвер вернул не поток.
    private static func nativeTarget(
        for provider: VideoProvider,
        url: URL,
        title: String
    ) async -> PlaybackTarget? {
        do {
            let resolved: PlaybackTarget
            switch provider {
            case .sibnet:
                resolved = try await SibnetResolver.resolve(url: url, title: title)
            case .libria:
                resolved = try await AniLibriaResolver.resolve(url: url, title: title)
            case .rutube:
                resolved = try await RutubeResolver.resolve(url: url, title: title)
            case .anixplayer:
                resolved = try await AnixPlayerResolver.resolve(url: url, title: title)
            case .kodik, .youtube, .unknown:
                return nil
            }
            guard case .hls = resolved.kind else { return nil }
            return resolved
        } catch is CancellationError {
            // Экран закрыли/сменили серию — не подменяем цель web-фолбэком.
            return nil
        } catch {
            // Резолвер не смог достать поток: остаёмся на web-цели (см. `upgraded`).
            return nil
        }
    }

    // MARK: - Чистые помощники

    /// Провайдер web-цели: `PlaybackResolver` уже вписал человеческое имя
    /// источника в `providerName`, поэтому `VideoProvider.detect` по нему
    /// восстанавливает тот же провайдер, что был определён при разборе ссылки.
    ///
    /// Чистая функция без сети — её проверяет `EpisodePlaybackServiceTests`.
    nonisolated static func provider(for target: PlaybackTarget) -> VideoProvider {
        VideoProvider.detect(sourceName: target.providerName, url: nil)
    }

    /// Ссылка для нативного резолвера: исходный адрес плеера, а не web-прокси
    /// Anixart `anixmirai.com/iframe?url=…` (Kodik/Libria оборачиваются в него
    /// в `PlaybackResolver`).
    ///
    /// Чистая функция без сети — её проверяет `EpisodePlaybackServiceTests`.
    /// - Returns: исходный или развёрнутый адрес для `.web`-цели; `nil` для
    ///   нативных целей.
    nonisolated static func originalWebURL(for target: PlaybackTarget) -> URL? {
        guard case .web(let url) = target.kind else { return nil }
        return unwrappedProxyURL(url) ?? url
    }

    /// Достаёт исходную ссылку из прокси Anixart `anixmirai.com/iframe?url=...`.
    ///
    /// Чистая функция без сети — её проверяет `EpisodePlaybackServiceTests`.
    /// - Returns: вложенный URL или `nil`, если это не прокси.
    nonisolated static func unwrappedProxyURL(_ url: URL) -> URL? {
        guard url.host?.lowercased().contains("anixmirai") == true,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?
                  .first(where: { $0.name == "url" })?
                  .value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let inner = URL(string: raw),
              inner.host != nil else {
            return nil
        }
        return inner
    }

    /// Цель нативного Kodik из разобранного `ftor`-ответа: лучшее качество
    /// текущим URL, все качества — в `variants` для меню плеера.
    ///
    /// Чистая функция без сети — её проверяет `EpisodePlaybackServiceTests`.
    nonisolated static func directTarget(from stream: KodikStream, title: String) -> PlaybackTarget {
        let variants = KodikDirectResolver.variants(for: stream)
        return PlaybackTarget(
            kind: .hls(stream.bestURL),
            title: title,
            providerName: KodikDirectResolver.providerName,
            referer: stream.pageURL,
            variants: variants.isEmpty ? nil : variants
        )
    }
}
