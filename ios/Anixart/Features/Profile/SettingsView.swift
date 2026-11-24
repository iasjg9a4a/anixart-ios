import SwiftUI
import Foundation

/// Настройки клиента: аккаунт, профиль, уведомления, темы, сведения о сборке и локальный кэш.
///
/// Чтение профиля и уведомлений идёт из `.task` через `APIClient+Preferences`.
/// Запись на сервер здесь ровно одна — статус профиля (`profile/preference/status/edit`).
/// Настройки уведомлений и выбор темы API менять не умеет, поэтому оба списка
/// показываются только для чтения.
struct SettingsView: View {
    @EnvironmentObject private var session: Session

    @State private var showClearCacheConfirm = false
    @State private var showCacheCleared = false

    /// Sheet «Изменить статус».
    @State private var showStatusEditor = false

    /// Ответ `profile/preference/my`: доступные темы и `selected_theme_id`.
    @State private var preferences: AccountPreferences?
    /// Ответ `profile/preference/notification/my`.
    @State private var notificationSettings: AccountPreferences?
    @State private var isLoadingPreferences = false
    @State private var isLoadingNotifications = false
    /// `.task` стартует после первого кадра, поэтому до первого ответа показываем
    /// не «пустой сервер», а загрузку. `nil` у уведомлений — валидный ответ.
    @State private var hasLoadedPreferences = false
    @State private var hasLoadedNotifications = false
    @State private var preferencesError: String?
    @State private var notificationsError: String?

    /// Заглушка: настоящий репозиторий проекта появится позже.
    private let repositoryURL = URL(string: "https://github.com")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    accountSection
                    if session.isAuthorized {
                        profileSection
                    }
                    appearanceSection
                    notificationsSection
                    themesSection
                    aboutSection
                    dataSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .screenBackground()
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadPreferences()
                await loadNotificationSettings()
            }
            .sheet(isPresented: $showStatusEditor) {
                // Настройки открываются из sheet профиля: передаём сессию явно,
                // чтобы не зависеть от наследования environment во вложенных sheet.
                StatusEditorSheet(initialStatus: profileStatus)
                    .environmentObject(session)
            }
        }
    }

    // MARK: - Аккаунт

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader("Аккаунт")

            VStack(spacing: 0) {
                SettingsRow(title: "Логин", value: session.profile?.displayName ?? "—")
                rowDivider
                SettingsRow(title: "Статус", value: session.isAuthorized ? "Вы вошли" : "Гость")

                if session.isAuthorized {
                    rowDivider
                    Button {
                        session.signOut()
                    } label: {
                        Text("Выйти")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .cardSurface()
        }
    }

    // MARK: - Профиль

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader("Профиль")

            VStack(spacing: 0) {
                SettingsRow(title: "Статус", value: statusText)
                rowDivider
                Button {
                    showStatusEditor = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                        Text("Изменить")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .cardSurface()
        }
    }

    // MARK: - Внешний вид

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader("Внешний вид")

            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: "Тема", value: "Тёмная")
                rowDivider
                Text("Светлая тема пока не поддерживается: интерфейс всегда тёмный.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .cardSurface()
        }
    }

    // MARK: - Уведомления

    /// Тумблеры только читают ответ сервера: в API нет метода записи настроек
    /// уведомлений, поэтому строки отключены.
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader("Уведомления")

            VStack(alignment: .leading, spacing: 0) {
                if !session.isAuthorized {
                    SettingsNoteRow(text: "Доступно после входа в аккаунт.")
                } else if isLoadingNotifications || !hasLoadedNotifications {
                    SettingsLoadingRow(text: "Загружаем настройки уведомлений…")
                } else if let message = notificationsError {
                    SettingsRetryRow(text: message) {
                        Task { await loadNotificationSettings() }
                    }
                } else if notificationItems.isEmpty {
                    SettingsNoteRow(text: "Сервер не прислал настройки уведомлений.")
                } else {
                    ForEach(notificationItems) { item in
                        if item.id != notificationItems.first?.id {
                            rowDivider
                        }
                        NotificationToggleRow(title: item.title, isOn: item.isOn)
                    }
                }
            }
            .cardSurface()

            Text("Изменение уведомлений — в следующей версии: сейчас настройки только для чтения.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// Подтверждённые поля ответа `profile/preference/notification/my`.
    /// Показываем только те, что сервер реально прислал (остальные — `nil`).
    private var notificationItems: [NotificationSettingItem] {
        guard let settings = notificationSettings else { return [] }

        var items: [NotificationSettingItem] = []
        func add(_ value: Bool?, _ id: String, _ title: String) {
            guard let value = value else { return }
            items.append(NotificationSettingItem(id: id, title: title, isOn: value))
        }

        add(settings.isReleaseTypeNotificationsEnabled, "release-type", "Новые релизы")
        add(settings.isEpisodeNotificationsEnabled, "episode", "Новые эпизоды")
        add(settings.isFirstEpisodeNotificationEnabled, "first-episode", "Первый эпизод")
        add(settings.isRelatedReleaseNotificationsEnabled, "related-release", "Связанные релизы")
        add(settings.isCommentNotificationsEnabled, "comment", "Комментарии")
        add(settings.isMyCollectionCommentNotificationsEnabled, "my-collection-comment",
            "Комментарии в моих коллекциях")
        add(settings.isArticleNotificationsEnabled, "article", "Новые статьи")
        add(settings.isMyArticleCommentNotificationsEnabled, "my-article-comment",
            "Комментарии к моим статьям")
        add(settings.isReportProcessNotificationsEnabled, "report-process", "Обработка жалоб")

        return items
    }

    // MARK: - Темы

    /// `availableThemes()` — тонкая обёртка над `preferences()` (тот же
    /// `profile/preference/my`), а выбранная тема есть только в ответе целиком,
    /// поэтому оба значения берутся из одного запроса в `.task`.
    private var themesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader("Темы")

            VStack(alignment: .leading, spacing: 0) {
                if !session.isAuthorized {
                    SettingsNoteRow(text: "Доступно после входа в аккаунт.")
                } else if isLoadingPreferences || !hasLoadedPreferences {
                    SettingsLoadingRow(text: "Загружаем темы…")
                } else if let message = preferencesError {
                    SettingsRetryRow(text: message) {
                        Task { await loadPreferences() }
                    }
                } else if availableThemes.isEmpty {
                    SettingsNoteRow(text: "Сервер не прислал список тем.")
                } else {
                    ForEach(availableThemes) { theme in
                        if theme.id != availableThemes.first?.id {
                            rowDivider
                        }
                        themeRow(theme)
                    }
                }
            }
            .cardSurface()

            Text("Выбор темы пока не сохраняется: отметка показывает тему аккаунта на сервере.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var availableThemes: [AccountTheme] {
        preferences?.availableThemes ?? []
    }

    private func themeRow(_ theme: AccountTheme) -> some View {
        let isSelected = theme.id == preferences?.selectedThemeId

        return HStack(spacing: 8) {
            Text(theme.displayName)
                .font(.subheadline)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text("Текущая")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    // MARK: - О приложении

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader("О приложении")

            VStack(spacing: 0) {
                SettingsRow(title: "Версия", value: appVersion)
                rowDivider
                SettingsRow(title: "Приложение", value: "Клиент Anixart для iOS")
                rowDivider
                Link(destination: repositoryURL) {
                    HStack(spacing: 6) {
                        Text("Репозиторий")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 8)
                        Text("github.com")
                            .font(.subheadline)
                            .foregroundStyle(Theme.accent)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
            }
            .cardSurface()
        }
    }

    // MARK: - Данные

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader("Данные")

            VStack(spacing: 0) {
                Button {
                    showClearCacheConfirm = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                        Text("Очистить кэш изображений")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .alert("Очистить кэш изображений?", isPresented: $showClearCacheConfirm) {
                    Button("Отмена", role: .cancel) {}
                    Button("Очистить", role: .destructive) {
                        clearImageCache()
                    }
                } message: {
                    Text("Будут удалены сохранённые постеры, аватары и обложки. Профиль и вход останутся на месте.")
                }
            }
            .cardSurface()

            Text("Кэш ускоряет повторную загрузку картинок. Его можно очистить в любой момент.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .alert("Готово", isPresented: $showCacheCleared) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text("Кэш изображений очищен.")
        }
    }

    // MARK: - Сеть

    /// `profile/preference/my`: доступные темы и выбранная тема.
    @MainActor
    private func loadPreferences() async {
        guard session.isAuthorized else { return }
        guard !isLoadingPreferences else { return }

        isLoadingPreferences = true
        preferencesError = nil
        defer {
            isLoadingPreferences = false
            hasLoadedPreferences = true
        }

        do {
            preferences = try await APIClient.shared.preferences()
        } catch {
            preferencesError = error.localizedDescription
        }
    }

    /// `profile/preference/notification/my`: только чтение, записи в API нет.
    @MainActor
    private func loadNotificationSettings() async {
        guard session.isAuthorized else { return }
        guard !isLoadingNotifications else { return }

        isLoadingNotifications = true
        notificationsError = nil
        defer {
            isLoadingNotifications = false
            hasLoadedNotifications = true
        }

        do {
            notificationSettings = try await APIClient.shared.notificationPreferences()
        } catch {
            notificationsError = error.localizedDescription
        }
    }

    // MARK: - Служебное

    /// Статус из профиля сессии; после сохранения обновляется `session.refreshProfile()`.
    private var profileStatus: String {
        (session.profile?.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusText: String {
        profileStatus.isEmpty ? "—" : profileStatus
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private func clearImageCache() {
        URLCache.shared.removeAllCachedResponses()
        // iOS 16 не показывает второй alert в том же run loop, где закрывается первый.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showCacheCleared = true
        }
    }
}

// MARK: - Редактор статуса

/// Sheet смены статуса профиля. Пишет на сервер только по кнопке «Сохранить»:
/// `textarea` → `profile/preference/status/edit` → `session.refreshProfile()`.
/// Ошибка показывается alert'ом здесь же, sheet остаётся открытым, чтобы текст не потерялся.
private struct StatusEditorSheet: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showSaveError = false

    /// Ограничение сервера: статус — до 100 символов.
    private let limit = 100

    init(initialStatus: String) {
        _text = State(initialValue: initialStatus)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Статус", text: limitedText)
                    .textInputAutocapitalization(.sentences)
                    .padding(14)
                    .cardSurface()
                    .disabled(isSaving)

                HStack(spacing: 8) {
                    Text("До \(limit) символов")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                    Text("\(text.count)/\(limit)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(text.count >= limit ? Theme.accent : Theme.textTertiary)
                }

                Text("Пустой статус убирает его из профиля.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenBackground()
            .navigationTitle("Статус")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена", role: .cancel) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .tint(Theme.accent)
                        } else {
                            Text("Сохранить")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                }
            }
            .alert("Не удалось сохранить статус", isPresented: $showSaveError) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(saveError ?? "Неизвестная ошибка")
            }
        }
    }

    /// `@Binding` в заглушке SwiftUI не компилируется (Binding — обычный класс),
    /// поэтому лимит длины живёт в сеттере собственного `Binding`.
    private var limitedText: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                text = String(newValue.prefix(limit))
            }
        )
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true

        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await APIClient.shared.updateStatus(value)
                await session.refreshProfile()
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
                showSaveError = true
            }
        }
    }
}

// MARK: - Элементы оформления

/// Заголовок секции: мелкий, серый, капсом — как в оригинальном Anixart.
private struct SettingsSectionHeader: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 4)
    }
}

/// Строка «название — значение» внутри карточки.
private struct SettingsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

/// Пояснение внутри карточки: гость, пустой ответ сервера и т.п.
private struct SettingsNoteRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }
}

/// Состояние загрузки секции.
private struct SettingsLoadingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Theme.accent)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

/// Ошибка загрузки секции с кнопкой повтора.
private struct SettingsRetryRow: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Повторить", action: retry)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Пара «название настройки — значение» из ответа сервера.
private struct NotificationSettingItem: Identifiable {
    let id: String
    let title: String
    let isOn: Bool
}

/// Тумблер только для чтения.
private struct NotificationToggleRow: View {
    let title: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ReadOnlySwitch(isOn: isOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .disabled(true)
    }
}

/// Внешний вид системного тумблера без интерактивности: в заглушке SwiftUI
/// (tools/StubSwiftUI/StubKit.swift) `Toggle` не объявлен, а секция всё равно
/// должна быть только для чтения — поэтому переключатель нарисован вручную.
private struct ReadOnlySwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.accent : Theme.surfaceHigh)
            .frame(width: 40, height: 24)
            .overlay(
                Circle()
                    .fill(isOn ? Color.white : Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .padding(3),
                alignment: isOn ? .trailing : .leading
            )
            .accessibilityLabel(isOn ? "Включено" : "Выключено")
    }
}
