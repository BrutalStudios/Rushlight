import XCTest
@testable import RushlightCore

final class CubeLUTTests: XCTestCase {
    func testParsesMinimalCube() throws {
        let text = """
        # a comment
        TITLE "Test LUT"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.title, "Test LUT")
        XCTAssertEqual(lut.size, 2)
        // 8 lattice points × RGBA × Float32
        XCTAssertEqual(lut.data.count, 8 * 4 * MemoryLayout<Float32>.size)

        let floats = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        // First entry (0,0,0) → black with alpha 1.
        XCTAssertEqual(Array(floats[0..<4]), [0, 0, 0, 1])
        // Last entry → white with alpha 1.
        XCTAssertEqual(Array(floats[28..<32]), [1, 1, 1, 1])
    }

    func testClampsOutOfRangeValues() throws {
        let text = """
        LUT_3D_SIZE 2
        -0.2 0.0 0.0
        1.3 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        let lut = try CubeLUT.parse(text)
        let floats = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        XCTAssertEqual(floats[0], 0, "negative value should clamp to 0")
        XCTAssertEqual(floats[4], 1, "value above 1 should clamp to 1")
    }

    func testMissingSizeThrows() {
        XCTAssertThrowsError(try CubeLUT.parse("0.0 0.0 0.0")) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .missingSize)
        }
    }

    func testOneDimensionalLUTThrows() {
        let text = """
        LUT_1D_SIZE 2
        0.0 0.0 0.0
        1.0 1.0 1.0
        """
        XCTAssertThrowsError(try CubeLUT.parse(text)) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .oneDimensionalUnsupported)
        }
    }

    func testWrongEntryCountThrows() {
        let text = """
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 1.0 1.0
        """
        XCTAssertThrowsError(try CubeLUT.parse(text)) { error in
            XCTAssertEqual(error as? CubeLUT.ParseError, .wrongEntryCount(expected: 8, got: 2))
        }
    }

    func testInvalidValueThrows() {
        let text = """
        LUT_3D_SIZE 2
        0.0 zebra 0.0
        """
        XCTAssertThrowsError(try CubeLUT.parse(text)) { error in
            guard case .invalidValue = error as? CubeLUT.ParseError else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
    }

    func testFallbackTitleUsedWhenAbsent() throws {
        let text = """
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        let lut = try CubeLUT.parse(text, fallbackTitle: "MyLUT")
        XCTAssertEqual(lut.title, "MyLUT")
    }
}

final class BuiltinLUTTests: XCTestCase {
    func testGeneratedLUTShape() {
        let lut = BuiltinLUT.dlogMToRec709(size: 17)
        XCTAssertEqual(lut.size, 17)
        XCTAssertEqual(lut.data.count, 17 * 17 * 17 * 4 * MemoryLayout<Float32>.size)
    }

    func testGrayAxisIsMonotonic() {
        let n = 17
        let lut = BuiltinLUT.dlogMToRec709(size: n)
        let floats = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        var previous: Float = -1
        for i in 0..<n {
            // Lattice index of the neutral (i,i,i) entry; red varies fastest.
            let entry = i + i * n + i * n * n
            let red = floats[entry * 4]
            XCTAssertGreaterThanOrEqual(
                red + 1e-5, previous,
                "gray-axis output should not decrease (step \(i))"
            )
            previous = red
        }
        // A log-to-709 conversion must add contrast: deep shadows crushed
        // toward black, top end near white.
        XCTAssertLessThan(floats[0], 0.05)
        let lastEntry = (n * n * n - 1) * 4
        XCTAssertGreaterThan(floats[lastEntry], 0.9)
    }

    func testAllValuesWithinRange() {
        let lut = BuiltinLUT.dlogMToRec709(size: 9)
        let floats = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        for v in floats {
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
    }
}
