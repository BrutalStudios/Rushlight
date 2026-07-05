import Foundation

/// Pure decision logic for classifying footage as log vs. normal. The
/// AVFoundation-side code extracts pixels and color tags; everything
/// judgement-shaped lives here so it can be unit tested.
public enum LogDetection {

    /// DJI cameras (Osmo Pocket 3, Action, Mini/Air/Mavic drones) append
    /// "_D" to the filename of clips recorded in D-Log / D-Log M, e.g.
    /// `DJI_20240309094418_0012_D.MP4`. A very cheap, very reliable signal.
    public static func isDJILogFilename(_ filename: String) -> Bool {
        let upper = filename.uppercased()
        guard upper.hasPrefix("DJI_") else { return false }
        let stem = (upper as NSString).deletingPathExtension
        return stem.hasSuffix("_D")
    }

    public struct FrameStats: Equatable {
        /// ~2nd percentile of luma (0…1) — where the blacks sit.
        public let lowLuma: Float
        /// ~98th percentile of luma — where the highlights sit.
        public let highLuma: Float
        /// Mean HSV-style saturation of non-dark pixels.
        public let meanSaturation: Float

        public init(lowLuma: Float, highLuma: Float, meanSaturation: Float) {
            self.lowLuma = lowLuma
            self.highLuma = highLuma
            self.meanSaturation = meanSaturation
        }
    }

    /// Reduces sampled pixels to the stats the verdict needs. `saturations`
    /// should only contain values from pixels bright enough to measure
    /// (dark pixels are saturation noise). Returns nil if the sample is too
    /// small to judge.
    public static func stats(lumas: [Float], saturations: [Float]) -> FrameStats? {
        guard lumas.count >= 64 else { return nil }
        let sorted = lumas.sorted()
        let low = sorted[Int(Float(sorted.count - 1) * 0.02)]
        let high = sorted[Int(Float(sorted.count - 1) * 0.98)]
        let sat = saturations.isEmpty ? 0 : saturations.reduce(0, +) / Float(saturations.count)
        return FrameStats(lowLuma: low, highLuma: high, meanSaturation: sat)
    }

    /// Verdict for a single frame: true = looks like log, false = looks like
    /// normal/graded video, nil = uninformative (e.g. black frame, fade).
    ///
    /// Log profiles lift true black to ~9–10 IRE and roll highlights off well
    /// below clip, and their wide gamuts read as desaturated in sRGB — so a
    /// frame that is flat at both ends *and* muted is almost certainly log,
    /// and a frame that is extremely flat is log even if colorful.
    public static func frameLooksLog(_ s: FrameStats) -> Bool? {
        guard s.highLuma >= 0.12 else { return nil }
        let veryFlat = s.lowLuma >= 0.085 && s.highLuma <= 0.74
        let flat = s.lowLuma >= 0.055 && s.highLuma <= 0.86
        let desaturated = s.meanSaturation <= 0.30
        return veryFlat || (flat && desaturated)
    }

    /// Majority vote across per-frame verdicts, ignoring uninformative
    /// frames; ties lean log (a wrongly-applied LUT is easier to spot and
    /// toggle off than silently-skipped grading). nil if no frame was usable.
    public static func combineVerdicts(_ verdicts: [Bool?]) -> Bool? {
        let informative = verdicts.compactMap { $0 }
        guard !informative.isEmpty else { return nil }
        let logVotes = informative.filter { $0 }.count
        return logVotes * 2 >= informative.count
    }
}
