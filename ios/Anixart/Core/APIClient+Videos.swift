import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле
#endif

// MARK: - Видео релиза
//
// Контракт снят живыми запросами 24.11.2026 (HTTP 200, без авторизации):
//
//   GET video/release/92
//     → {"code":0, "release":{…}, "blocks":[5 шт.], "streaming_platforms":[…],
//        "last_videos":[25 шт.], "can_appeal":false}
//     `blocks` уже разложены сервером по категориям: в блоке `category` {id,name}
//     и `videos`. На релизе 92:
//       Трейлеры (id 1, 3 видео), Превью (2, 23), Опенинги (3, 4),
//       Эндинги (4, 4), Муз клипы (5, 4).
//     У видео ключи: id, release, category, hosting, title, image, url, timestamp,
//     player_url, is_favorite, favorites_count; `release`/`profile` модели не нужны.
//     Хостинги на этом релизе — YouTube (id 2) и ВКонтакте (id 3, vk).
//
//   GET video/release/categories
//     → {"code":0, "categories":[8 шт.]}: Трейлеры(1), Обзоры(7), Превью(2),
//       Опенинги(3), Каверы(6), Эндинги(4), Муз клипы(5), Другое(8).
//
// `last_videos` — последние добавленные видео всех категорий, без блоков. Это
// запасной источник: если сервер отдал пустой `blocks`, раскладываем последние
// видео по категориям сами, чтобы экран показал их в той же форме, что и блоки.
// Живых релизов, где `blocks` пуст, а `last_videos` не пуст, в пробах не
// встретилось (у релизов с 90+ видео есть и блоки, и last_videos; у релиза без
// видео оба пусты) — запасной путь проверен только сборкой.

extension APIClient {
    /// Видео на странице релиза, сгруппированные по категориям
    /// (`GET video/release/{releaseId}`).
    ///
    /// Возвращает блоки категорий как есть. Пустой `blocks` у релиза без видео —
    /// нормальный ответ, это пустой массив. Если категорий в ответе нет, а
    /// `last_videos` есть, они группируются в блоки по своей категории.
    func releaseVideos(releaseId: Int) async throws -> [ReleaseVideoBlock] {
        let response: ReleaseVideosResponse = try await request("video/release/\(releaseId)")
        try check(response.code)

        if let blocks = response.blocks, !blocks.isEmpty {
            return blocks
        }
        return Self.blocksByCategory(response.lastVideos ?? [])
    }

    /// Категории видео (`GET video/release/categories`) — общий справочник,
    /// из него приходят имена категорий для блоков `video/release/{releaseId}`.
    func videoCategories() async throws -> [VideoCategoryRef] {
        let response: VideoCategoriesResponse = try await request("video/release/categories")
        try check(response.code)
        return response.categories ?? []
    }
}

/// Ответ `video/release/categories`: `{"code":0,"categories":[{"id":1,"name":"Трейлеры"},…]}`.
/// Общая модель `ReleaseVideosResponse` не подходит — у неё нет поля `categories`.
private struct VideoCategoriesResponse: Decodable {
    let code: Int
    let categories: [VideoCategoryRef]?
}

private extension APIClient {
    /// Раскладывает `last_videos` по категориям, сохраняя порядок первого появления
    /// категории в ответе (сервер отдаёт видео свежими первыми).
    static func blocksByCategory(_ videos: [ReleaseVideo]) -> [ReleaseVideoBlock] {
        guard !videos.isEmpty else { return [] }

        var order: [Int] = []
        var groups: [Int: ReleaseVideoBlock] = [:]

        for video in videos {
            let key = video.category?.id ?? 0
            if var block = groups[key] {
                if block.videos == nil { block.videos = [] }
                block.videos?.append(video)
                groups[key] = block
            } else {
                order.append(key)
                groups[key] = ReleaseVideoBlock(category: video.category, videos: [video])
            }
        }

        return order.compactMap { groups[$0] }
    }
}
