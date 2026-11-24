import XCTest
import Foundation
@testable import Anixart

/// Видео на странице релиза: разбор хостинга (YouTube/VK/RuTube), терпимое
/// декодирование ссылки на хостинг, срез живого ответа `GET video/release/{id}`,
/// извлечение YouTube-id, цель плеера и fallback заголовка.
///
/// Сети нет: срез реального ответа API (релиз 92, 24.11.2026) вписан строкой,
/// поэтому тест не зависит ни от сети, ни от `tools/fixtures`.
final class ReleaseVideoTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Вспомогательные

    private func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("Некорректный URL в тесте: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    /// Конструктор видео, чтобы не повторять в каждом тесте 11 полей модели.
    private func makeVideo(
        title: String? = nil,
        url: String? = nil,
        playerURL: String? = nil,
        hosting: VideoHostingRef? = nil,
        category: VideoCategoryRef? = nil
    ) -> ReleaseVideo {
        ReleaseVideo(
            id: 1,
            releaseId: 1,
            title: title,
            image: nil,
            url: url,
            playerURL: playerURL,
            hosting: hosting,
            category: category,
            timestamp: nil,
            favoritesCount: nil,
            isFavorite: nil
        )
    }

    // MARK: - 1. Определение хостинга

    func testHostingDetect() {
        // Имена хостингов в живом API: "YouTube", "ВКонтакте", "RuTube".
        XCTAssertEqual(ReleaseVideoHosting.detect(url: nil, hosting: "YouTube"), ReleaseVideoHosting.youtube)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: nil, hosting: "youtube"), ReleaseVideoHosting.youtube)

        // YouTube узнаётся и по ссылке; регистр хоста не важен.
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://www.YouTube.com/watch?v=JHuILzpmR28"), hosting: nil),
                       ReleaseVideoHosting.youtube)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://youtu.be/NN2fBRNqdWs"), hosting: nil),
                       ReleaseVideoHosting.youtube)

        // «ВКонтакте» приходит с vk.com-ссылками: имя кириллическое, латинского "vk"
        // в нём нет, поэтому хостинг распознаётся по URL (как в живом ответе).
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://vk.com/video-92067374_456239922"), hosting: "ВКонтакте"),
                       ReleaseVideoHosting.vk)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://vk.com/video_ext.php?oid=-1&id=2&hash=x"), hosting: nil),
                       ReleaseVideoHosting.vk)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://vkvideo.ru/video-1_2"), hosting: nil),
                       ReleaseVideoHosting.vk)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: nil, hosting: "VK"), ReleaseVideoHosting.vk)

        XCTAssertEqual(ReleaseVideoHosting.detect(url: nil, hosting: "RuTube"), ReleaseVideoHosting.rutube)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: nil, hosting: "rutube"), ReleaseVideoHosting.rutube)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://rutube.ru/video/abcdef/"), hosting: nil),
                       ReleaseVideoHosting.rutube)

        // Sibnet-видео (video/release/92: трейлеры/опенинги на video.sibnet.ru).
        XCTAssertEqual(ReleaseVideoHosting.detect(url: nil, hosting: "Sibnet"), ReleaseVideoHosting.sibnet)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://video.sibnet.ru/shell.php?videoid=1&d=1&s=x"),
                                                   hosting: nil),
                       ReleaseVideoHosting.sibnet)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: nil, hosting: "sibnet"), ReleaseVideoHosting.sibnet)

        // Неизвестный хостинг и пустой вход — .other.
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://example.com/video/1"), hosting: "Dailymotion"),
                       ReleaseVideoHosting.other)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: nil, hosting: nil), ReleaseVideoHosting.other)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: nil, hosting: ""), ReleaseVideoHosting.other)

        // Имя хостинга проверяется раньше ссылки: подставленный чужой URL его не перебивает.
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://vk.com/video-1_2"), hosting: "YouTube"),
                       ReleaseVideoHosting.youtube)
        XCTAssertEqual(ReleaseVideoHosting.detect(url: makeURL("https://rutube.ru/video/abcdef/"), hosting: "VK"),
                       ReleaseVideoHosting.vk)
    }

    // MARK: - 2. Терпимое декодирование ссылки на хостинг

    func testHostingDecodingObjectAndString() throws {
        // Основная форма в живом API — объект.
        let objectJSON = Data("""
        {"id":2,"name":"YouTube","icon":"https://i.imgur.com/BPP8Hal.png"}
        """.utf8)
        let object = try decoder.decode(VideoHostingRef.self, from: objectJSON)
        XCTAssertEqual(object, VideoHostingRef(id: 2, name: "YouTube", icon: "https://i.imgur.com/BPP8Hal.png"))
        XCTAssertEqual(object.id, 2)
        XCTAssertEqual(object.name, "YouTube")
        XCTAssertEqual(object.icon, "https://i.imgur.com/BPP8Hal.png")

        // Неполный объект тоже валиден: все поля необязательные.
        let partial = try decoder.decode(VideoHostingRef.self, from: Data("{\"name\":\"YouTube\"}".utf8))
        XCTAssertNil(partial.id)
        XCTAssertEqual(partial.name, "YouTube")

        // Встречались и строковые формы — имя хостинга без id/иконки.
        let string = try decoder.decode(VideoHostingRef.self, from: Data("\"ruTube\"".utf8))
        XCTAssertNil(string.id)
        XCTAssertEqual(string.name, "ruTube")
        XCTAssertNil(string.icon)

        // null и отсутствие ключа дают nil, а не ошибку декодирования.
        let nullHosting = try decoder.decode(HostingBox.self, from: Data("{\"hosting\":null}".utf8))
        XCTAssertNil(nullHosting.hosting)
        let missingHosting = try decoder.decode(HostingBox.self, from: Data("{}".utf8))
        XCTAssertNil(missingHosting.hosting)

        // Строковая форма проходит и через `ReleaseVideo` (поле необязательное).
        let stringVideo = try decoder.decode(ReleaseVideo.self,
                                             from: Data("{\"id\":1,\"hosting\":\"ruTube\",\"url\":\"https://rutube.ru/video/abcdef/\"}".utf8))
        XCTAssertEqual(stringVideo.hosting?.name, "ruTube")
        XCTAssertNil(stringVideo.hosting?.id)
        XCTAssertEqual(stringVideo.hostingKind, ReleaseVideoHosting.rutube)
    }

    /// Обёртка, чтобы проверить декодирование `null` в необязательное поле —
    /// ровно так это поле приходит внутри `ReleaseVideo`.
    private struct HostingBox: Decodable {
        let hosting: VideoHostingRef?
    }

    // MARK: - 3. Живой ответ video/release/92

    func testReleaseVideoDecodingFromLiveSlice() throws {
        // Срез реального ответа: два блока с видео и пустая категория в конце.
        // Ключи, которых нет в модели (`@id`, `profile`, `release` верхнего уровня),
        // должны игнорироваться декодером.
        let json = """
        {
          "code": 0,
          "blocks": [
            {
              "category": {"id": 1, "name": "Трейлеры"},
              "videos": [
                {
                  "@id": 2,
                  "id": 216,
                  "release": 1,
                  "category": {"id": 1, "name": "Трейлеры"},
                  "title": "",
                  "image": "http://img.youtube.com/vi/JHuILzpmR28/hqdefault.jpg",
                  "url": "https://youtube.com/watch?v=JHuILzpmR28",
                  "player_url": "http://youtube.com/embed/JHuILzpmR28",
                  "hosting": {"id": 2, "name": "YouTube", "icon": "https://i.imgur.com/BPP8Hal.png"},
                  "is_favorite": false,
                  "favorites_count": 29,
                  "timestamp": 1648408323
                },
                {
                  "id": 49056,
                  "release": 1,
                  "category": {"id": 1, "name": "Трейлеры"},
                  "title": "Тизер",
                  "image": "http://img.youtube.com/vi/NN2fBRNqdWs/hqdefault.jpg",
                  "url": "https://youtu.be/NN2fBRNqdWs",
                  "player_url": "http://youtube.com/embed/NN2fBRNqdWs",
                  "hosting": {"id": 2, "name": "YouTube", "icon": "https://i.imgur.com/BPP8Hal.png"},
                  "is_favorite": false,
                  "favorites_count": 0,
                  "timestamp": 1750567937
                }
              ]
            },
            {
              "category": {"id": 3, "name": "Опенинги"},
              "videos": [
                {
                  "id": 219,
                  "release": 1,
                  "category": {"id": 3, "name": "Опенинги"},
                  "title": "OP1 «PSI-missing» — Мами Кавада",
                  "image": "http://sun9-76.userapi.com/c637220/v637220374/7c00/bCJhqFrTTK0.jpg",
                  "url": "https://vk.com/video-92067374_456239922",
                  "player_url": "http://vk.com/video_ext.php?oid=-92067374&id=456239922&hash=4b200d1d808e4483",
                  "hosting": {"id": 3, "name": "ВКонтакте", "icon": "https://i.imgur.com/kGjowMV.png"},
                  "is_favorite": true,
                  "favorites_count": 44,
                  "timestamp": 1648408323
                }
              ]
            },
            {
              "category": {"id": 6, "name": "Каверы"},
              "videos": []
            }
          ],
          "last_videos": []
        }
        """

        let response = try decoder.decode(ReleaseVideosResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.code, 0)
        XCTAssertEqual(response.lastVideos?.count, 0)

        let blocks = try XCTUnwrap(response.blocks)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.map { $0.category?.id }, [1, 3, 6], "Порядок категорий — как в ответе сервера")
        XCTAssertEqual(blocks[0].category?.name, "Трейлеры")
        XCTAssertEqual(blocks[1].category?.name, "Опенинги")

        // Блок 1: трейлеры на YouTube. Пустой title у первого — как в живом ответе.
        let trailerVideos = try XCTUnwrap(blocks[0].videos)
        XCTAssertEqual(trailerVideos.map { $0.id }, [216, 49056])
        XCTAssertEqual(trailerVideos.map { $0.releaseId }, [1, 1])

        let trailer = trailerVideos[0]
        XCTAssertEqual(trailer.title, "")
        XCTAssertEqual(trailer.image, "http://img.youtube.com/vi/JHuILzpmR28/hqdefault.jpg")
        XCTAssertEqual(trailer.url, "https://youtube.com/watch?v=JHuILzpmR28")
        XCTAssertEqual(trailer.playerURL, "http://youtube.com/embed/JHuILzpmR28")
        XCTAssertEqual(trailer.hosting?.id, 2)
        XCTAssertEqual(trailer.hosting?.name, "YouTube")
        XCTAssertEqual(trailer.hosting, VideoHostingRef(id: 2, name: "YouTube", icon: "https://i.imgur.com/BPP8Hal.png"))
        XCTAssertEqual(trailer.hostingKind, ReleaseVideoHosting.youtube)
        XCTAssertEqual(trailer.category?.id, 1)
        XCTAssertEqual(trailer.isFavorite, false)
        XCTAssertEqual(trailer.favoritesCount, 29)
        XCTAssertEqual(trailer.timestamp, 1648408323)
        XCTAssertEqual(trailer.displayTitle, "Трейлеры", "Пустой title — имя категории")
        XCTAssertEqual(trailerVideos[1].title, "Тизер")

        // Блок 2: опенинги на ВКонтакте.
        let openingVideos = try XCTUnwrap(blocks[1].videos)
        XCTAssertEqual(openingVideos.count, 1)
        let opening = openingVideos[0]
        XCTAssertEqual(opening.id, 219)
        XCTAssertEqual(opening.title, "OP1 «PSI-missing» — Мами Кавада")
        XCTAssertEqual(opening.url, "https://vk.com/video-92067374_456239922")
        XCTAssertEqual(opening.hosting?.id, 3)
        XCTAssertEqual(opening.hosting?.name, "ВКонтакте")
        XCTAssertEqual(opening.hostingKind, ReleaseVideoHosting.vk)
        XCTAssertEqual(opening.isFavorite, true)
        XCTAssertEqual(opening.favoritesCount, 44)

        // Пустой блок сервер тоже присылает: данные его сохраняют, фильтрация
        // пустых категорий — ответственность UI (`visibleBlocks`), не декодера.
        let emptyBlock = blocks[2]
        XCTAssertEqual(emptyBlock.category?.id, 6)
        XCTAssertEqual(emptyBlock.category?.name, "Каверы")
        XCTAssertEqual(emptyBlock.videos?.count, 0)
    }

    // MARK: - 4. YouTube videoId

    func testYouTubeIDExtraction() {
        let videoId = "dQw4w9WgXcQ"
        let links = [
            "https://www.youtube.com/watch?v=\(videoId)",
            "https://youtube.com/watch?v=\(videoId)&t=30",
            "https://m.youtube.com/watch?v=\(videoId)",
            "https://youtu.be/\(videoId)",
            "https://youtu.be/\(videoId)?t=30",
            "https://www.youtube.com/embed/\(videoId)",
            "https://www.youtube.com/embed/\(videoId)?start=10",
            "https://youtube.com/shorts/\(videoId)"
        ]
        for link in links {
            XCTAssertEqual(ReleaseVideo.youtubeID(from: link), videoId, "Не извлекли videoId из \(link)")
        }

        // Отрицательные случаи: идентификатора нет или это не ссылка.
        XCTAssertNil(ReleaseVideo.youtubeID(from: "https://www.youtube.com/watch"))
        XCTAssertNil(ReleaseVideo.youtubeID(from: "https://www.youtube.com/watch?v="))
        XCTAssertNil(ReleaseVideo.youtubeID(from: "https://www.youtube.com/watch?list=PL123"))
        XCTAssertNil(ReleaseVideo.youtubeID(from: "https://youtu.be/"))
        XCTAssertNil(ReleaseVideo.youtubeID(from: "https://www.youtube.com/embed"))
        XCTAssertNil(ReleaseVideo.youtubeID(from: "https://example.com/video/1"))
        XCTAssertNil(ReleaseVideo.youtubeID(from: "не ссылка"))
        XCTAssertNil(ReleaseVideo.youtubeID(from: ""))
    }

    // MARK: - 5. Цель плеера

    func testPlaybackTargetMapping() throws {
        // 1) YouTube: id из player_url (embed), заголовок — из title видео.
        let youtube = makeVideo(
            title: "Тизер",
            url: "https://youtu.be/NN2fBRNqdWs",
            playerURL: "http://youtube.com/embed/NN2fBRNqdWs",
            hosting: VideoHostingRef(id: 2, name: "YouTube")
        )
        let youtubeTarget = try XCTUnwrap(youtube.playbackTarget)
        XCTAssertEqual(youtubeTarget.kind, PlaybackKind.youtube(videoId: "NN2fBRNqdWs"))
        XCTAssertEqual(youtubeTarget.title, "Тизер")
        XCTAssertEqual(youtubeTarget.providerName, "YouTube")
        XCTAssertEqual(youtubeTarget.referer, URL(string: "https://www.youtube.com/"))

        // 2) player_url не про YouTube — id достаём из обычной ссылки.
        let youtubeFromURL = makeVideo(
            url: "https://youtube.com/watch?v=JHuILzpmR28",
            playerURL: "https://example.com/player",
            hosting: VideoHostingRef(id: 2, name: "YouTube")
        )
        let youtubeFromURLTarget = try XCTUnwrap(youtubeFromURL.playbackTarget)
        XCTAssertEqual(youtubeFromURLTarget.kind, PlaybackKind.youtube(videoId: "JHuILzpmR28"))

        // 3) Хостинг неизвестен, но ссылка — YouTube: тоже iframe-API.
        let youtubeByURL = makeVideo(url: "https://www.youtube.com/embed/QAp1i_lftuw")
        let youtubeByURLTarget = try XCTUnwrap(youtubeByURL.playbackTarget)
        XCTAssertEqual(youtubeByURLTarget.kind, PlaybackKind.youtube(videoId: "QAp1i_lftuw"))

        // 4) VK: играем embed-страницу из player_url, а не страницу vk.com.
        let vk = makeVideo(
            url: "https://vk.com/video-227911798_456239238",
            playerURL: "https://vk.com/video_ext.php?oid=-227911798&id=456239238&hash=9f4313d97e7e6b4f",
            hosting: VideoHostingRef(id: 3, name: "ВКонтакте")
        )
        let vkTarget = try XCTUnwrap(vk.playbackTarget)
        XCTAssertEqual(vkTarget.kind,
                       PlaybackKind.web(makeURL("https://vk.com/video_ext.php?oid=-227911798&id=456239238&hash=9f4313d97e7e6b4f")))
        XCTAssertEqual(vkTarget.providerName, "VK")
        XCTAssertEqual(vkTarget.referer, URL(string: "https://vk.com/"))

        // 5) VK без player_url — открываем обычную ссылку.
        let vkWithoutPlayer = makeVideo(
            url: "https://vk.com/video-92067374_456239922",
            hosting: VideoHostingRef(id: 3, name: "ВКонтакте")
        )
        let vkWithoutPlayerTarget = try XCTUnwrap(vkWithoutPlayer.playbackTarget)
        XCTAssertEqual(vkWithoutPlayerTarget.kind,
                       PlaybackKind.web(makeURL("https://vk.com/video-92067374_456239922")))

        // 6) RuTube: .web из player_url, Referer rutube.ru.
        let rutube = makeVideo(
            url: "https://rutube.ru/video/1234567890abcdef/",
            playerURL: "https://rutube.ru/play/embed/1234567890abcdef/",
            hosting: VideoHostingRef(name: "RuTube")
        )
        let rutubeTarget = try XCTUnwrap(rutube.playbackTarget)
        XCTAssertEqual(rutubeTarget.kind,
                       PlaybackKind.web(makeURL("https://rutube.ru/play/embed/1234567890abcdef/")))
        XCTAssertEqual(rutubeTarget.providerName, "RuTube")
        XCTAssertEqual(rutubeTarget.referer, URL(string: "https://rutube.ru/"))

        // 6.1) Sibnet: .web-цель с провайдером «Sibnet» — по нему `PlayerView`
        // поднимает нативный поток через `SibnetResolver` (MP4 + Referer/UA).
        let sibnet = makeVideo(
            url: "https://video.sibnet.ru/shell.php?videoid=2665026&d=1&s=x&ip=1.2.3.4",
            hosting: VideoHostingRef(name: "Sibnet")
        )
        let sibnetTarget = try XCTUnwrap(sibnet.playbackTarget)
        XCTAssertEqual(sibnetTarget.kind,
                       PlaybackKind.web(makeURL("https://video.sibnet.ru/shell.php?videoid=2665026&d=1&s=x&ip=1.2.3.4")))
        XCTAssertEqual(sibnetTarget.providerName, "Sibnet")
        XCTAssertEqual(sibnetTarget.referer, URL(string: "https://video.sibnet.ru/"))

        // 7) Неизвестный хостинг: обычная ссылка из url, без Referer.
        let other = makeVideo(
            url: "https://example.com/video/1",
            hosting: VideoHostingRef(id: 8, name: "Dailymotion"),
            category: VideoCategoryRef(id: 8, name: "Другое")
        )
        let otherTarget = try XCTUnwrap(other.playbackTarget)
        XCTAssertEqual(otherTarget.kind, PlaybackKind.web(makeURL("https://example.com/video/1")))
        XCTAssertEqual(otherTarget.providerName, "Видео")
        XCTAssertNil(otherTarget.referer)
        XCTAssertEqual(otherTarget.title, "Другое")

        // 8) Битая или пустая ссылка — цели нет.
        let brokenYouTube = makeVideo(hosting: VideoHostingRef(id: 2, name: "YouTube"))
        XCTAssertNil(brokenYouTube.playbackTarget)
        let brokenVK = makeVideo(url: "", playerURL: "", hosting: VideoHostingRef(name: "VK"))
        XCTAssertNil(brokenVK.playbackTarget)
        let brokenRuTube = makeVideo(url: "", hosting: VideoHostingRef(name: "RuTube"))
        XCTAssertNil(brokenRuTube.playbackTarget)
        let brokenOther = makeVideo()
        XCTAssertNil(brokenOther.playbackTarget)
    }

    // MARK: - 6. Заголовок карточки

    func testDisplayTitleFallback() {
        // В живом ответе у части трейлеров title пустой — показываем категорию.
        XCTAssertEqual(makeVideo(title: "Тизер", category: VideoCategoryRef(id: 1, name: "Трейлеры")).displayTitle,
                       "Тизер", "Непустой title приоритетнее категории")
        XCTAssertEqual(makeVideo(title: "", category: VideoCategoryRef(id: 1, name: "Трейлеры")).displayTitle,
                       "Трейлеры")
        XCTAssertEqual(makeVideo(category: VideoCategoryRef(id: 5, name: "Муз клипы")).displayTitle,
                       "Муз клипы")

        // Ни title, ни категории — общий заголовок секции.
        XCTAssertEqual(makeVideo().displayTitle, "Видео")
        XCTAssertEqual(makeVideo(title: "", category: nil).displayTitle, "Видео")
    }
}
