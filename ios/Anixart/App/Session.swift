import SwiftUI
import Combine

/// Глобальное состояние аккаунта.
@MainActor
final class Session: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var isAuthorized: Bool
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let api = APIClient.shared
    private let profileIdKey = "anixart.profile.id"

    init() {
        isAuthorized = TokenStore.shared.token != nil
    }

    /// id пользователя запоминается при входе: `profile/info` его не отдаёт.
    var profileId: Int? {
        let value = UserDefaults.standard.integer(forKey: profileIdKey)
        return value > 0 ? value : nil
    }

    func bootstrap() async {
        guard isAuthorized else { return }
        await refreshProfile()
    }

    func refreshProfile() async {
        guard isAuthorized, let id = profileId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            profile = try await api.profile(id: id)
            errorMessage = nil
        } catch {
            if let apiError = error as? APIError, apiError == .unauthorized {
                signOut()
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func signIn(login: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await api.signIn(login: login, password: password)
            TokenStore.shared.save(result.token)
            if let loaded = result.profile {
                UserDefaults.standard.set(loaded.id, forKey: profileIdKey)
                profile = loaded
            }
            isAuthorized = true
            await refreshProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Принять готовый токен (например, после QR-входа) и подтянуть профиль.
    /// `profileId` нужен, потому что `profile/info` не отдаёт id — его знает только
    /// ответ авторизации.
    func adopt(token: String, profileId: Int?) async {
        TokenStore.shared.save(token)
        if let profileId {
            UserDefaults.standard.set(profileId, forKey: profileIdKey)
        }
        isAuthorized = true
        errorMessage = nil
        await refreshProfile()
    }

    func signOut() {
        TokenStore.shared.clear()
        UserDefaults.standard.removeObject(forKey: profileIdKey)
        isAuthorized = false
        profile = nil
        errorMessage = nil
    }
}
