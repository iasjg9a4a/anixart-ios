import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // на Linux URLSession живёт в отдельном модуле
#endif

// MARK: - Легальные площадки релиза
//
// Контракт снят живыми запросами 24.11.2026 (HTTP 200, без авторизации):
//
//   GET release/streaming/platform/92
//     → {"code":0,
//        "content":[{"id":4,"name":"Netflix",
//                    "icon":"https://s3.anixmirai.com/streamings/netflix.jpg",
//                    "url":"https://www.netflix.com/title/70308188",
//                    "position":1}],
//        "total_count":1,"total_page_count":0,"current_page":0}
//
//   GET release/streaming/platform/1
//     → {"code":0,"content":[],"total_count":0,…}
//
// Пустой `content` у релиза без официальных площадок — нормальный ответ,
// поэтому возвращается пустой массив, а не ошибка.

extension APIClient {
    /// Официальные площадки, где релиз доступен легально
    /// (`GET release/streaming/platform/{releaseId}`).
    func releaseStreamingPlatforms(releaseId: Int) async throws -> [StreamingPlatform] {
        let response: StreamingPlatformsResponse = try await request("release/streaming/platform/\(releaseId)")
        try check(response.code)
        return response.content ?? []
    }
}
