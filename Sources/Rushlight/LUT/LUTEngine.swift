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
    /// camera-vendor LUTs expect.
    func process(_ source: CIImage, assetColorSpace: CGColorSpace?) -> CIImage {
        let s = snapshot()
        guard s.isEnabled, let cube = s.cube, s.intensity > 0.001 else { return source }

        let colorSpace = s.colorSpaceOverride
            ?? assetColorSpace
            ?? CGColorSpace(name: CGColorSpace.itur_709)!

        var output = source.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": NSNumber(value: cube.size),
            "inputCubeData": cube.data,
            "inputColorSpace": colorSpace,
        ])

        if s.intensity < 0.999 {
            output = output.applyingFilter("CIMix", parameters: [
                kCIInputBackgroundImageKey: source,
                kCIInputAmountKey: NSNumber(value: s.intensity),
            ])
        }
        return output
    }
}
