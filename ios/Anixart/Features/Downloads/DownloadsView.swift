import Foundation
import SwiftUI

// MARK: - Экран «Загрузки»

/// Список офлайн-скачанных серий: прогресс, отмена и удаление.
///
/// Офлайн-скачивание поддерживают только нативные HLS-источники (AniLibria, RuTube,
/// AnixPlayer) — см. `docs/OFFLINE.md`. Данными владеет `DownloadManager`: экран
/// только показывает его `items` и вызывает `cancel`/`remove`, ничего не досчитывая.
struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared

    /// Серия, для которой открыт диалог подтверждения удаления файла.
    /// `DownloadItem` — value-тип, поэтому копия в состоянии безопасна.
    @State private var pendingDeletion: DownloadItem?

    /// Новые загрузки — сверху: `createdAt` растёт при каждом добавлении.
    private var sortedItems: [DownloadItem] {
        manager.items.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .screenBackground()
                .navigationTitle("Загрузки")
                .navigationBarTitleDisplayMode(.large)
                .alert("Удалить серию?", isPresented: isDeleteConfirmationPresented) {
                    Button("Удалить", role: .destructive) {
                        deletePendingItem()
                    }
                    Button("Отмена", role: .cancel) {
                        pendingDeletion = nil
                    }
                } message: {
                    Text("Скачанный файл будет удалён с устройства.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if sortedItems.isEmpty {
            emptyState
        } else {
            list
        }
    }

    // MARK: - Список

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(sortedItems) { item in
                    DownloadRow(
                        item: item,
                        onCancel: { manager.cancel(id: item.id) },
                        onDelete: { requestDeletion(of: item) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textTertiary)

            Text("Скачанных серий нет")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Скачивание доступно для нативных плееров (AniLibria, RuTube, AnixPlayer). Серии добавляются из карточки релиза.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    // MARK: - Удаление

    /// Готовую серию удаляем только после подтверждения, а неудачную — сразу:
    /// пользователь уже увидел ошибку и отдельного вопроса она не требует.
    private func requestDeletion(of item: DownloadItem) {
        if case .completed = item.state {
            pendingDeletion = item
        } else {
            manager.remove(id: item.id)
        }
    }

    private func deletePendingItem() {
        guard let item = pendingDeletion else { return }
        manager.remove(id: item.id)
        pendingDeletion = nil
    }

    /// `Binding`, а не два `Bool`/`item`: диалог закрывается и кнопкой, и свайпом,
    /// в обоих случаях состояние должно очиститься.
    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }
}

// MARK: - Карточка загрузки

private struct DownloadRow: View {
    let item: DownloadItem
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            stateBlock
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // `humanTitle` — название релиза, а если оно не пришло, «Серия N».
                Text(item.humanTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text("Серия \(item.position)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            trailingButton
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if item.isActive {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Отменить скачивание")
        } else if case .completed = item.state {
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Удалить скачанную серию")
        }
    }

    @ViewBuilder
    private var stateBlock: some View {
        switch item.state {
        case .queued:
            progressBlock(value: 0, status: "В очереди")
        case .downloading(let progress):
            progressBlock(value: progress, status: "Скачивание")
        case .completed:
            completedBlock
        case .failed(let message):
            failedBlock(message)
        }
    }

    private func progressBlock(value: Double, status: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: clamped(value))
                .tint(Theme.accent)

            HStack(spacing: 6) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 0)

                Text("\(percent(value))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Размер серии `DownloadItem` не отдаёт, поэтому у готовой загрузки только статус.
    private var completedBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.accent)

            Text("Скачано")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func failedBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onDelete) {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.caption2)

                    Text("Удалить")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Удалить неудачную загрузку")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func percent(_ value: Double) -> Int {
        Int((clamped(value) * 100).rounded())
    }
}
