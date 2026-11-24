import Foundation
import SwiftUI

// MARK: - Клиент QR-входа
//
// Контракт снят с живого beta-API 24.11.2026 и сверен с APK beta-11
// (`AuthApi` и `QrAuthResponse` из dex, см. analysis/):
//
//   POST auth/qr/create  form: device                     → code, key, secret, pin, expires_in, poll_interval
//   POST auth/qr/status  form: key, secret                → code + status (+ profileToken при успехе)
//   POST auth/qr/open    form: key          query: token  — только авторизованное устройство
//   POST auth/qr/confirm form: key, pin     query: token  — только авторизованное устройство
//   POST auth/qr/decline form: key          query: token  — только авторизованное устройство
//
// `status`: 0 — ждём ввода, 1 — код введён на другом устройстве, 2 — вход подтверждён.
// `code`:   0 — успех, 2 — код истёк/неизвестен, 3 — вход отклонён,
//           4 — слишком много попыток ввода кода, 6 — слишком много запросов.
//
// Живые пробы: create и status работают без авторизации; status принимает только
// form-urlencoded (`key` + `secret`), на JSON-тело отвечает 200 с пустым телом, на GET — 405.
// open/confirm/decline без `?token=` отвечают `{"code":401}`, поэтому с этого экрана
// (пользователь ещё не авторизован) они не вызываются.
//
// Живая проба спустя 15 минут после `expires_in`: status всё ещё `{"code":0,"status":0}` —
// сервер не гасит сессию по таймеру, истечение отсчитывает клиент (APK: expires_in + 2 * poll).
// `code`: 2 приходит на неизвестный/просроченный ключ.
//
// НЕ ПРОВЕРЕНО ЖИВЫМ ВХОДОМ: положительный ответ `status` (status = 2) с `profileToken` —
// подопытного аккаунта нет, схема взята из APK (`QrAuthResponse.profileToken`).
// Перед выдачей токена декодирование проверяет лишь его непустоту.

/// Тонкий клиент QR-входа: создаёт код, опрашивает его статус, умеет отклонять чужой вход.
struct QrAuthService {
    /// Параметры созданного кода. PIN — строка: сервер выдаёт и коды с ведущим нулём.
    struct Session: Equatable {
        let key: String
        let secret: String
        let pin: String
        let expiresIn: Int
        let pollInterval: Int
    }

    /// Состояние входа, которое вернул `auth/qr/status`.
    enum Status: Equatable {
        case waiting
        case scanned
        case confirmed(token: String, profileId: Int?)
        case declined
        case expired
        case tooManyAttempts
        case tooManyRequests
        case unknown(code: Int)
    }

    /// Ошибки клиента. Описания — готовый для пользователя текст.
    enum Failure: LocalizedError {
        case incompleteResponse
        case missingToken
        case rejected(code: Int)

        var errorDescription: String? {
            switch self {
            case .incompleteResponse:
                return "Сервер вернул неполные данные для входа по QR"
            case .missingToken:
                return "Сервер подтвердил вход, но не выдал токен"
            case .rejected(let code):
                if code == 6 {
                    return "Слишком много запросов. Попробуйте позже"
                }
                return "Сервер отклонил запрос на вход (код \(code))"
            }
        }
    }

    private struct CreatedResponse: Decodable {
        let code: Int
        let key: String?
        let secret: String?
        let pin: String?
        let expiresIn: Int?
        let pollInterval: Int?

        enum CodingKeys: String, CodingKey {
            case code, key, secret, pin
            case expiresIn = "expires_in"
            case pollInterval = "poll_interval"
        }
    }

    private struct StatusResponse: Decodable {
        let code: Int
        let status: Int?
        let profileToken: TokenPayload?
    }

    private struct TokenPayload: Decodable {
        let token: String
        /// id профиля: сервер отдаёт его вместе с токеном, без него не загрузить профиль.
        let id: Int?
    }

    private struct CodeResponse: Decodable {
        let code: Int
    }

    private static let formContentType = "application/x-www-form-urlencoded"
    /// Имя устройства увидит человек, подтверждающий вход на другом устройстве.
    private static let deviceName = "iPhone"

    private let api = APIClient.shared

    // MARK: - Запросы

    /// Создаёт новый код. Предыдущий код после этого недействителен.
    func create() async throws -> Session {
        let body = formBody(["device": Self.deviceName])
        let response: CreatedResponse = try await api.request(
            "auth/qr/create",
            method: "POST",
            body: body,
            contentType: Self.formContentType
        )

        guard response.code == 0 else { throw Failure.rejected(code: response.code) }
        guard let key = response.key, let secret = response.secret, let pin = response.pin else {
            throw Failure.incompleteResponse
        }
        return Session(
            key: key,
            secret: secret,
            pin: pin,
            expiresIn: max(1, response.expiresIn ?? 600),
            pollInterval: max(2, response.pollInterval ?? 3)
        )
    }

    /// Состояние кода. Сервер требует `key` и `secret` вместе: с одним параметром
    /// он отвечает 200 с пустым телом, поэтому второй не опционален.
    func status(key: String, secret: String) async throws -> Status {
        let body = formBody(["key": key, "secret": secret])
        let response: StatusResponse = try await api.request(
            "auth/qr/status",
            method: "POST",
            body: body,
            contentType: Self.formContentType
        )

        switch response.code {
        case 0:
            switch response.status ?? 0 {
            case 1:
                return .scanned
            case 2:
                guard let token = response.profileToken?.token, !token.isEmpty else {
                    throw Failure.missingToken
                }
                return .confirmed(token: token, profileId: response.profileToken?.id)
            default:
                return .waiting
            }
        case 2:
            return .expired
        case 3:
            return .declined
        case 4:
            return .tooManyAttempts
        case 6:
            return .tooManyRequests
        default:
            return .unknown(code: response.code)
        }
    }

    /// Отклоняет QR-вход. Требует `?token=` авторизованного устройства: без него сервер
    /// отвечает `{"code":401}` (проверено), поэтому экран ожидания метод не вызывает.
    func decline(key: String) async throws {
        let body = formBody(["key": key])
        let response: CodeResponse = try await api.request(
            "auth/qr/decline",
            method: "POST",
            body: body,
            contentType: Self.formContentType
        )
        guard response.code == 0 else { throw Failure.rejected(code: response.code) }
    }

    // MARK: - Кодирование формы

    private func formBody(_ fields: [String: String]) -> Data {
        let pairs = fields
            .map { "\($0.key)=\(formEncode($0.value))" }
            .sorted()
            .joined(separator: "&")
        return Data(pairs.utf8)
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Модель экрана

@MainActor
final class QrLoginViewModel: ObservableObject {
    /// Состояние экрана QR-входа.
    enum Phase: Equatable {
        case loading
        case waiting
        case success
        case expired
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var pin = ""
    @Published private(set) var secondsLeft = 0
    @Published private(set) var isScanned = false

    private let service = QrAuthService()
    private let onToken: (String, Int?) -> Void

    private var session: QrAuthService.Session?
    private var deadline: Date?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var isRunning = false
    private var consecutiveErrors = 0

    init(onToken: @escaping (String, Int?) -> Void) {
        self.onToken = onToken
    }

    // MARK: - Управление

    /// Создаёт код и запускает опрос. Повторный вызов перезапускает вход с новым кодом.
    func start() async {
        cancel()
        phase = .loading
        pin = ""
        secondsLeft = 0
        isScanned = false
        consecutiveErrors = 0
        isRunning = true

        do {
            let created = try await service.create()
            guard isRunning else { return }
            session = created
            pin = created.pin
            secondsLeft = created.expiresIn
            deadline = Date().addingTimeInterval(TimeInterval(created.expiresIn))
            phase = .waiting
            startTicker()
            startPolling(created)
        } catch {
            guard isRunning else { return }
            finish(.failed(error.localizedDescription))
        }
    }

    /// Останавливает таймер и опрос. Вызывается при закрытии экрана и перед «Повторить».
    ///
    /// Серверный `auth/qr/decline` здесь не вызывается: он требует токен авторизованного
    /// устройства, а на этом экране токена ещё нет — сервер ответит `{"code":401}`.
    func cancel() {
        isRunning = false
        session = nil
        deadline = nil
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Таймер

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard isRunning, case .waiting = phase, let deadline else { return }
        let left = Int(deadline.timeIntervalSinceNow.rounded(.up))
        secondsLeft = max(0, left)
        if left <= 0 {
            finish(.expired)
        }
    }

    // MARK: - Опрос статуса

    private func startPolling(_ session: QrAuthService.Session) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.poll(session)
        }
    }

    private func poll(_ session: QrAuthService.Session) async {
        let interval = UInt64(max(1, session.pollInterval)) * 1_000_000_000
        while !Task.isCancelled && isRunning {
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled, isRunning, self.session?.key == session.key else { return }

            do {
                let status = try await service.status(key: session.key, secret: session.secret)
                guard !Task.isCancelled, isRunning else { return }
                consecutiveErrors = 0
                if handle(status) {
                    return
                }
            } catch {
                guard !Task.isCancelled, isRunning else { return }
                // Одиночный обрыв связи не должен убивать вход: даём опросу три попытки.
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    finish(.failed(error.localizedDescription))
                    return
                }
            }
        }
    }

    /// - Returns: `true`, если вход закончился и опрос пора остановить.
    private func handle(_ status: QrAuthService.Status) -> Bool {
        switch status {
        case .waiting:
            return false
        case .scanned:
            isScanned = true
            return false
        case .confirmed(let token, let profileId):
            finish(.success)
            onToken(token, profileId)
            return true
        case .declined:
            finish(.failed("Вход отклонён на другом устройстве"))
            return true
        case .expired:
            finish(.expired)
            return true
        case .tooManyAttempts:
            finish(.failed("Слишком много неверных кодов. Создайте новый код"))
            return true
        case .tooManyRequests:
            finish(.failed("Слишком много запросов. Попробуйте позже"))
            return true
        case .unknown(let code):
            finish(.failed("Сервер вернул ошибку \(code). Попробуйте ещё раз"))
            return true
        }
    }

    private func finish(_ newPhase: Phase) {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
        phase = newPhase
    }

    // MARK: - Отображение

    /// PIN с пробелами между цифрами — так его проще продиктовать/прочитать.
    var displayPin: String {
        pin.map { String($0) }.joined(separator: " ")
    }

    /// «09:58» — сколько коду осталось жить.
    var countdownText: String {
        let total = max(0, secondsLeft)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Экран

struct QrLoginView: View {
    /// Вызывается один раз, когда вход подтверждён и сервер выдал токен.
    var onToken: (String, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: QrLoginViewModel

    init(onToken: @escaping (String, Int?) -> Void) {
        self.onToken = onToken
        _model = StateObject(wrappedValue: QrLoginViewModel(onToken: onToken))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    codeCard
                    hint
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .screenBackground()
            .navigationTitle("Вход по QR")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.start() }
            .onDisappear { model.cancel() }
        }
    }

    // MARK: - Код

    private var codeCard: some View {
        VStack(spacing: 14) {
            Text(cardTitle)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)

            if model.phase == .success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(model.displayPin.isEmpty ? "· · · ·" : model.displayPin)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .opacity(model.pin.isEmpty ? 0.4 : 1)
            }

            statusLine
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .cardSurface(cornerRadius: Theme.radius)
    }

    private var cardTitle: String {
        switch model.phase {
        case .loading:
            return "Создаём код для входа"
        case .waiting:
            return "Код для входа"
        case .success:
            return "Готово"
        case .expired:
            return "Код устарел"
        case .failed:
            return "Не удалось войти"
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(Theme.accent)
                Text("Подключаемся к серверу")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .waiting:
            VStack(spacing: 4) {
                Text(waitingText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if model.isScanned {
                    Text("Подтвердите вход в приложении Anixart")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        case .success:
            Text("Вход подтверждён")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        case .expired:
            Text("Код больше не действует — создайте новый")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        case .failed(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var waitingText: String {
        if model.isScanned {
            return "Код уже введён на другом устройстве"
        }
        return "Действует ещё \(model.countdownText)"
    }

    // MARK: - Пояснение и кнопки

    private var hint: some View {
        Text("Откройте Anixart на другом устройстве → Профиль → Войти по QR и введите код")
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await model.start() }
            } label: {
                Text("Повторить")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .foregroundStyle(.white)
            .disabled(isRetryDisabled)
            .opacity(isRetryDisabled ? 0.5 : 1)

            Button {
                model.cancel()
                dismiss()
            } label: {
                Text("Отменить")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .foregroundStyle(Theme.textPrimary)
        }
        .padding(.top, 4)
    }

    private var isRetryDisabled: Bool {
        switch model.phase {
        case .loading, .success:
            return true
        case .waiting, .expired, .failed:
            return false
        }
    }
}
