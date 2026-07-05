import AVFoundation
import Foundation

struct VideoItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let sizeBytes: Int64
    let modified: Date

    var id: URL { url }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        self.sizeBytes = Int64(rv?.fileSize ?? 0)
        self.modified = rv?.contentModificationDate ?? .distantPast
    }
}

struct VideoMeta {
    var durationSeconds: Double?
    var width: Int?
    var height: Int?
    var fps: Double?
}

enum PlaylistSortOrder: String, CaseIterable, Identifiable {
    case name
    case date

    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date Modified"
        }
    }
}

@MainActor
final class Playlist: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published var currentIndex: Int?
    @Published private(set) var meta: [URL: VideoMeta] = [:]

    @Published var sortOrder: PlaylistSortOrder {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: Keys.sortOrder)
            resort()
        }
    }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    private enum Keys {
        static let sortOrder = "playlist.sortOrder"
        static let paths = "playlist.paths"
    }

    init() {
        sortOrder = PlaylistSortOrder(
            rawValue: UserDefaults.standard.string(forKey: Keys.sortOrder) ?? ""
        ) ?? .name
        restore()
    }

    var currentItem: VideoItem? {
        guard let i = currentIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }

    var totalSizeBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    func index(of url: URL) -> Int? {
        items.firstIndex { $0.url == url }
    }

    /// Adds files and folders (folders are scanned recursively). Returns the
    /// post-sort index of the first newly added clip, or nil if nothing new.
    @discardableResult
    func add(urls: [URL]) -> Int? {
        var discovered: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                discovered += Self.findVideos(in: url)
            } else if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
                discovered.append(url)
            }
        }

        var seen = Set(items.map(\.url))
        var newURLs: [URL] = []
        for url in discovered where !seen.contains(url) {
            seen.insert(url)
            newURLs.append(url)
        }
        guard !newURLs.isEmpty else { return nil }

        items += newURLs.map { VideoItem(url: $0) }
        resort()
        loadMetadata(for: newURLs)
        persist()
        return newURLs.compactMap { index(of: $0) }.min()
    }

    func remove(at offsets: IndexSet) {
        let currentURL = currentItem?.url
        for offset in offsets {
            meta[items[offset].url] = nil
        }
        items.remove(atOffsets: offsets)
        currentIndex = currentURL.flatMap { index(of: $0) }
        persist()
    }

    func removeAll() {
        items = []
        meta = [:]
        currentIndex = nil
        persist()
    }

    static func findVideos(in folder: URL) -> [URL] {
        var result: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard videoExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            result.append(url)
        }
        return result
    }

    private func resort() {
        let currentURL = currentItem?.url
        switch sortOrder {
        case .name:
            items.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .date:
            items.sort { $0.modified < $1.modified }
        }
        currentIndex = currentURL.flatMap { index(of: $0) }
    }

    private func loadMetadata(for urls: [URL]) {
        Task(priority: .utility) { [weak self] in
            for url in urls {
                let asset = AVURLAsset(url: url)
                var m = VideoMeta()
                if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                    m.durationSeconds = duration.seconds
                }
                if let track = try? await asset.loadTracks(withMediaType: .video).first {
                    if let size = try? await track.load(.naturalSize) {
                        m.width = Int(abs(size.width))
                        m.height = Int(abs(size.height))
                    }
                    if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                        m.fps = Double(fps)
                    }
                }
                self?.meta[url] = m
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: Keys.paths)
    }

    private func restore() {
        guard let paths = UserDefaults.standard.stringArray(forKey: Keys.paths), !paths.isEmpty else { return }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        items = existing.map { VideoItem(url: URL(fileURLWithPath: $0)) }
        resort()
        loadMetadata(for: items.map(\.url))
    }
}
