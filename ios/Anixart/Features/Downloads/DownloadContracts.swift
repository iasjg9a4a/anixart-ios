import Foundation

/// Одна загрузка серии: то, что показывает экран «Загрузки» и что умеет ставить/удалять
/// `DownloadManager`.
///
/// Офлайн-скачивание поддерживают только нативные HLS-источники (AniLibria, RuTube,
/// AnixPlayer) — см. `docs/OFFLINE.md`. Kodik и Sibnet отдают HTML/подписанные ссылки,
/// которые нельзя положить в `AVAssetDownloadTask`.
struct DownloadItem: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case downloading(progress: Double)
        case completed(URL)
        case failed(String)
    }

    let id: String
    let releaseId: Int
    let sourceId: Int
    let position: Int
    let title: String
    let createdAt: Date
    var state: State
    /// Локальное расположение скачанного пакета (`.movpkg`), если готово.
    var localURL: URL?

    var humanTitle: String { title.isEmpty ? "Серия \(position)" : title }
    var isActive: Bool {
        switch state {
        case .queued, .downloading: return true
        case .completed, .failed: return false
        }
    }
}

enum DownloadError: LocalizedError, Equatable {
    case unsupportedProvider(String)
    case emptyURL
    case notAuthorized
    case diskFull

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let name):
            return "Офлайн-скачивание недоступно для «\(name)»"
        case .emptyURL:
            return "Сервер не вернул ссылку на видео"
        case .notAuthorized:
            return "Скачивание доступно только после входа"
        case .diskFull:
            return "Недостаточно места на устройстве"
        }
    }
}
