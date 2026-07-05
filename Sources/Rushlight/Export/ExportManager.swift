import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case hevc
    case h264
    case prores422

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hevc: return "HEVC — best quality/size (recommended)"
        case .h264: return "H.264 — plays anywhere"
        case .prores422: return "Apple ProRes 422 — edit-ready, huge files"
        }
    }

    var presetName: String {
        switch self {
        case .hevc: return AVAssetExportPresetHEVCHighestQuality
        case .h264: return AVAssetExportPresetHighestQuality
        case .prores422: return AVAssetExportPresetAppleProRes422LPCM
        }
    }
}

enum ExportError: LocalizedError {
    case presetUnsupported
    case frameRenderFailed
    case unknown

    var errorDescription: String? {
        switch self {
        case .presetUnsupported:
            return "This clip can't be exported with the chosen format."
        case .frameRenderFailed:
            return "Could not render the frame."
        case .unknown:
            return "The export failed for an unknown reason."
        }
    }
}

/// Bakes the active LUT into new video files via AVAssetExportSession.
/// Exports run sequentially off the player's pipeline, with live progress and
/// cancellation; the LUT state is frozen per clip when its export starts.
@MainActor
final class ExportManager: ObservableObject {
    struct Config {
        var urls: [URL]
        var format: ExportFormat
        var destination: URL
    }

    struct ActiveExport {
        var totalCount: Int
        var completedCount: Int
        var currentName: String
        var progress: Double

        var overallProgress: Double {
            guard totalCount > 0 else { return 0 }
            return (Double(completedCount) + min(progress, 1)) / Double(totalCount)
        }
    }

    /// Non-nil while the configuration sheet is up.
    @Published var config: Config?
    @Published private(set) var active: ActiveExport?
    @Published var lastError: String?
    /// Transient success/cancel notice for the status strip.
    @Published private(set) var finishedMessage: String?

    private let classifications: ClassificationStore
    private var pendingJobs: [(source: URL, folder: URL, format: ExportFormat)] = []
    private var currentSession: AVAssetExportSession?
    private var currentExportTask: Task<Void, Error>?
    private var isCancelled = false
    private var runTask: Task<Void, Never>?

    private enum Keys {
        static let format = "export.format"
        static let folder = "export.lastFolder"
    }

    init(classifications: ClassificationStore) {
        self.classifications = classifications
    }

    var isExporting: Bool { active != nil }

    // MARK: - Configuration sheet

    func beginConfiguration(urls: [URL]) {
        guard !urls.isEmpty, !isExporting else { return }
        let format = ExportFormat(
            rawValue: UserDefaults.standard.string(forKey: Keys.format) ?? ""
        ) ?? .hevc
        let savedFolder = UserDefaults.standard.string(forKey: Keys.folder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        config = Config(
            urls: urls,
            format: format,
            destination: savedFolder ?? urls[0].deletingLastPathComponent()
        )
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the exported clips"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.config?.destination = url }
        }
    }

    func cancelConfiguration() {
        config = nil
    }

    /// How many of the clips in the pending config will actually get the LUT
    /// (the rest export as plain transcodes).
    var configuredLUTCount: Int {
        guard let config else { return 0 }
        return config.urls.filter { LUTEngine.shared.wouldApply(to: $0) }.count
    }

    func startConfigured() {
        guard let config else { return }
        self.config = nil
        UserDefaults.standard.set(config.format.rawValue, forKey: Keys.format)
        UserDefaults.standard.set(config.destination.path, forKey: Keys.folder)
        pendingJobs += config.urls.map { ($0, config.destination, config.format) }

        guard runTask == nil else { return }
        isCancelled = false
        active = ActiveExport(
            totalCount: pendingJobs.count,
            completedCount: 0,
            currentName: pendingJobs.first?.source.lastPathComponent ?? "",
            progress: 0
        )
        runTask = Task { await drainQueue() }
    }

    func cancel() {
        isCancelled = true
        currentExportTask?.cancel()
        currentSession?.cancelExport()
    }

    // MARK: - Queue

    private func drainQueue() async {
        var failures: [String] = []
        var exportedCount = 0
        var firstDestination: URL?

        while !isCancelled, !pendingJobs.isEmpty {
            let job = pendingJobs.removeFirst()
            active?.currentName = job.source.lastPathComponent
            active?.progress = 0
            do {
                let destination = Self.availableDestination(for: job.source, in: job.folder)
                try await exportOne(source: job.source, destination: destination, format: job.format)
                exportedCount += 1
                if firstDestination == nil { firstDestination = destination }
            } catch {
                if isCancelled || error is CancellationError { break }
                failures.append("\(job.source.lastPathComponent): \(error.localizedDescription)")
            }
            active?.completedCount += 1
        }

        let wasCancelled = isCancelled
        pendingJobs.removeAll()
        currentSession = nil
        currentExportTask = nil
        runTask = nil
        active = nil

        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        } else if wasCancelled {
            flash("Export cancelled")
        } else if exportedCount > 0 {
            flash(exportedCount == 1 ? "Exported 1 clip" : "Exported \(exportedCount) clips")
            if exportedCount == 1, let destination = firstDestination {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    private func exportOne(source: URL, destination: URL, format: ExportFormat) async throws {
        // A fresh asset keeps the export decoder independent from playback.
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: format.presetName) else {
            throw ExportError.presetUnsupported
        }
        session.videoComposition = await lutComposition(for: asset, url: source)
        session.metadata = (try? await asset.load(.metadata)) ?? []
        currentSession = session

        if #available(macOS 15.0, *) {
            let progressTask = Task { [weak self] in
                for await state in session.states(updateInterval: 0.25) {
                    if case .exporting(let progress) = state {
                        self?.active?.progress = progress.fractionCompleted
                    }
                }
            }
            defer { progressTask.cancel() }
            let exportTask = Task { try await session.export(to: destination, as: .mov) }
            currentExportTask = exportTask
            try await exportTask.value
        } else {
            try await legacyExport(session: session, to: destination)
        }
        active?.progress = 1
    }

    @available(macOS, deprecated: 15.0)
    private func legacyExport(session: AVAssetExportSession, to destination: URL) async throws {
        session.outputURL = destination
        session.outputFileType = .mov
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.active?.progress = Double(session.progress)
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { progressTask.cancel() }
        await session.export()
        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            throw session.error ?? ExportError.unknown
        }
    }

    /// Builds the composition that bakes the LUT in, or nil (plain transcode)
    /// when the LUT is off/skipped for this clip — matching what playback shows.
    private func lutComposition(for asset: AVAsset, url: URL) async -> AVVideoComposition? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        // The verdict must exist before freezing the filter state.
        _ = await classifications.classification(for: url)
        let colorSpace = await VideoColorProbe.detectColorSpace(of: track)
        guard let filter = LUTEngine.shared.frozenFilter(for: url, assetColorSpace: colorSpace) else {
            return nil
        }
        return try? await AVMutableVideoComposition.videoComposition(with: asset) { request in
            request.finish(with: filter(request.sourceImage), context: LUTEngine.renderContext)
        }
    }

    private static func availableDestination(for source: URL, in folder: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent + "-graded"
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension("mov")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension("mov")
            counter += 1
        }
        return candidate
    }

    private func flash(_ message: String) {
        finishedMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.finishedMessage == message {
                self?.finishedMessage = nil
            }
        }
    }

    // MARK: - Frame export

    /// Saves the frame at `seconds` as a PNG, with the LUT baked in exactly
    /// as playback shows it (skipped clips save the original frame).
    func saveFrame(of url: URL, at seconds: Double) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let stem = url.deletingPathExtension().lastPathComponent
        let stamp = Format.time(seconds).replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = "\(stem) @ \(stamp).png"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try await self?.renderFrame(of: url, at: seconds)
                    try data?.write(to: destination)
                    self?.flash("Frame saved")
                } catch {
                    self?.lastError = "Could not save frame: \(error.localizedDescription)"
                }
            }
        }
    }

    private func renderFrame(of url: URL, at seconds: Double) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.videoComposition = await lutComposition(for: asset, url: url)

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let cgImage = try await generator.image(at: time).image
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ExportError.frameRenderFailed
        }
        return png
    }
}
