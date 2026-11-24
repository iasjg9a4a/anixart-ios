import Foundation
import Combine

// MARK: - Ключ прогресса

/// Ключ, под которым хранится прогресс просмотра одной серии.
///
/// `position` серии уникальна только внутри источника: у одного релиза может быть
/// несколько озвучек/источников, поэтому в ключ входят все три идентификатора.
struct PlaybackKey: Hashable, Codable {
    let releaseId: Int
    let sourceId: Int
    let position: Int

    init(releaseId: Int, sourceId: Int, position: Int) {
        self.releaseId = releaseId
        self.sourceId = sourceId
        self.position = position
    }

    /// Строка вида `releaseId-sourceId-position`.
    ///
    /// Она же суффикс ключа в `UserDefaults` (`anixart.playback.<storageKey>`)
    /// и ключ в `PlaybackProgress.lastPlayed`.
    var storageKey: String { "\(releaseId)-\(sourceId)-\(position)" }

    /// Обратный разбор `storageKey` — например, для избранных записей
    /// из `PlaybackProgress.continueWatching()`, где ключ приходит строкой.
    init?(storageKey: String) {
        let parts = storageKey.split(separator: "-")
        guard parts.count == 3,
              let releaseId = Int(parts[0]),
              let sourceId = Int(parts[1]),
              let position = Int(parts[2]) else {
            return nil
        }
        self.init(releaseId: releaseId, sourceId: sourceId, position: position)
    }
}

// MARK: - Сервис прогресса

/// Локальный прогресс просмотра и запись прогресса на сервер Anixart.
///
/// Зачем отдельный сервис: `PlayerView` не должен знать ни про `UserDefaults`,
/// ни про то, когда вызывать `episode/watch` и `history/add`. Экран сообщает
/// только два факта — «пользователь на такой-то секунде» и «серия досмотрена», —
/// а решения принимает этот класс. Поэтому SwiftUI здесь не импортируется:
/// сервис не зависит ни от одного экрана.
///
/// Экземпляр один на приложение — `PlaybackProgress.shared`. Класс `@MainActor`,
/// так как его `@Published`-свойства читает UI, а запись в `UserDefaults` дешёвая
/// и не требует фонового потока.
///
/// Порядок работы из плеера:
/// 1. при открытии серии — `position(...)`, чтобы перемотать на сохранённое место;
/// 2. во время просмотра — `savePosition(...)` раз в 10–15 секунд;
/// 3. при закрытии плеера — `savePosition(...)` ещё раз, затем `reportHistory(...)`;
/// 4. когда серия досмотрена — `markWatched(...)`.
@MainActor
final class PlaybackProgress: ObservableObject {
    static let shared = PlaybackProgress()

    /// Позиции в секундах по ключу `releaseId-sourceId-position`
    /// (см. `PlaybackKey.storageKey`). Заполняется из `UserDefaults` при первом
    /// обращении к сервису и обновляется в `savePosition(...)`.
    @Published private(set) var lastPlayed: [String: Int] = [:]

    /// Текст последней ошибки синхронизации с сервером.
    ///
    /// Ошибки не пробрасываются наружу: плеер не должен ломаться из-за сети.
    /// Экран может показать это значение, например, в `.alert` или тосте.
    /// При успешном запросе сбрасывается в `nil`.
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults
    private let api: APIClient

    private let keyPrefix = "anixart.playback."
    private let datePrefix = "anixart.playback.date."
    private let indexKey = "anixart.playback.index"

    /// Сколько серий помнить локально, чтобы `position(...)` и `continueWatching()`
    /// оставались быстрыми даже после долгого использования приложения.
    private let storedLimit = 50

    /// Размер списка «Продолжить просмотр». Храним больше (`storedLimit`),
    /// но показываем самое свежее.
    private let continueLimit = 10

    private init(defaults: UserDefaults = .standard, api: APIClient = .shared) {
        self.defaults = defaults
        self.api = api
        loadStoredPositions()
    }

    // MARK: - Локальная позиция

    /// Сохранить, на какой секунде сейчас находится просмотр.
    ///
    /// Когда вызывать:
    /// * периодически во время просмотра — раз в 10–15 секунд;
    /// * обязательно при закрытии плеера (`onDisappear`) и уходе приложения в фон,
    ///   иначе потеряются последние секунды;
    /// * после ручной перемотки пользователем.
    ///
    /// Метод синхронный и без сети: это одна запись в `UserDefaults`, поэтому
    /// вызывать его часто можно и нужно. Отрицательные значения приводятся к нулю.
    func savePosition(seconds: Int, releaseId: Int, sourceId: Int, position: Int) {
        let key = PlaybackKey(releaseId: releaseId, sourceId: sourceId, position: position).storageKey
        let value = max(0, seconds)

        defaults.set(value, forKey: keyPrefix + key)
        defaults.set(Date().timeIntervalSince1970, forKey: datePrefix + key)
        touch(key)
        lastPlayed[key] = value
    }

    /// Сохранённая позиция в секундах или `nil`, если серию ещё не смотрели.
    ///
    /// Когда вызывать: сразу после открытия серии в плеере, до первого `play()`,
    /// чтобы выполнить `seek` на сохранённое место. Для web-плеера (Kodik, iframe)
    /// позиция недоступна — там появится «Продолжить» только после появления
    /// реальной позиции от самого плеера.
    func position(releaseId: Int, sourceId: Int, position: Int) -> Int? {
        let key = PlaybackKey(releaseId: releaseId, sourceId: sourceId, position: position).storageKey
        if let cached = lastPlayed[key] { return cached }
        return defaults.object(forKey: keyPrefix + key) as? Int
    }

    /// Последние просмотренные серии для блока «Продолжить просмотр».
    ///
    /// Когда вызывать: при отрисовке главной, профиля или списка «Продолжить».
    /// Массив уже отсортирован: первым идёт то, что смотрели последним.
    /// Ключ разбирается обратно в `PlaybackKey(storageKey:)`, чтобы открыть серию.
    /// Серии с нулевой позицией (плеер открыли и сразу закрыли) не попадают в список.
    func continueWatching() -> [(key: String, seconds: Int)] {
        var entries: [(key: String, seconds: Int, date: Date)] = []

        for key in storedKeys() {
            guard let seconds = defaults.object(forKey: keyPrefix + key) as? Int,
                  seconds > 0 else { continue }

            let rawDate = defaults.object(forKey: datePrefix + key) as? Double
            let date = rawDate.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            entries.append((key: key, seconds: seconds, date: date))
        }

        entries.sort { $0.date > $1.date }
        return entries.prefix(continueLimit).map { (key: $0.key, seconds: $0.seconds) }
    }

    // MARK: - Синхронизация с сервером

    /// Отметить серию просмотренной на сервере (`episode/watch`).
    ///
    /// Когда вызывать: когда серия действительно досмотрена — по уведомлению
    /// `AVPlayerItem.didPlayToEndTimeNotification` или при достижении ~90–95 % длины.
    /// Не вызывайте на каждом тике: сервер получит десятки одинаковых запросов.
    ///
    /// Без входа в аккаунт метод ничего не делает молча: write-эндпоинты требуют
    /// токен, а `Session.isAuthorized` — это тот же признак (`TokenStore.shared.token`).
    /// Ошибку не пробрасывает — складывает в `lastError`.
    func markWatched(releaseId: Int, sourceId: Int, position: Int) async {
        guard isAuthorized else { return }
        do {
            try await api.markEpisodeWatched(releaseId: releaseId, sourceId: sourceId, position: position)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Записать пройденную позицию в историю просмотров аккаунта (`history/add`).
    ///
    /// Когда вызывать: реже, чем `savePosition`, — например, при паузе или раз в
    /// несколько минут, чтобы история на сервере соответствовала просмотру.
    /// Серию «просмотренной» не отмечает — для этого есть `markWatched(...)`.
    ///
    /// Без входа в аккаунт метод ничего не делает, ошибку не пробрасывает.
    func reportHistory(releaseId: Int, sourceId: Int, position: Int) async {
        guard isAuthorized else { return }
        do {
            try await api.addHistory(releaseId: releaseId, sourceId: sourceId, position: position)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Хранилище

    /// Тот же признак авторизации, что и `Session.isAuthorized`, но без зависимости
    /// от SwiftUI-окружения: сервис создаётся один раз и не видит `EnvironmentObject`.
    private var isAuthorized: Bool {
        TokenStore.shared.token != nil
    }

    private func storedKeys() -> [String] {
        defaults.stringArray(forKey: indexKey) ?? []
    }

    /// Ставит ключ в начало списка «последних» и выкидывает самые старые записи,
    /// чтобы `UserDefaults` не рос бесконечно.
    private func touch(_ key: String) {
        var keys = storedKeys()
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)

        if keys.count > storedLimit {
            for expired in keys[storedLimit...] {
                defaults.removeObject(forKey: keyPrefix + expired)
                defaults.removeObject(forKey: datePrefix + expired)
                lastPlayed[expired] = nil
            }
            keys.removeSubrange(storedLimit...)
        }

        defaults.set(keys, forKey: indexKey)
    }

    /// Восстанавливает позиции из `UserDefaults` при первом обращении к `shared`.
    private func loadStoredPositions() {
        var loaded: [String: Int] = [:]
        for key in storedKeys() {
            if let seconds = defaults.object(forKey: keyPrefix + key) as? Int {
                loaded[key] = seconds
            }
        }
        lastPlayed = loaded
    }
}
