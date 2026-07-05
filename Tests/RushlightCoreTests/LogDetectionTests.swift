import XCTest
@testable import RushlightCore

final class LogDetectionTests: XCTestCase {
    // MARK: - DJI filename convention

    func testDJILogFilenamesDetected() {
        XCTAssertTrue(LogDetection.isDJILogFilename("DJI_20240309094418_0012_D.MP4"))
        XCTAssertTrue(LogDetection.isDJILogFilename("DJI_20231115170528_0001_D.mp4"))
        XCTAssertTrue(LogDetection.isDJILogFilename("dji_20240309094418_0012_d.mov"))
    }

    func testNonLogFilenamesRejected() {
        XCTAssertFalse(LogDetection.isDJILogFilename("DJI_20240309094418_0012.MP4"), "no _D suffix")
        XCTAssertFalse(LogDetection.isDJILogFilename("DJI_20240309094418_0012_HLG.MP4"))
        XCTAssertFalse(LogDetection.isDJILogFilename("GX010042_D.MP4"), "not a DJI_ prefix")
        XCTAssertFalse(LogDetection.isDJILogFilename("IMG_0042.MOV"))
        XCTAssertFalse(LogDetection.isDJILogFilename("holiday_D.MP4"))
    }

    // MARK: - Stats

    func testStatsPercentiles() throws {
        // 100 evenly spaced lumas 0.00…0.99.
        let lumas = (0..<100).map { Float($0) / 100 }
        let stats = try XCTUnwrap(LogDetection.stats(lumas: lumas, saturations: [0.2, 0.4]))
        XCTAssertEqual(stats.lowLuma, 0.01, accuracy: 0.02)
        XCTAssertEqual(stats.highLuma, 0.97, accuracy: 0.02)
        XCTAssertEqual(stats.meanSaturation, 0.3, accuracy: 0.001)
    }

    func testStatsRequiresEnoughSamples() {
        XCTAssertNil(LogDetection.stats(lumas: [0.5, 0.5], saturations: []))
    }

    // MARK: - Per-frame verdict

    func testFlatDesaturatedFrameLooksLog() {
        // Typical D-Log M: blacks ~0.09, highlights ~0.65, muted color.
        let stats = LogDetection.FrameStats(lowLuma: 0.09, highLuma: 0.65, meanSaturation: 0.18)
        XCTAssertEqual(LogDetection.frameLooksLog(stats), true)
    }

    func testVeryFlatFrameLooksLogEvenIfColorful() {
        let stats = LogDetection.FrameStats(lowLuma: 0.10, highLuma: 0.70, meanSaturation: 0.45)
        XCTAssertEqual(LogDetection.frameLooksLog(stats), true)
    }

    func testPunchyGradedFrameLooksNormal() {
        // Graded/normal video: true blacks, bright highlights, saturated.
        let stats = LogDetection.FrameStats(lowLuma: 0.01, highLuma: 0.97, meanSaturation: 0.45)
        XCTAssertEqual(LogDetection.frameLooksLog(stats), false)
    }

    func testFlatButSaturatedMidRangeFrameLooksNormal() {
        // e.g. a normal video of a colorful mural on an overcast day.
        let stats = LogDetection.FrameStats(lowLuma: 0.06, highLuma: 0.84, meanSaturation: 0.5)
        XCTAssertEqual(LogDetection.frameLooksLog(stats), false)
    }

    func testBlackFrameIsUninformative() {
        let stats = LogDetection.FrameStats(lowLuma: 0.0, highLuma: 0.05, meanSaturation: 0.0)
        XCTAssertNil(LogDetection.frameLooksLog(stats))
    }

    // MARK: - Combining verdicts

    func testMajorityVoteWins() {
        XCTAssertEqual(LogDetection.combineVerdicts([true, true, false]), true)
        XCTAssertEqual(LogDetection.combineVerdicts([false, false, true]), false)
    }

    func testUninformativeFramesIgnored() {
        XCTAssertEqual(LogDetection.combineVerdicts([nil, true, nil]), true)
        XCTAssertEqual(LogDetection.combineVerdicts([nil, false, nil]), false)
    }

    func testTieLeansLog() {
        XCTAssertEqual(LogDetection.combineVerdicts([true, false]), true)
    }

    func testAllUninformativeGivesNoVerdict() {
        XCTAssertNil(LogDetection.combineVerdicts([nil, nil, nil]))
        XCTAssertNil(LogDetection.combineVerdicts([]))
    }
}
