// Проверка Codable-моделей на реальных ответах API без Xcode и без iOS SDK.
//
// Сборка и запуск (macOS или Windows со Swift toolchain):
//   python tools/fetch_fixtures.py
//   swiftc -o modelcheck Anixart/Models/Models.swift tools/ModelCheck/main.swift
//   ./modelcheck tools/fixtures
//
// Если модель разойдётся с API — упадёт именно здесь, а не в приложении.

import Foundation
#if canImport(Glibc)
import Glibc
#endif

let fixturesPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/fixtures"
let fixturesURL = URL(fileURLWithPath: fixturesPath)

func data(_ name: String) throws -> Data {
    try Data(contentsOf: fixturesURL.appendingPathComponent(name))
}

var failures = 0
var checks = 0

func expect(_ name: String, _ body: () throws -> String) {
    checks += 1
    do {
        let detail = try body()
        print("OK   \(name) — \(detail)")
    } catch {
        failures += 1
        print("FAIL \(name) — \(error)")
    }
}

let decoder = JSONDecoder()

func decode<T: Decodable>(_ type: T.Type, _ file: String) throws -> T {
    try decoder.decode(type, from: try data(file))
}

expect("Release") {
    let response = try decode(ReleaseResponse.self, "release.json")
    guard response.code == 0 else { throw NSError(domain: "code", code: response.code) }
    let release = response.release
    guard !release.displayTitle.isEmpty else { throw NSError(domain: "title", code: 1) }
    return "id=\(release.id) «\(release.displayTitle)», жанров \(release.genreList.count), серий \((release.episodesTotal ?? 0))"
}

expect("Profile") {
    let response = try decode(ProfileResponse.self, "profile.json")
    guard response.code == 0 else { throw NSError(domain: "code", code: response.code) }
    return "id=\(response.profile.id) «\(response.profile.displayName)»"
}

expect("Catalog (Paged<Release>)") {
    let page = try decode(Paged<Release>.self, "filter.json")
    guard !page.content.isEmpty else { throw NSError(domain: "empty", code: 1) }
    return "\(page.content.count) из \(page.totalCount ?? 0), страница \(page.currentPage ?? 0)"
}

expect("Discover") {
    let hub = try decode(Discover.self, "discover.json")
    return "смотрят \((hub.watching ?? []).count), обсуждают \((hub.discussing ?? []).count)"
}

expect("Search (Paged<Release>)") {
    let page = try decode(Paged<Release>.self, "search.json")
    return "\(page.content.count) результатов на «one piece»"
}

expect("EpisodeTypes") {
    let response = try decode(EpisodeTypesResponse.self, "episode_types.json")
    return "\(response.types?.count ?? 0) озвучек"
}

expect("EpisodeSources") {
    let response = try decode(EpisodeSourcesResponse.self, "episode_sources.json")
    return "\(response.sources?.count ?? 0) источников"
}

expect("Episodes") {
    let response = try decode(EpisodesResponse.self, "episodes.json")
    let first = response.episodes?.first
    return "\(response.episodes?.count ?? 0) серий, первая «\(first?.displayName ?? "—")»"
}

expect("EpisodeTarget") {
    let response = try decode(EpisodeTargetResponse.self, "episode_target.json")
    guard let episode = response.episode, let raw = episode.url, URL(string: raw) != nil else {
        throw NSError(domain: "url", code: 1)
    }
    return "позиция \(episode.position), iframe=\(episode.iframe ?? false)"
}

print("")
if failures > 0 {
    print("Провалено \(failures) из \(checks)")
    exit(1)
}
print("Все \(checks) проверок прошли")
