import CoreImage
import Foundation
import RushlightCore

extension Notification.Name {
    /// Posted whenever LUT state changes so a paused player can redraw its frame.
    static let rushlightLUTChanged = Notification.Name("rushlightLUTChanged")
}

/// Thread-safe holder of the active LUT state, applied per frame from the
/// AVVideoComposition CI handler. Because the handler reads this dynamically,
/// toggling or swapping LUTs takes effect instantly without rebuilding player
/// items — which keeps playback gapless.
final class LUTEngine {
    static let shared = LUTEngine()

    /// One Metal-backed context shared by every composition render.
    static let renderContext = CIContext(options: [
        .cacheIntermediates: false,
        .name: "RushlightLUT",
    ])

    struct State {
        var cube: CubeLUT?
        var isEnabled = true
        var intensity: Float = 1.0
        /// nil means "auto" — use the color space detected from the asset.
        var colorSpaceOverride: CGColorSpace?
        /// When on, the LUT is only applied to clips classified as log.
        var autoDetectLog = true
        var logClips: Set<URL> = []
        var classifiedClips: Set<URL> = []
        /// Per-clip manual override: true = always apply, false = never.
        var clipOverrides: [URL: Bool] = [:]
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ mutate: (inout State) -> Void) {
        lock.lock()
        mutate(&state)
        lock.unlock()
        NotificationCenter.default.post(name: .rushlightLUTChanged, object: nil)
    }

    private func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Applies the active LUT to one video frame. `assetColorSpace` is the
    /// color space detected from the footage; converting into it before the
    /// cube lookup reconstructs the original encoded code values that
    /// camera-vendor LUTs expect. `clipURL` identifies the clip so per-clip
    /// overrides and log auto-detection can skip normal/HDR footage.
    func process(_ source: CIImage, assetColorSpace: CGColorSpace?, clipURL: URL?) -> CIImage {
        let s = snapshot()
        guard s.isEnabled, let cube = s.cube, s.intensity > 0.001 else { return source }

        if let url = clipURL {
            if let forced = s.clipOverrides[url] {
                if !forced { return source }
            } else if s.autoDetectLog,
                      s.classifiedClips.contains(url),
                      !s.logClips.contains(url) {
                // Classified as normal/HDR — leave it untouched.
                return source
            }
        }

        let colorSpace = s.colorSpaceOverride
            ?? assetColorSpace
            ?? CGColorSpace(name: CGColorSpace.itur_709)!
        return Self.applyCube(to: source, cube: cube, colorSpace: colorSpace, intensity: s.intensity)
    }

    private static func applyCube(
        to source: CIImage, cube: CubeLUT, colorSpace: CGColorSpace, intensity: Float
    ) -> CIImage {
        var output = source.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": NSNumber(value: cube.size),
            "inputCubeData": cube.data,
            "inputColorSpace": colorSpace,
        ])
        if intensity < 0.999 {
            output = output.applyingFilter("CIMix", parameters: [
                kCIInputBackgroundImageKey: source,
                kCIInputAmountKey: NSNumber(value: intensity),
            ])
        }
        return output
    }

    /// Whether the LUT would currently touch this clip (enabled, a cube is
    /// selected, and the clip isn't skipped by auto-detection or an override).
    func wouldApply(to clipURL: URL) -> Bool {
        let s = snapshot()
        guard s.isEnabled, s.cube != nil, s.intensity > 0.001 else { return false }
        if let forced = s.clipOverrides[clipURL] { return forced }
        if s.autoDetectLog, s.classifiedClips.contains(clipURL), !s.logClips.contains(clipURL) {
            return false
        }
        return true
    }

    /// Captures the current LUT state into a self-contained per-frame filter
    /// for export, so a deterministic look is baked in even if the user
    /// changes LUT settings while the export runs. Returns nil when the LUT
    /// would not be applied to this clip (export becomes a plain transcode).
    func frozenFilter(for clipURL: URL, assetColorSpace: CGColorSpace?) -> ((CIImage) -> CIImage)? {
        let s = snapshot()
        guard wouldApply(to: clipURL), let cube = s.cube else { return nil }
        let colorSpace = s.colorSpaceOverride
            ?? assetColorSpace
            ?? CGColorSpace(name: CGColorSpace.itur_709)!
        let intensity = s.intensity
        return { source in
            Self.applyCube(to: source, cube: cube, colorSpace: colorSpace, intensity: intensity)
        }
    }
}
