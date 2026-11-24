import Foundation

/// Формат файла офлайн-кэша: дата сохранения и полезная нагрузка.
struct Envelope<Value: Codable>: Codable {
    let savedAt: Date
    let value: Value
}

/// Дисковый JSON-кэш для офлайн-режима.
///
/// Не зависит от моделей проекта: сохраняет и читает любые `Codable`-значения.
/// Все операции сериализуются актором. Файлы лежат в
/// `Library/Caches/anixart-offline/<key>.json`.
actor OfflineCache {
    static let shared = OfflineCache()

    /// Конверт для записи: публичный `save` требует только `Encodable`.
    private struct WritableView<Value: Encodable>: Encodable {
        let savedAt: Date
        let value: Value
    }

    /// Конверт для чтения: публичный `load` требует только `Decodable`.
    private struct ReadableView<Value: Decodable>: Decodable {
        let savedAt: Date
        let value: Value
    }

    private static let directoryName = "anixart-offline"

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Публичные методы

    /// Сохраняет значение в кэш. Ошибки записи намеренно проглатываются:
    /// кэш не должен мешать основному сценарию работы приложения.
    func save<T: Encodable>(_ value: T, for key: String) async {
        do {
            try ensureDirectoryExists()
            let envelope = WritableView(savedAt: Date(), value: value)
            let data = try encoder.encode(envelope)
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            // Офлайн-кэш — необязательный слой.
        }
    }

    /// Читает значение из кэша.
    ///
    /// Возвращает `nil`, если файла нет, он повреждён или старше `maxAge`.
    func load<T: Decodable>(_ type: T.Type, for key: String, maxAge: TimeInterval) async -> T? {
        guard maxAge >= 0 else { return nil }

        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let envelope = try decoder.decode(ReadableView<T>.self, from: data)
            guard Date().timeIntervalSince(envelope.savedAt) <= maxAge else { return nil }
            return envelope.value
        } catch {
            return nil
        }
    }

    /// Удаляет все файлы кэша.
    func clear() async {
        try? fileManager.removeItem(at: cacheDirectory)
    }

    /// Суммарный размер всех файлов кэша в байтах.
    func diskSize() async -> Int {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return 0
        }

        var total = 0
        for url in urls {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let size = values.fileSize
            else { continue }
            total += size
        }
        return total
    }

    // MARK: - Файлы

    private var cacheDirectory: URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func fileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}

/// Ключи файлов офлайн-кэша.
enum CacheKey {
    static func catalog(page: Int) -> String { "catalog-\(page)" }
    static func history(page: Int) -> String { "history-\(page)" }
    static func release(id: Int) -> String { "release-\(id)" }
    static func profile(id: Int) -> String { "profile-\(id)" }
}
