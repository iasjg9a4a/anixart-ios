import SwiftUI

private enum LibraryDestination: String, Identifiable {
    case history
    case favorites
    case notifications
    case friends
    case downloads
    case settings

    var id: String { rawValue }
}

private struct LibraryTile: View {
    let title: String
    let systemImage: String
    /// Число для бейджа в правом верхнем углу иконки. `nil` — бейджа нет.
    let badgeCount: Int?
    let action: () -> Void

    init(title: String, systemImage: String, badgeCount: Int? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.badgeCount = badgeCount
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 24)
                    badge
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .cardSurface()
        }
        .buttonStyle(.plain)
    }

    /// Красный кружок с числом непрочитанных поверх иконки.
    @ViewBuilder
    private var badge: some View {
        if let count = badgeCount, count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .frame(minWidth: 16, minHeight: 16)
                .background(Theme.accent, in: Circle())
                .offset(x: 4, y: -6)
                .accessibilityLabel("Непрочитанных уведомлений: \(count)")
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        NavigationStack {
            Group {
                if session.isAuthorized {
                    if let profile = session.profile {
                        ProfileContent(profile: profile)
                    } else if let message = session.errorMessage {
                        ErrorStateView(message: message) {
                            Task { await session.refreshProfile() }
                        }
                    } else {
                        LoadingView()
                    }
                } else {
                    LoginView()
                }
            }
            .screenBackground()
            .navigationTitle("Профиль")
        }
    }
}

// MARK: - Вход

private struct LoginView: View {
    @EnvironmentObject private var session: Session

    @State private var login = ""
    @State private var password = ""
    /// Открыт ли экран входа по QR-коду.
    @State private var isQrPresented = false
    /// QR-вход подтверждён и токен сохранён — показываем памятку, что делать дальше.
    @State private var showsSavedTokenNotice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Вход")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 24)

                Text("Логин и пароль от аккаунта Anixart.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                TextField("Логин", text: $login)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .cardSurface()

                SecureField("Пароль", text: $password)
                    .textContentType(.password)
                    .padding(14)
                    .cardSurface()

                Button {
                    Task { await session.signIn(login: login, password: password) }
                } label: {
                    HStack {
                        if session.isLoading {
                            ProgressView().tint(.white)
                        }
                        Text("Войти")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .foregroundStyle(.white)
                .disabled(login.isEmpty || password.isEmpty || session.isLoading)
                .opacity(login.isEmpty || password.isEmpty ? 0.5 : 1)

                qrButton

                if showsSavedTokenNotice {
                    savedTokenNotice
                }

                if let message = session.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Каталог, поиск и просмотр доступны без входа. Аккаунт нужен для списков, истории и синхронизации прогресса.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20)
        }
        .sheet(isPresented: $isQrPresented) {
            QrLoginView(onToken: { token, profileId in
                Task { await session.adopt(token: token, profileId: profileId) }
            })
        }
    }

    /// Вторичная кнопка под основным действием: прозрачный фон, рамка и акцентный текст.
    private var qrButton: some View {
        Button {
            showsSavedTokenNotice = false
            isQrPresented = true
        } label: {
            HStack(spacing: 8) {
                if session.isLoading {
                    ProgressView()
                        .tint(Theme.accent)
                } else {
                    Image(systemName: "qrcode")
                        .font(.subheadline)
                }
                Text("Войти по QR-коду")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .foregroundStyle(Theme.accent)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
        .disabled(session.isLoading)
        .opacity(session.isLoading ? 0.5 : 1)
    }

    /// Памятка после QR-входа: токен уже в Keychain, но текущая `Session` его не перечитает.
    private var savedTokenNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Токен сохранён")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Перезапустите приложение — профиль загрузится автоматически.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// Вход по QR подтверждён: токен сразу кладём в Keychain, чтобы он пережил перезапуск
    /// (`Session` читает его в `init`). Переключить текущую сессию отсюда нельзя: у
    /// `Session.isAuthorized` приватный setter, а публичного `adopt(token:)` в `Session` нет.
    private func handleQrToken(_ token: String) {
        // Оставлено для совместимости: токен принимает Session.adopt(token:profileId:).
        TokenStore.shared.save(token)
    }
}

// MARK: - Профиль

private struct ProfileContent: View {
    let profile: Profile

    @EnvironmentObject private var session: Session
    @StateObject private var lists = ProfileListsViewModel()
    @State private var presentedLibrary: LibraryDestination?
    /// Непрочитанные уведомления — для бейджа на плитке «Уведомления».
    @State private var unreadNotifications = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                stats
                librarySection
                listSection
            }
            .padding(.bottom, 32)
        }
        .refreshable {
            await session.refreshProfile()
            await lists.load(lists.status)
            await refreshUnreadNotifications()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Выйти") { session.signOut() }
                    .font(.footnote)
            }
        }
        .sheet(item: $presentedLibrary, onDismiss: {
            // В «Уведомлениях» могли нажать «Прочитать все» — счётчик перезапрашиваем.
            Task { await refreshUnreadNotifications() }
        }) { destination in
            switch destination {
            case .history:
                HistoryView()
            case .favorites:
                FavoritesView()
            case .notifications:
                NotificationsView()
            case .friends:
                FriendsView(profileId: profile.id)
            case .downloads:
                DownloadsView()
            case .settings:
                SettingsView()
            }
        }
        .task {
            await lists.load(.watching)
            await refreshUnreadNotifications()
        }
    }

    /// Счётчик непрочитанных для бейджа. Требует входа, ошибки не показываем:
    /// бейдж не критичен, при сбое остаётся прежнее значение.
    @MainActor
    private func refreshUnreadNotifications() async {
        guard session.isAuthorized else {
            unreadNotifications = 0
            return
        }

        do {
            unreadNotifications = max(try await APIClient.shared.notificationCount(), 0)
        } catch {
            // Молча игнорируем: счётчик обновится при следующей попытке.
        }
    }

    private var librarySection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ], spacing: 10) {
            LibraryTile(title: "История", systemImage: "clock.arrow.circlepath") {
                presentedLibrary = .history
            }
            LibraryTile(title: "Избранное", systemImage: "heart.fill") {
                presentedLibrary = .favorites
            }
            LibraryTile(
                title: "Уведомления",
                systemImage: "bell.fill",
                badgeCount: unreadNotifications > 0 ? unreadNotifications : nil
            ) {
                presentedLibrary = .notifications
            }
            LibraryTile(title: "Друзья", systemImage: "person.2.fill") {
                presentedLibrary = .friends
            }
            LibraryTile(title: "Загрузки", systemImage: "arrow.down.circle.fill") {
                presentedLibrary = .downloads
            }
            LibraryTile(title: "Настройки", systemImage: "gearshape.fill") {
                presentedLibrary = .settings
            }
        }
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RemoteImage(urlString: profile.avatar)
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.separator, lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.title3.bold())
                        .foregroundStyle(Theme.textPrimary)
                    if profile.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                if let status = profile.status, !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var stats: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ], spacing: 10) {
            ProfileStat(value: profile.watchingCount, title: "Смотрю")
            ProfileStat(value: profile.planCount, title: "В планах")
            ProfileStat(value: profile.completedCount, title: "Просмотрено")
            ProfileStat(value: profile.holdOnCount, title: "Отложено")
            ProfileStat(value: profile.droppedCount, title: "Брошено")
            ProfileStat(value: profile.watchedEpisodeCount, title: "Серий")
        }
        .padding(.horizontal, 16)
    }

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProfileListStatus.allCases) { status in
                        Button {
                            Task { await lists.load(status) }
                        } label: {
                            ChipView(text: status.title, selected: lists.status == status)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            if lists.isLoading {
                LoadingView().frame(height: 160)
            } else if let message = lists.errorMessage {
                ErrorStateView(message: message) {
                    Task { await lists.load(lists.status) }
                }
                .frame(height: 200)
            } else if lists.items.isEmpty {
                Text("Список пуст")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ], alignment: .leading, spacing: 16) {
                    ForEach(lists.items) { release in
                        NavigationLink {
                            ReleaseView(releaseId: release.id)
                        } label: {
                            ReleaseCard(release: release, posterWidth: 100)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct ProfileStat: View {
    let value: Int?
    let title: String

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value ?? 0)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .cardSurface()
    }
}

@MainActor
final class ProfileListsViewModel: ObservableObject {
    @Published private(set) var status: ProfileListStatus = .watching
    @Published private(set) var items: [Release] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let api = APIClient.shared

    func load(_ status: ProfileListStatus) async {
        self.status = status
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await api.profileList(status: status, page: 1)
            items = page.content
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }
}
