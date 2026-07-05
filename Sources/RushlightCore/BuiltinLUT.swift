import Foundation

/// Programmatically generated conversion LUTs that ship with the app, so log
/// footage is watchable out of the box before the user imports camera-vendor
/// LUTs. These are pleasing approximations, not colorimetric matches — for
/// exact results users should import the official .cube from their camera
/// maker (e.g. DJI's "DLog-M to Rec.709" LUT).
public enum BuiltinLUT {

    /// Approximate DJI D-Log M → Rec.709 viewing transform.
    ///
    /// Pipeline per lattice point: DJI D-Log decode (published D-Log curve as
    /// a stand-in for the unpublished D-Log M variant) → BT.2020 → BT.709
    /// primaries → filmic tone map (Narkowicz ACES fit) → 2.2 gamma →
    /// gentle saturation lift.
    public static func dlogMToRec709(size: Int = 33) -> CubeLUT {
        precondition(size >= 2)
        let n = size
        var rgba = [Float]()
        rgba.reserveCapacity(n * n * n * 4)
        let step = 1.0 / Float(n - 1)

        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var r = dlogDecode(Float(ri) * step)
                    var g = dlogDecode(Float(gi) * step)
                    var b = dlogDecode(Float(bi) * step)

                    // BT.2020 → BT.709 primaries (linear light).
                    let r709 = 1.6605 * r - 0.5876 * g - 0.0728 * b
                    let g709 = -0.1246 * r + 1.1329 * g - 0.0083 * b
                    let b709 = -0.0182 * r - 0.1006 * g + 1.1187 * b
                    r = max(r709, 0); g = max(g709, 0); b = max(b709, 0)

                    let exposure: Float = 0.8
                    r = acesFilm(r * exposure)
                    g = acesFilm(g * exposure)
                    b = acesFilm(b * exposure)

                    let gamma: Float = 1.0 / 2.2
                    r = pow(r, gamma); g = pow(g, gamma); b = pow(b, gamma)

                    // Saturation lift in display space.
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let sat: Float = 1.05
                    r = clamp01(luma + (r - luma) * sat)
                    g = clamp01(luma + (g - luma) * sat)
                    b = clamp01(luma + (b - luma) * sat)

                    rgba.append(r); rgba.append(g); rgba.append(b); rgba.append(1)
                }
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(title: "D-Log M → Rec.709 (built-in approx.)", size: n, data: data)
    }

    /// DJI D-Log → scene linear, from DJI's D-Log/D-Gamut whitepaper.
    static func dlogDecode(_ y: Float) -> Float {
        if y <= 0.14 {
            return max((y - 0.0929) / 6.025, 0)
        }
        return (pow(10, (y - 0.584555) / 0.256663) - 0.0108) / 0.9892
    }

    /// Narkowicz ACES filmic tone-map fit (linear in, linear out).
    static func acesFilm(_ x: Float) -> Float {
        let v = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)
        return clamp01(v)
    }

    static func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
}
