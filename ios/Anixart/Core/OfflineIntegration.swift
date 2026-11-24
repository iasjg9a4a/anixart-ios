import Foundation
import SwiftUI

// MARK: - Страница в кэше

/// Снимок страницы списка релизов для офлайн-кэша.
///
/// `Paged` объявлен только как `Decodable` и не кодируется, поэтому положить его
/// в `OfflineCache` нельзя. Кэшируем собственный симметричный `Codable`-тип,
/// а наружу отдаём уже готовый массив `Release`.
struct CachedPage<Item: Codable>: Codable {
    let items: [Item]
    let totalCount: Int?
    let totalPageCount: Int?
    let currentPage: Int?
}

// MARK: - Интеграция с кэшем

/// Связка экранов с дисковым офлайн-кэшем.
///
/// Экраны не знают ни ключей, ни TTL: спрашивают `cachedCatalog(page:)` и
/// складывают свежие данные через `storeCatalog(...)`. Кэш необязателен —
/// при любой проблеме методы возвращают `nil` или ничего и не бросают ошибок.
enum OfflineIntegration {
    /// Каталог «Новинки»: 30 минут. Более старые новинки показывать не стоит.
    static let catalogMaxAge: TimeInterval = 30 * 60
    /// История: 10 минут — она меняется после каждой просмотренной серии.
    static let historyMaxAge: TimeInterval = 10 * 60
    /// Карточка релиза: сутки. Пока только копится, экран релиза ещё не читает.
    static let releaseMaxAge: TimeInterval = 24 * 60 * 60

    // MARK: Каталог

    /// Релизы каталога с диска; `nil`, если кэша нет, он устарел или пуст.
    static func cachedCatalog(page: Int) async -> [Release]? {
        await cachedReleases(key: CacheKey.catalog(page: page),
                             page: page,
                             maxAge: catalogMaxAge)
    }

    /// Сохраняет страницу каталога после успешной загрузки из сети.
    static func storeCatalog(_ releases: [Release],
                             page: Int,
                             totalCount: Int?,
                             totalPageCount: Int? = nil) async {
        await store(releases,
                    page: page,
                    totalCount: totalCount,
                    totalPageCount: totalPageCount,
                    key: CacheKey.catalog(page: page))
    }

    // MARK: История

    /// Релизы истории с диска; `nil`, если кэша нет, он устарел или пуст.
    static func cachedHistory(page: Int) async -> [Release]? {
        await cachedReleases(key: CacheKey.history(page: page),
                             page: page,
                             maxAge: historyMaxAge)
    }

    /// Сохраняет страницу истории после успешной загрузки из сети.
    static func storeHistory(_ releases: [Release],
                             page: Int,
                             totalCount: Int?,
                             totalPageCount: Int? = nil) async {
        await store(releases,
                    page: page,
                    totalCount: totalCount,
                    totalPageCount: totalPageCount,
                    key: CacheKey.history(page: page))
    }

    // MARK: Релиз

    /// Полная карточка релиза с диска (для будущих офлайн-страниц релиза).
    static func cachedRelease(id: Int) async -> Release? {
        guard id > 0 else { return nil }
        return await OfflineCache.shared.load(Release.self,
                                              for: CacheKey.release(id: id),
                                              maxAge: releaseMaxAge)
    }

    /// Сохраняет полную карточку релиза: пригодится, когда релиз откроют без сети.
    static func storeRelease(_ release: Release) async {
        guard release.id > 0 else { return }
        await OfflineCache.shared.save(release, for: CacheKey.release(id: release.id))
    }

    // MARK: Общее

    private static func cachedReleases(key: String,
                                      page: Int,
                                      maxAge: TimeInterval) async -> [Release]? {
        guard page > 0 else { return nil }
        let cached = await OfflineCache.shared.load(CachedPage<Release>.self,
                                                    for: key,
                                                    maxAge: maxAge)
        guard let items = cached?.items, !items.isEmpty else { return nil }
        return items
    }

    private static func store(_ releases: [Release],
                              page: Int,
                              totalCount: Int?,
                              totalPageCount: Int?,
                              key: String) async {
        // Пустой список не кэшируем: он затёр бы полезный офлайн-снимок.
        guard page > 0, !releases.isEmpty else { return }
        let snapshot = CachedPage(items: releases,
                                  totalCount: totalCount,
                                  totalPageCount: totalPageCount,
                                  currentPage: page)
        await OfflineCache.shared.save(snapshot, for: key)
    }
}

// MARK: - Индикатор

/// Пометка «Офлайн-данные»: экран отрисован из дискового кэша, а не из сети.
///
/// Живёт рядом с интеграцией, чтобы главная и история выглядели одинаково;
/// оформление — из `Theme`, как у прочих служебных состояний.
struct OfflineDataBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.caption2.weight(.semibold))

            Text("Офлайн-данные")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface, in: Capsule())
        .accessibilityLabel("Показаны офлайн-данные")
    }
}
