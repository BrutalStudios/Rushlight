import AVFoundation
import CoreGraphics

enum VideoColorProbe {
    /// Maps the track's tagged color primaries/transfer to a CGColorSpace so
    /// the LUT can be applied to reconstructed original code values.
    static func detectColorSpace(of track: AVAssetTrack) async -> CGColorSpace? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first
        else { return nil }

        let primaries = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
        ) as? String
        let transfer = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String

        if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
            return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                ?? CGColorSpace(name: CGColorSpace.itur_2020)
        }
        if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                ?? CGColorSpace(name: CGColorSpace.itur_2020)
        }

        if primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
            return CGColorSpace(name: CGColorSpace.itur_2020)
        }
        if primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) {
            return CGColorSpace(name: CGColorSpace.displayP3)
        }
        return CGColorSpace(name: CGColorSpace.itur_709)
    }
}
