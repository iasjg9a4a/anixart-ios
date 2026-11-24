import Foundation

// MARK: - Политика

/// Правило повторных попыток для асинхронной операции.
///
/// Пауза перед повтором растёт экспоненциально и разбавляется случайной добавкой:
///
///     задержка(попытка) = initialDelay * pow(multiplier, попытка) + base * random(0...jitter)
///
/// `jitter` — доля от вычисленной задержки (0...1): случайный разброс нужен, чтобы
/// несколько клиентов не повторяли запрос строго одновременно.
struct RetryPolicy {
    /// Сколько всего попыток, включая первую. Значение < 1 приводится к одной попытке.
    let maxAttempts: Int
    /// Пауза перед первым повтором, секунды.
    let initialDelay: TimeInterval
    /// Во сколько раз растёт пауза с каждым следующим повтором.
    let multiplier: Double
    /// Доля случайной добавки к паузе: от 0 до 1 от текущей задержки.
    let jitter: Double

    /// Обычные запросы: до 3 попыток, паузы 0.4 и 0.8 с (+ до 20 % случайно).
    static let `default` = RetryPolicy(maxAttempts: 3,
                                       initialDelay: 0.4,
                                       multiplier: 2.0,
                                       jitter: 0.2)

    /// Одна попытка: помощник превращается в обычный вызов. Нужно для операций,
    /// которые нельзя выполнять дважды (отправка комментария, смена статуса).
    static let none = RetryPolicy(maxAttempts: 1, initialDelay: 0, multiplier: 1, jitter: 0)

    /// «Попробовать понастойчивее»: до 5 попыток с короткой стартовой паузой.
    static let aggressive = RetryPolicy(maxAttempts: 5,
                                        initialDelay: 0.2,
                                        multiplier: 1.8,
                                        jitter: 0.3)

    /// Задержка перед повтором после неудачной попытки `attempt` (нумерация с нуля).
    func delay(afterAttempt attempt: Int) -> TimeInterval {
        let index = max(0, attempt)
        let factor = multiplier > 0 ? multiplier : 1
        let base = max(0, initialDelay) * pow(factor, Double(index))
        let spread = min(max(jitter, 0), 1)
        return base + base * Double.random(in: 0...spread)
    }
}

// MARK: - Повторитель

/// Запуск асинхронной операции с повторами при сбоях.
enum Retry {
    /// Выполняет `operation` и повторяет её по `policy`, пока ошибка ретраибельна
    /// и попытки не исчерпаны. Возвращает результат первой успешной попытки.
    ///
    /// - Отмена задачи: `Task.checkCancellation()` вызывается перед каждой попыткой
    ///   и после паузы; при отмене пробрасывается `CancellationError`.
    /// - Исчерпание попыток: пробрасывается ошибка именно последней попытки, без обёрток.
    /// - Неретраибельная ошибка пробрасывается сразу, без лишней паузы.
    ///
    /// По умолчанию ретраибельной считается любая ошибка. Если повторять 401/403/404
    /// и ошибки разбора ответа не нужно, передайте готовую проверку `Retry.isRetryable`:
    ///
    ///     let release = try await Retry.run(isRetryable: Retry.isRetryable) {
    ///         try await APIClient.shared.release(id: 42)
    ///     }
    static func run<T>(_ policy: RetryPolicy = .default,
                       isRetryable: (Error) -> Bool = { _ in true },
                       operation: () async throws -> T) async throws -> T {
        let attempts = max(1, policy.maxAttempts)
        var attempt = 0

        while true {
            try Task.checkCancellation()

            do {
                return try await operation()
            } catch let cancellation as CancellationError {
                // Отменённую задачу не повторяем ни при каких настройках.
                throw cancellation
            } catch {
                // Последняя попытка или бессмысленная ошибка — сразу наружу, без паузы.
                guard isRetryable(error), attempt < attempts - 1 else { throw error }

                let delay = policy.delay(afterAttempt: attempt)
                attempt += 1
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                try Task.checkCancellation()
            }
        }
    }

    /// Готовое условие для `isRetryable:`.
    ///
    /// Повторяет сетевые сбои (`APIError.transport`), HTTP 5xx и HTTP 429;
    /// не повторяет 401/403/404, ошибки декодирования и прочие логические ошибки.
    /// Понимает любую ошибку, объявившую `RetryableError` (в приложении — `APIError`),
    /// незнакомые ошибки считает неретраибельными.
    static func isRetryable(_ error: Error) -> Bool {
        (error as? RetryableError)?.isRetryable ?? false
    }
}

// MARK: - Ретраибельность ошибок

/// Ошибка, которая сама знает, имеет ли смысл её повторять.
protocol RetryableError {
    /// `true` — повтор осмыслен (обрыв сети, 5xx, 429), `false` — нет (4xx, формат ответа).
    var isRetryable: Bool { get }
}

extension APIError: RetryableError {
    /// 5xx и 429 повторяем, 4xx и ошибки декодирования — нет.
    var isRetryable: Bool {
        switch self {
        case .transport:
            // Нет связи, таймаут, обрыв — самый частый повод для повтора.
            return true
        case .http(let code):
            // 5xx — сбой на сервере, 429 — просят притормозить. Прочие коды (4xx) — нет.
            return code >= 500 || code == 429
        case .unauthorized, .badURL, .api, .empty, .authUnavailable,
             .invalidCredentials, .decoding:
            // 401/403/404 приходят сюда как `.http`; `.decoding` — ответ не того формата.
            return false
        }
    }
}
