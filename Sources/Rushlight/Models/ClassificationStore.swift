import AVFoundation
import CoreGraphics
import Foundation
import RushlightCore

/// What kind of picture a clip carries, which decides whether the LUT should
/// touch it when auto-detection is on.
enum ContentKind: String {
    /// Flat log profile (D-Log M, S-Log, …) — the LUT applies.
    case log
    /// Normal or already-graded SDR — the LUT is skipped.
    case sdr
    /// HLG/PQ HDR — the system tone-maps these; the LUT is skipped.
    case hdr

    var badge: String? {
        switch self {
        case .log: return "LOG"
        case .hdr: return "HDR"
        case .sdr: return nil
        }
    }
}

/// Classifies clips (DJI filename convention → color tags → histogram probe)
/// and holds per-clip manual overrides. Results are pushed into `LUTEngine`
/// so the per-frame render handler can honor them dynamically.
@MainActor
final class ClassificationStore: ObservableObject {
    @Published private(set) var kinds: [URL: ContentKind] = [:]
    /// true = always apply the LUT to this clip, false = never. Absent = automatic.
    @Published private(set) var overrides: [URL: Bool] = [:]

    private var pendingQueue: [URL] = []
    private var isPumping = false

    private enum Keys {
        static let overrides = "lut.clipOverrides"
    }

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Keys.overrides) as? [String: Bool] {
            overrides = Dictionary(uniqueKeysWithValues: saved.map {
                (URL(fileURLWithPath: $0.key), $0.value)
            })
        }
        pushToEngine()
    }

    func kind(for url: URL) -> ContentKind? { kinds[url] }
    func override(for url: URL) -> Bool? { overrides[url] }

    func setOverride(_ value: Bool?, for url: URL) {
        if let value {
            overrides[url] = value
        } else {
            overrides.removeValue(forKey: url)
        }
        let plist = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.path, $0.value) })
        UserDefaults.standard.set(plist, forKey: Keys.overrides)
        pushToEngine()
    }

    /// Classification for playback — runs the probe on demand if the clip
    /// hasn't been seen yet, so the answer is known before the first frame
    /// renders.
    func classification(for url: URL) async -> ContentKind {
        if let known = kinds[url] { return known }
        let kind = await Self.classify(url: url)
        store(kind, for: url)
        return kind
    }

    /// Opportunistic background classification (one clip at a time, utility
    /// priority) so sidebar badges fill in without stalling playback.
    func classifyMissing(_ urls: [URL]) {
        let fresh = urls.filter { kinds[$0] == nil && !pendingQueue.contains($0) }
        guard !fresh.isEmpty else { return }
        pendingQueue += fresh
        pump()
    }

    private func pump() {
        guard !isPumping, !pendingQueue.isEmpty else { return }
        isPumping = true
        let url = pendingQueue.removeFirst()
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            if self.kinds[url] == nil {
                let kind = await Self.classify(url: url)
                self.store(kind, for: url)
            }
            self.isPumping = false
            self.pump()
        }
    }

    private func store(_ kind: ContentKind, for url: URL) {
        kinds[url] = kind
        pushToEngine()
    }

    private func pushToEngine() {
        let logClips = Set(kinds.filter { $0.value == .log }.map(\.key))
        let classified = Set(kinds.keys)
        let clipOverrides = overrides
        LUTEngine.shared.update { state in
            state.logClips = logClips
            state.classifiedClips = classified
            state.clipOverrides = clipOverrides
        }
    }

    // MARK: - Classification pipeline

    nonisolated static func classify(url: URL) async -> ContentKind {
        // 1. DJI's "_D" filename suffix marks D-Log/D-Log M clips outright.
        if LogDetection.isDJILogFilename(url.lastPathComponent) {
            return .log
        }

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return .sdr
        }

        var primaries: String?
        var transfer: String?
        if let description = (try? await track.load(.formatDescriptions))?.first {
            primaries = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
            ) as? String
            transfer = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
            ) as? String
        }

        // 2. Tagged HDR plays correctly without a conversion LUT.
        if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            return .hdr
        }

        // 3. Look at actual frames: log footage has lifted blacks, rolled-off
        //    highlights, and muted color.
        if let looksLog = await histogramProbe(asset: asset) {
            return looksLog ? .log : .sdr
        }

        // 4. Probe failed (very short clip, decode error): SDR-tagged
        //    wide-gamut footage from a camera is almost certainly log.
        if primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
            return .log
        }
        return .sdr
    }

    private nonisolated static func histogramProbe(asset: AVAsset) async -> Bool? {
        guard let duration = try? await asset.load(.duration),
              duration.seconds.isFinite, duration.seconds > 0.2
        else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        // Nearest keyframes are fine and much cheaper than exact seeks.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let seconds = duration.seconds
        var verdicts: [Bool?] = []
        for fraction in [0.2, 0.5, 0.82] {
            let time = CMTime(seconds: seconds * fraction, preferredTimescale: 600)
            guard let frame = try? await generator.image(at: time).image else { continue }
            verdicts.append(frameVerdict(frame))
        }
        guard !verdicts.isEmpty else { return nil }
        return LogDetection.combineVerdicts(verdicts)
    }

    private nonisolated static func frameVerdict(_ image: CGImage) -> Bool? {
        let width = 96
        let height = 54
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return nil }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var lumas: [Float] = []
        lumas.reserveCapacity(width * height)
        var saturations: [Float] = []
        for i in 0..<(width * height) {
            let r = Float(pixels[i * 4]) / 255
            let g = Float(pixels[i * 4 + 1]) / 255
            let b = Float(pixels[i * 4 + 2]) / 255
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            let maxChannel = max(r, g, b)
            if maxChannel > 0.10 {
                saturations.append((maxChannel - min(r, g, b)) / maxChannel)
            }
        }

        guard let stats = LogDetection.stats(lumas: lumas, saturations: saturations) else {
            return nil
        }
        return LogDetection.frameLooksLog(stats)
    }
}
