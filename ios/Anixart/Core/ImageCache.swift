import Foundation
import SwiftUI
import UIKit

/// Кэш изображений с тремя уровнями: память → диск → сеть.
///
/// В памяти хранится до 30 МБ, при переполнении записи вытесняются
/// в порядке добавления. На диске файлы лежат в `Caches/anixart-images`.
/// Одновременные запросы одного и того же URL объединяются в одну загрузку.
actor ImageCache {
    static let shared = ImageCache()

    private static let memoryLimit = 30 * 1024 * 1024
    private static let downloadLimit = 8 * 1024 * 1024

    private let directory: URL
    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private var memorySize = 0
    private var inFlight: [String: Task<Data?, Never>] = [:]
    /// Меняется при очистке: завершившиеся задачи прошлого поколения
    /// не должны снова заполнить уже очищенный кэш.
    private var generation = 0

    private init() {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folder = caches.appendingPathComponent("anixart-images", isDirectory: true)
        directory = folder
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: - API

    /// Сначала память, затем диск, затем сеть.
    ///
    /// Возвращает `nil`, если изображение не удалось получить
    /// или сервер ответил не кодом 2xx.
    func imageData(for url: URL) async -> Data? {
        let key = url.absoluteString

        if let data = memory[key] {
            return data
        }

        if let data = readFromDisk(key: key) {
            storeInMemory(data, key: key)
            return data
        }

        if let task = inFlight[key] {
            return await task.value
        }

        let currentGeneration = generation
        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            let data = await self.fetchAndStore(
                url: url,
                key: key,
                generation: currentGeneration
            )
            await self.removeInFlight(key: key, generation: currentGeneration)
            return data
        }
        inFlight[key] = task
        return await task.value
    }

    /// Кладёт готовые данные сразу в память и на диск.
    func store(_ data: Data, for url: URL) async {
        let key = url.absoluteString
        storeInMemory(data, key: key)
        writeToDisk(data, key: key)
    }

    /// Очищает память и папку кэша, отменяя незавершённые загрузки.
    func clear() async {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        memory.removeAll(keepingCapacity: false)
        memoryOrder.removeAll(keepingCapacity: false)
        memorySize = 0

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Сеть

    private func fetchAndStore(
        url: URL,
        key: String,
        generation expectedGeneration: Int
    ) async -> Data? {
        guard let data = await download(url) else { return nil }
        guard !Task.isCancelled, generation == expectedGeneration else { return nil }

        storeInMemory(data, key: key)
        writeToDisk(data, key: key)
        return data
    }

    private func download(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty,
                  data.count <= Self.downloadLimit else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func removeInFlight(key: String, generation expectedGeneration: Int) {
        guard expectedGeneration == generation else { return }
        inFlight[key] = nil
    }

    // MARK: - Память

    private func storeInMemory(_ data: Data, key: String) {
        if let old = memory.updateValue(data, forKey: key) {
            memorySize -= old.count
        } else {
            memoryOrder.append(key)
        }
        memorySize += data.count
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while memorySize > Self.memoryLimit, !memoryOrder.isEmpty {
            let oldest = memoryOrder.removeFirst()
            if let removed = memory.removeValue(forKey: oldest) {
                memorySize -= removed.count
            }
        }
    }

    // MARK: - Диск

    private func readFromDisk(key: String) -> Data? {
        try? Data(contentsOf: diskURL(for: key))
    }

    private func writeToDisk(_ data: Data, key: String) {
        try? data.write(to: diskURL(for: key), options: .atomic)
    }

    private func diskURL(for key: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: key), isDirectory: false)
    }

    /// djb2 в UInt64 плюс длина ключа — без CryptoKit и лишних импортов.
    private static func fileName(for key: String) -> String {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return "\(String(hash, radix: 16))-\(key.utf8.count).img"
    }
}

/// Замена `AsyncImage` с общим кэшем из `ImageCache`.
///
/// Показывает `ProgressView` во время загрузки и системную иконку `photo`,
/// если URL отсутствует или изображение не удалось загрузить.
public struct CachedAsyncImage: View {
    private let url: URL?
    private let contentMode: ContentMode

    @State private var data: Data?
    @State private var didFail = false

    public init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }

    public var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if didFail || url == nil || data != nil {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard let url else {
            data = nil
            didFail = true
            return
        }

        data = nil
        didFail = false

        let loaded = await ImageCache.shared.imageData(for: url)
        guard !Task.isCancelled else { return }
        data = loaded
        didFail = loaded == nil
    }
}
