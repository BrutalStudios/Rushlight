import Foundation

/// A parsed 3D LUT in Adobe/IRIDAS `.cube` format.
///
/// `data` holds RGBA Float32 entries with red varying fastest, which is the
/// exact layout `CIColorCube` / `CIColorCubeWithColorSpace` expect.
public struct CubeLUT: Equatable {
    public let title: String?
    public let size: Int
    public let data: Data

    public init(title: String?, size: Int, data: Data) {
        self.title = title
        self.size = size
        self.data = data
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case oneDimensionalUnsupported
        case missingSize
        case sizeOutOfRange(Int)
        case invalidValue(line: Int)
        case wrongEntryCount(expected: Int, got: Int)

        public var errorDescription: String? {
            switch self {
            case .oneDimensionalUnsupported:
                return "1D LUTs are not supported — use a 3D .cube LUT."
            case .missingSize:
                return "The file has no LUT_3D_SIZE declaration, so it is not a valid 3D .cube LUT."
            case .sizeOutOfRange(let s):
                return "LUT_3D_SIZE \(s) is out of the supported range (2–128)."
            case .invalidValue(let line):
                return "Could not parse a value on line \(line)."
            case .wrongEntryCount(let expected, let got):
                return "Expected \(expected) LUT entries but found \(got)."
            }
        }
    }

    public static func parse(contentsOf url: URL) throws -> CubeLUT {
        let raw = try Data(contentsOf: url)
        let text = String(data: raw, encoding: .utf8)
            ?? String(data: raw, encoding: .isoLatin1)
            ?? ""
        return try parse(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(_ text: String, fallbackTitle: String? = nil) throws -> CubeLUT {
        var title: String?
        var size: Int?
        var values: [Float] = []
        var lineNo = 0

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNo += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let upper = line.uppercased()
            if upper.hasPrefix("TITLE") {
                let value = line.dropFirst("TITLE".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
                if !value.isEmpty { title = value }
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") {
                throw ParseError.oneDimensionalUnsupported
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, let s = Int(parts[1]) else {
                    throw ParseError.invalidValue(line: lineNo)
                }
                guard (2...128).contains(s) else { throw ParseError.sizeOutOfRange(s) }
                size = s
                values.reserveCapacity(s * s * s * 3)
                continue
            }
            // Any other keyword line (DOMAIN_MIN, DOMAIN_MAX, LUT_3D_INPUT_RANGE, …)
            // starts with a letter; data lines start with a digit, sign, or dot.
            if let first = line.unicodeScalars.first, CharacterSet.letters.contains(first) {
                continue
            }

            let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard comps.count >= 3,
                  let r = Float(comps[0]), let g = Float(comps[1]), let b = Float(comps[2])
            else {
                throw ParseError.invalidValue(line: lineNo)
            }
            values.append(r)
            values.append(g)
            values.append(b)
        }

        guard let n = size else { throw ParseError.missingSize }
        let expectedEntries = n * n * n
        guard values.count == expectedEntries * 3 else {
            throw ParseError.wrongEntryCount(expected: expectedEntries, got: values.count / 3)
        }

        var rgba = [Float]()
        rgba.reserveCapacity(expectedEntries * 4)
        for i in stride(from: 0, to: values.count, by: 3) {
            rgba.append(min(max(values[i], 0), 1))
            rgba.append(min(max(values[i + 1], 0), 1))
            rgba.append(min(max(values[i + 2], 0), 1))
            rgba.append(1)
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(title: title ?? fallbackTitle, size: n, data: data)
    }
}
