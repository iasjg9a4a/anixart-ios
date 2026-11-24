import Foundation
import AVFoundation
import Combine

// MARK: - Менеджер загрузок

/// Скачивание серий для офлайн-просмотра.
///
/// Один экземпляр на приложение — `DownloadManager.shared`. Класс `@MainActor`, как
/// остальные `ObservableObject` в проекте: UI читает `items` без переключения потоков.
///
/// Как устроено (см. `docs/OFFLINE.md`, этап 3):
/// - **HLS** (`url.pathExtension == "m3u8"`, AniLibria/RuTube/AnixPlayer): один
///   `AVAssetDownloadURLSession` на приложение с background-конфигурацией и
///   `AVAssetDownloadTask` (через `AVAssetDownloadConfiguration` — старый
///   `makeAssetDownloadTask(asset:assetTitle:...)` в новых SDK deprecated). Система
///   качает `.movpkg` вне процесса, поэтому загрузка переживает сворачивание приложения.
/// - **Прогрессивный HTTP (MP4**, Sibnet): обычный `URLSessionDownloadTask`; это не HLS,
///   `AVAssetDownloadURLSession` его не умеет. Докачка через `resumeData` не реализована —
///   после ошибки загрузка начинается заново (как в Android-оригинале, там это
///   `EpisodeFileDownloader` с `Range`).
/// - **Хранилище**: `Application Support/AnixartDownloads/<id>/` — сюда переносится готовый
///   пакет, `DownloadItem.localURL` указывает на фактический URL из `didFinishDownloadingTo`.
///   Состояние загрузок — JSON-манифест `Application Support/anixart-downloads.json`
///   (папка исключена из iCloud-бэкапа: 0,5–0,9 ГБ на серию бэкапить нельзя).
///
/// Чего класс не делает: не резолвит ссылки на видео (это резолверы в `Features/Player`),
/// не выбирает качество и не ретраит ошибки. `beginDownload(...)` ждёт уже готовый
/// прямой URL: media-плейлист `*.m3u8` или прогрессивный MP4.
///
/// Идентификатор загрузки детерминированный: `releaseId-sourceId-position`. Поэтому
/// повторный `beginDownload` для уже скачанной серии — no-op, а UI может считать
/// `isDownloaded(...)` без хранения id.
@MainActor
final class DownloadManager: NSObject, ObservableObject {

    // MARK: - Константы

    static let shared = DownloadManager()

    /// Идентификатор background-сессии. Он должен быть неизменным: при перезапуске
    /// приложение обязано пересоздать сессию с тем же identifier, иначе система
    /// не отдаст колбэки по уже идущим задачам (`docs/OFFLINE.md` §3).
    static let backgroundSessionIdentifier = "com.swiftsoft.anixart.ios.downloads"

    /// Папка с пакетами загрузок внутри `Application Support`.
    static let downloadsDirectoryName = "AnixartDownloads"

    /// Имя JSON-манифеста состояния (в корне `Application Support`, не в папке загрузок).
    static let manifestFileName = "anixart-downloads.json"

    /// Минимальный запас свободного места перед стартом. Точный размер серии заранее
    /// неизвестен (720p ~ 150–350 МБ, 1080p до ~0,9 ГБ), поэтому это грубая отсечка,
    /// чтобы не начинать загрузку на почти заполненном диске.
    static let minimumFreeSpace: Int64 = 100 * 1024 * 1024

    // MARK: - Состояние для UI

    /// Все известные загрузки, новые сверху. Источник истины для экрана «Загрузки».
    @Published private(set) var items: [DownloadItem] = []

    // MARK: - Сессии

    /// Фоновая сессия AVFoundation для HLS. Создаётся лениво: если загрузок нет,
    /// background-сессия приложению не нужна.
    ///
    /// В симуляторе `AVAssetDownloadTask` может не работать (фоновые загрузки там
    /// не эмулируются как на устройстве). Это не повод падать: ошибки AVFoundation
    /// приходят в `didCompleteWithError` и превращаются в `.failed`.
    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        // Скачиваем только по явному действию пользователя, откладывать нельзя.
        configuration.isDiscretionary = false
        return AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )
    }()

    /// Обычная сессия для прогрессивных MP4: только пока приложение активно.
    private lazy var progressiveSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    /// Активные задачи по id, чтобы `cancel(id:)`/`remove(id:)` могли их остановить.
    private var hlsTasks: [String: AVAssetDownloadTask] = [:]
    private var progressiveTasks: [String: URLSessionDownloadTask] = [:]

    // MARK: - Файлы

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Версия формата манифеста: понадобится, когда у загрузок появятся новые поля
    /// (качество, лимит скорости, пауза). Старшие версии не читаем — пусть старый
    /// клиент не ломается о незнакомый JSON.
    private static let manifestVersion = 1

    // MARK: - Жизненный цикл

    private override init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        super.init()

        // Восстанавливаем список сразу: экран «Загрузки» создаётся после запуска
        // и не должен отдельно просить менеджер прочитать диск.
        loadPersisted()
    }

    // MARK: - Публичный API

    /// Поставить серию в загрузку.
    ///
    /// - Parameters:
    ///   - releaseId: релиз, к которому относится серия.
    ///   - sourceId: источник (`EpisodeSource.id`), внутри которого нумеруются позиции.
    ///   - position: номер серии внутри источника (с 1).
    ///   - title: подпись для экрана загрузок, например «Релиз — серия 1».
    ///   - url: прямой URL: media-плейлист HLS (`*.m3u8`) или прогрессивный MP4.
    ///
    /// Бросает `DownloadError` для ожидаемых случаев: `emptyURL`, `unsupportedProvider`
    /// (HTML-плеер вроде Kodik — качать нечего), `diskFull`. Ошибки файловой системы
    /// пробрасываются как есть (Cocoa-ошибки), их текст подходит для UI.
    ///
    /// Повторный вызов для той же серии безопасен: завершённая и уже идущая загрузка
    /// игнорируются, провалившаяся — перезапускается.
    func beginDownload(releaseId: Int,
                       sourceId: Int,
                       position: Int,
                       title: String,
                       url: URL) throws {
        let id = Self.identifier(releaseId: releaseId, sourceId: sourceId, position: position)

        if let existing = items.first(where: { $0.id == id }) {
            switch existing.state {
            case .completed, .queued, .downloading:
                return
            case .failed:
                break   // повторная попытка: обновляем запись и стартуем заново
            }
        }

        guard !url.absoluteString.isEmpty else { throw DownloadError.emptyURL }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.unsupportedProvider(url.absoluteString)
        }

        // Kodik отдаёт HTML-страницу плеера, а не медиафайл; такой URL до менеджера
        // доходить не должен, но подстрахуемся, чтобы `AVURLAsset` не качал html-мусор.
        if let host = url.host?.lowercased(), Self.htmlOnlyHosts.contains(where: { host.contains($0) }) {
            throw DownloadError.unsupportedProvider(host)
        }

        try ensureDownloadsDirectory()
        try ensureFreeSpace()

        let item = DownloadItem(id: id,
                                releaseId: releaseId,
                                sourceId: sourceId,
                                position: position,
                                title: title,
                                createdAt: Date(),
                                state: .queued,
                                localURL: nil)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
        persist()

        if isHLS(url) {
            startHLSDownload(id: id, title: item.humanTitle, url: url)
        } else {
            startProgressiveDownload(id: id, url: url)
        }
    }

    /// Остановить загрузку, не удаляя её из списка.
    ///
    /// Запись остаётся со статусом `.failed("Загрузка отменена")`: пользователь видит,
    /// что произошло, и может запустить серию снова или удалить запись через `remove`.
    /// Готовую загрузку отменить нельзя — она остаётся `.completed`.
    func cancel(id: String) {
        if let task = hlsTasks.removeValue(forKey: id) {
            task.cancel()
        }
        if let task = progressiveTasks.removeValue(forKey: id) {
            task.cancel()
        }

        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else {
            return
        }
        items[index].state = .failed(Self.cancelledMessage)
        persist()
    }

    /// Удалить загрузку из списка.
    ///
    /// - Parameter deleteFile: `true` — удалить и сам пакет с диска (обычный сценарий);
    ///   `false` — оставить файл (например, перед ручным переносом).
    func remove(id: String, deleteFile: Bool = true) {
        if let task = hlsTasks.removeValue(forKey: id) {
            task.cancel()
        }
        if let task = progressiveTasks.removeValue(forKey: id) {
            task.cancel()
        }
        if deleteFile {
            try? fileManager.removeItem(at: itemDirectory(for: id))
        }
        items.removeAll { $0.id == id }
        persist()
    }

    /// Прочитать манифест с диска и заменить `items` его содержимым.
    ///
    /// Вызывается автоматически из `init`. Публичный метод — для повторного чтения
    /// (после фонового восстановления сессии в будущем) и для тестов.
    ///
    /// Незавершённые загрузки после перезапуска помечаются `.failed`: объект задачи
    /// не переживает перезапуск процесса, а публичного resume у `AVAssetDownloadTask`
    /// нет (переподключение к фоновой сессии — этап 4 плана в `docs/OFFLINE.md`).
    /// Завершённые записи, у которых файл пропал (вычистили/удалили), отбрасываются.
    func loadPersisted() {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? decoder.decode(Manifest.self, from: data) else {
            return
        }
        guard manifest.version <= Self.manifestVersion else { return }

        let restored = manifest.items.compactMap { makeItem(from: $0) }
        items = restored

        // Записи без файла выбросили — почистим и манифест.
        if restored.count != manifest.items.count {
            persist()
        }
    }

    /// Записать текущее состояние в манифест.
    ///
    /// Ошибки записи намеренно проглатываются: манифест — вспомогательный слой,
    /// загрузки из-за него падать не должны. Прогресс сюда не входит (пишется только
    /// на переходах состояний), чтобы не трогать диск на каждом колбэке.
    func persist() {
        let manifest = Manifest(version: Self.manifestVersion,
                                items: items.map { PersistedItem(item: $0) })
        do {
            try ensureDownloadsDirectory()
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            // Манифест необязателен: при ошибке UI продолжит работать из памяти.
        }
    }

    /// Скачана ли конкретная серия и лежит ли файл на месте.
    func isDownloaded(releaseId: Int, sourceId: Int, position: Int) -> Bool {
        guard let item = item(releaseId: releaseId, sourceId: sourceId, position: position),
              case .completed(let localURL) = item.state else {
            return false
        }
        return fileManager.fileExists(atPath: localURL.path)
    }

    /// Запись загрузки для серии (удобно для UI: прогресс/ошибка/локальный файл).
    func item(releaseId: Int, sourceId: Int, position: Int) -> DownloadItem? {
        let id = Self.identifier(releaseId: releaseId, sourceId: sourceId, position: position)
        return items.first { $0.id == id }
    }

    // MARK: - Запуск задач

    /// HLS: `AVAssetDownloadTask` через `AVAssetDownloadConfiguration` (iOS 15+).
    ///
    /// `AVURLAsset` создаётся здесь же: AVFoundation сам скачает плейлист и сегменты.
    /// Один task = один вариант качества; при master-плейлисте вариант выбирает система.
    private func startHLSDownload(id: String, title: String, url: URL) {
        let asset = AVURLAsset(url: url)
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: title)
        let task = hlsSession.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = id
        hlsTasks[id] = task
        updateProgress(id: id, progress: 0)
        task.resume()
    }

    /// Прогрессивный MP4: обычный `URLSessionDownloadTask`, фоновая сессия его не качает.
    private func startProgressiveDownload(id: String, url: URL) {
        let task = progressiveSession.downloadTask(with: url)
        task.taskDescription = id
        progressiveTasks[id] = task
        updateProgress(id: id, progress: 0)
        task.resume()
    }

    // MARK: - Состояние

    /// Скачиваем ли мы HLS: по расширению пути (`.../index.m3u8?sign=...` — тоже m3u8,
    /// query в `pathExtension` не попадает).
    private func isHLS(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
    }

    /// Обновляет прогресс, не дёргая UI на каждые 0,5 %. Прогресс в манифест не пишем:
    /// при перезапуске задача всё равно не восстанавливается, а частые записи JSON
    /// на главном потоке дороже пользы.
    private func updateProgress(id: String, progress: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else {
            return
        }
        let clamped = min(max(progress, 0), 1)
        if case .downloading(let current) = items[index].state, abs(current - clamped) < 0.005 {
            return
        }
        items[index].state = .downloading(progress: clamped)
    }

    /// Завершение: файл перенесён в папку загрузок.
    private func markCompleted(id: String, localURL: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .completed(localURL)
        items[index].localURL = localURL
        hlsTasks[id] = nil
        progressiveTasks[id] = nil
        persist()
    }

    /// Провал: текст ошибки уже локализован для UI. Уже готовую загрузку не портим.
    private func markFailed(id: String, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if case .completed = items[index].state { return }
        items[index].state = .failed(message)
        hlsTasks[id] = nil
        progressiveTasks[id] = nil
        persist()
    }

    // MARK: - Файлы и диск

    /// `Application Support` — единственное место, которое система не чистит сама
    /// (в отличие от `Library/Caches`); манифест лежит прямо в нём.
    private var applicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    private var downloadsDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent(Self.downloadsDirectoryName, isDirectory: true)
    }

    private var manifestURL: URL {
        applicationSupportDirectory.appendingPathComponent(Self.manifestFileName, isDirectory: false)
    }

    /// Папка одной загрузки: `Application Support/AnixartDownloads/<id>`.
    private func itemDirectory(for id: String) -> URL {
        downloadsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func ensureDownloadsDirectory() throws {
        try fileManager.createDirectory(at: downloadsDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
        // Загрузки не должны попадать в iCloud-бэкап: серия 720p — это сотни мегабайт.
        excludeFromBackup(downloadsDirectory)
    }

    /// Подстраховка перед стартом: если места меньше `minimumFreeSpace`, сразу говорим
    /// «нет места», а не ждём ошибки на середине файла.
    private func ensureFreeSpace() throws {
        let attributes = try? fileManager.attributesOfFileSystem(
            forPath: applicationSupportDirectory.path
        )
        if let free = attributes?[.systemFreeSize] as? NSNumber,
           free.int64Value < Self.minimumFreeSpace {
            throw DownloadError.diskFull
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    /// Перенести готовый пакет из временной папки системы в `…/AnixartDownloads/<id>/`
    /// и вернуть его итоговый URL (он же попадёт в `DownloadItem.localURL`).
    ///
    /// Замечание: Apple для `didFinishDownloadingTo` советует не переносить `.movpkg`,
    /// а сохранять закладку на системный URL. Здесь пакет всё же переносится, потому что
    /// так требует хранилище проекта (`Application Support/AnixartDownloads/<id>`,
    /// относительный путь переживает смену пути контейнера при переустановке).
    /// Если на устройстве офлайн-воспроизведение перенесённого `.movpkg` не заработает —
    /// менять нужно только этот метод (хранить закладку и не трогать `location`).
    private func install(location: URL, id: String) throws -> URL {
        let directory = itemDirectory(for: id)
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
        let destination = directory.appendingPathComponent(location.lastPathComponent,
                                                           isDirectory: location.hasDirectoryPath)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: location, to: destination)
        excludeFromBackup(directory)
        return destination
    }

    // MARK: - Ошибки

    /// Локализованный текст для `.failed(...)`.
    private func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return Self.cancelledMessage
            case .userAuthenticationRequired, .noPermissionsToReadFile:
                return DownloadError.notAuthorized.errorDescription ?? urlError.localizedDescription
            default:
                break
            }
        }
        if Self.isOutOfSpace(error) {
            return DownloadError.diskFull.errorDescription ?? error.localizedDescription
        }
        return error.localizedDescription
    }

    private func message(forStatusCode statusCode: Int) -> String {
        switch statusCode {
        case 401, 403:
            return DownloadError.notAuthorized.errorDescription ?? "Сервер запретил загрузку"
        case 404, 410:
            // Подписанные ссылки живут ограниченно (RuTube ~24 ч), после этого нужен
            // повторный резолв — им занимается вызывающий код, а не менеджер.
            return "Ссылка на видео устарела — попробуйте снова"
        default:
            return "Сервер вернул ошибку \(statusCode)"
        }
    }

    /// `ENOSPC` без импорта Darwin/Glibc: код POSIX-ошибки один и тот же на Apple-платформах.
    private static let noSpacePOSIXCode = 28

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == noSpacePOSIXCode {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpace(underlying)
        }
        return false
    }

    // MARK: - Восстановление

    private func makeItem(from persisted: PersistedItem) -> DownloadItem? {
        switch persisted.state {
        case .completed:
            guard let fileName = persisted.localFileName else { return nil }
            let localURL = itemDirectory(for: persisted.id).appendingPathComponent(fileName,
                                                                                 isDirectory: false)
            guard fileManager.fileExists(atPath: localURL.path) else { return nil }
            return DownloadItem(id: persisted.id,
                                releaseId: persisted.releaseId,
                                sourceId: persisted.sourceId,
                                position: persisted.position,
                                title: persisted.title,
                                createdAt: persisted.createdAt,
                                state: .completed(localURL),
                                localURL: localURL)

        case .failed:
            return DownloadItem(id: persisted.id,
                                releaseId: persisted.releaseId,
                                sourceId: persisted.sourceId,
                                position: persisted.position,
                                title: persisted.title,
                                createdAt: persisted.createdAt,
                                state: .failed(persisted.message ?? Self.unknownFailureMessage),
                                localURL: nil)

        case .queued, .downloading:
            // Задача не переживает перезапуск процесса: показываем пользователю,
            // что загрузка прервана, а не «качается» вечно.
            return DownloadItem(id: persisted.id,
                                releaseId: persisted.releaseId,
                                sourceId: persisted.sourceId,
                                position: persisted.position,
                                title: persisted.title,
                                createdAt: persisted.createdAt,
                                state: .failed(Self.interruptedMessage),
                                localURL: nil)
        }
    }

    // MARK: - Вспомогательное

    private static func identifier(releaseId: Int, sourceId: Int, position: Int) -> String {
        "\(releaseId)-\(sourceId)-\(position)"
    }

    /// Хосты, которые отдают HTML-страницу плеера, а не медиафайл (Kodik, если ссылка
    /// всё-таки дошла до менеджера). Скачивать с них нечего — `docs/OFFLINE.md`.
    private static let htmlOnlyHosts = ["kodikplayer.com", "anixmirai.com"]

    private static let cancelledMessage = "Загрузка отменена"
    private static let interruptedMessage = "Загрузка прервана — попробуйте снова"
    private static let missingFileMessage = "Загрузка завершилась без файла"
    private static let unknownFailureMessage = "Неизвестная ошибка загрузки"

    // MARK: - Манифест

    /// Формат `anixart-downloads.json`. `DownloadItem` не `Codable` (и не должен им
    /// становиться — это контракт UI), поэтому состояние сериализуется отдельно.
    private struct Manifest: Codable {
        let version: Int
        let items: [PersistedItem]
    }

    private struct PersistedItem: Codable {
        enum State: String, Codable {
            case queued
            case downloading
            case completed
            case failed
        }

        let id: String
        let releaseId: Int
        let sourceId: Int
        let position: Int
        let title: String
        let createdAt: Date
        let state: State
        let progress: Double
        /// Имя файла/пакета внутри `AnixartDownloads/<id>/` (относительный путь,
        /// а не абсолютный: путь контейнера приложения меняется при переустановке).
        let localFileName: String?
        let message: String?

        init(item: DownloadItem) {
            self.id = item.id
            self.releaseId = item.releaseId
            self.sourceId = item.sourceId
            self.position = item.position
            self.title = item.title
            self.createdAt = item.createdAt

            switch item.state {
            case .queued:
                self.state = .queued
                self.progress = 0
                self.localFileName = nil
                self.message = nil
            case .downloading(let progress):
                self.state = .downloading
                self.progress = progress
                self.localFileName = nil
                self.message = nil
            case .completed(let localURL):
                self.state = .completed
                self.progress = 1
                self.localFileName = localURL.lastPathComponent
                self.message = nil
            case .failed(let message):
                self.state = .failed
                self.progress = 0
                self.localFileName = nil
                self.message = message
            }
        }
    }
}

// MARK: - AVAssetDownloadDelegate (HLS)

extension DownloadManager: AVAssetDownloadDelegate {

    /// Точный прогресс по HLS: доля скачанного времени от ожидаемого.
    ///
    /// Метод помечен deprecated в новых SDK, но это по-прежнему единственный способ
    /// получить «долю времени» (а не байты) и он совпадает с тем, что требует контракт.
    func urlSession(_ session: URLSession,
                    assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = assetDownloadTask.taskDescription, hlsTasks[id] != nil else { return }

        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { result, value in
            result + value.timeRangeValue.duration.seconds
        }
        updateProgress(id: id, progress: loaded / expected)
    }

    /// HLS готов: переносим `.movpkg` из временной папки в `AnixartDownloads/<id>/`.
    ///
    /// `location` после возврата из метода может исчезнуть, поэтому переносим сразу,
    /// синхронно. Сбой переноса (в том числе нехватка места) — это `.failed`.
    func urlSession(_ session: URLSession,
                    assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.taskDescription else { return }
        do {
            let localURL = try install(location: location, id: id)
            markCompleted(id: id, localURL: localURL)
        } catch {
            markFailed(id: id, message: message(for: error))
        }
    }

    /// Общий колбэк для HLS и MP4 (`URLSessionTaskDelegate`, который наследуют оба
    /// делегата). Успех обрабатывается в `didFinishDownloadingTo`; здесь только ошибки
    /// (включая отмену — пользователь получает «отменено», а не `NSURLErrorCancelled`).
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }

        if let error {
            markFailed(id: id, message: message(for: error))
            return
        }

        // `didFinishDownloadingTo` не пришёл, а задача завершилась «успешно»:
        // не оставляем запись в вечном `.downloading`.
        if let item = items.first(where: { $0.id == id }), item.isActive {
            markFailed(id: id, message: Self.missingFileMessage)
        }
        hlsTasks[id] = nil
        progressiveTasks[id] = nil
    }
}

// MARK: - URLSessionDownloadDelegate (прогрессивный MP4)

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        updateProgress(id: id, progress: progress)
    }

    /// MP4 готов. В отличие от HLS, HTTP-статус здесь известен: 401/403 — это
    /// «нужна авторизация», 404/410 — протухшая подписанная ссылка.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }

        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            markFailed(id: id, message: message(forStatusCode: response.statusCode))
            return
        }

        do {
            let localURL = try install(location: location, id: id)
            markCompleted(id: id, localURL: localURL)
        } catch {
            markFailed(id: id, message: message(for: error))
        }
    }
}
