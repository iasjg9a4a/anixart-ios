import Foundation

// MARK: - Готовая к показу серия

/// Результат полного резолва серии: что играть и из какого источника.
///
/// Раньше тип жил внутри `EpisodePlaybackService` (`Resolved`) — там он и
/// остался под тем же именем (`typealias`). Отдельный тип нужен кэшу: тот
/// хранит готовые цели и не должен зависеть от сервиса, который ходит в сеть.
struct EpisodeResolution: Equatable, Sendable {
    /// Цель для `PlayerView`: `.hls` — нативный `AVPlayer`, `.web` — `WKWebView`.
    let target: PlaybackTarget
    /// Источник, из которого реально взята серия.
    let sourceId: Int
    /// Имя источника; пока всегда `nil` (см. `EpisodePlaybackService.resolve`).
    let sourceName: String?
}

// MARK: - Кэш резолва серий

/// Короткоживущий кэш резолва серий и дедупликация подогрева.
///
/// ## Зачем
///
/// Переключение серии стоит два сетевых шага: `episode/target` (подписанная
/// ссылка) и нативный резолвер провайдера (`ftor` у Kodik, `shell.php` у
/// Sibnet, API у AniLibria/AnixPlayer, `play/options` у RuTube). На мобильной
/// сети это от половины секунды до нескольких секунд, и всё это время
/// пользователь смотрит на спиннер.
///
/// Кэш убирает ожидание в двух случаях:
///
/// * **Подогрев следующей серии.** `PlayerView` за ~2,5 минуты до конца серии
///   вызывает `EpisodePlaybackService.prefetch(...)`; к моменту нажатия
///   «Следующая серия» ссылка уже лежит здесь и плеер стартует сразу.
/// * **Возврат к недавней серии.** Выбор той же серии в списке или повторный
///   заход в пределах `lifetime` берётся из памяти, без сети.
///
/// ## Почему время жизни маленькое
///
/// Ссылка `episode/target` подписана (`d`/`s`/`ip` у Kodik, `clientIp` у
/// AniLibria): она привязана к IP и истекает. Поэтому запись живёт всего
/// `lifetime` (5 минут) — подогрев успевает, а «вчерашняя» ссылка из кэша
/// никогда не попадёт в плеер. Истёкшая запись просто игнорируется, и сервис
/// резолвит серию заново.
///
/// ## Изоляция
///
/// `actor`: резолв идёт из нескольких задач одновременно (экран плеера плюс
/// фоновый подогрев), а `EpisodePlaybackService` — набор `static`-функций без
/// собственного состояния. Одно общее состояние на приложение —
/// `EpisodeResolutionCache.shared`; отдельные экземпляры с укороченным
/// `lifetime`/`limit` создаются в тестах.
actor EpisodeResolutionCache {
    /// Общий кэш приложения.
    static let shared = EpisodeResolutionCache()

    /// Запись кэша: готовая цель и момент резолва.
    private struct Entry {
        let resolution: EpisodeResolution
        let storedAt: Date

        /// Свежая ли запись на момент `date`.
        func isFresh(at date: Date, lifetime: TimeInterval) -> Bool {
            let age = date.timeIntervalSince(storedAt)
            return age >= 0 && age < lifetime
        }
    }

    private var entries: [String: Entry] = [:]

    /// Ключи серий, которые сейчас резолвит подогрев: второй `prefetch` того же
    /// ключа не должен запускать вторую пару сетевых запросов.
    private var prefetching: Set<String> = []

    /// Сколько запись считается пригодной (подписанные ссылки истекают).
    private let lifetime: TimeInterval

    /// Предел числа записей: смотрят одну серию, подогревают следующую, иногда
    /// прыгают по списку — больше нескольких записей не нужно. Лишние
    /// вытесняются по дате резолва.
    private let limit: Int

    init(lifetime: TimeInterval = 5 * 60, limit: Int = 6) {
        self.lifetime = lifetime
        self.limit = limit
    }

    // MARK: - Ключ

    /// Ключ серии: `releaseId-sourceId-position`.
    ///
    /// Позиции уникальны только внутри источника, поэтому в ключе все три
    /// идентификатора. Чистая функция — её проверяет `EpisodeResolutionCacheTests`.
    nonisolated static func key(releaseId: Int, sourceId: Int, position: Int) -> String {
        "\(releaseId)-\(sourceId)-\(position)"
    }

    // MARK: - Чтение и запись

    /// Свежий резолв серии или `nil`, если его нет/он истёк.
    func resolution(forKey key: String, at now: Date = Date()) -> EpisodeResolution? {
        guard let entry = entries[key], entry.isFresh(at: now, lifetime: lifetime) else {
            return nil
        }
        return entry.resolution
    }

    /// Запоминает резолв серии, попутно выкидывая истёкшие и самые старые записи.
    func store(_ resolution: EpisodeResolution, forKey key: String, at now: Date = Date()) {
        entries[key] = Entry(resolution: resolution, storedAt: now)

        let fresh = entries.filter { $0.value.isFresh(at: now, lifetime: lifetime) }
        let newestFirst = fresh.sorted { $0.value.storedAt > $1.value.storedAt }
        entries = Dictionary(uniqueKeysWithValues: newestFirst.prefix(limit).map { ($0.key, $0.value) })
    }

    /// Забывает серию: нужно при повторной попытке после ошибки — пользователь
    /// нажал «Повторить», и ссылку надо брать свежую, а не ту, что не сыграла.
    func invalidate(forKey key: String) {
        entries.removeValue(forKey: key)
    }

    /// Ключи, которые лежат в кэше (без проверки свежести).
    ///
    /// Нужны тестам вытеснения и диагностике; поведение плеера от них не зависит.
    func cachedKeys() -> Set<String> {
        Set(entries.keys)
    }

    // MARK: - Подогрев

    /// Разрешает начать подогрев серии.
    ///
    /// - Returns: `false`, если подогрев этой серии уже идёт или свежий резолв
    ///   уже лежит в кэше — в обоих случаях сетевые запросы не нужны.
    func beginPrefetch(forKey key: String, at now: Date = Date()) -> Bool {
        guard !prefetching.contains(key) else { return false }
        guard resolution(forKey: key, at: now) == nil else { return false }
        prefetching.insert(key)
        return true
    }

    /// Снимает отметку «подогрев идёт» — успешный он или нет.
    func endPrefetch(forKey key: String) {
        prefetching.remove(key)
    }
}
