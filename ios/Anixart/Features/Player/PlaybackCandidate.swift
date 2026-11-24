import Foundation

/// Источник, который реально удалось подготовить к воспроизведению.
///
/// Нужен для автоподбора: если основной источник (например, Kodik) отдаёт битую
/// ссылку или его страница отвечает ошибкой, приложение пробует следующую озвучку
/// того же релиза и включает её без участия пользователя.
struct PlaybackCandidate: Equatable {
    let sourceId: Int
    let sourceName: String
    let target: PlaybackTarget
}

/// Классификация проблем основного источника.
enum PlaybackFallbackReason: Equatable {
    /// Сервер не вернул ссылку.
    case emptyURL
    /// Ссылка есть, но страница плеера отвечает ошибкой (HTTP >= 400).
    case providerHTTP(Int)
    /// Резолвер нативного потока не смог получить m3u8.
    case resolutionFailed(String)
    /// Провайдер не поддержан.
    case unsupported(String)

    var userHint: String {
        switch self {
        case .emptyURL:
            return "Сервер не вернул ссылку"
        case .providerHTTP(let code):
            return "Плеер ответил ошибкой \(code)"
        case .resolutionFailed(let text):
            return text
        case .unsupported(let name):
            return "Плеер «\(name)» не поддержан"
        }
    }
}
