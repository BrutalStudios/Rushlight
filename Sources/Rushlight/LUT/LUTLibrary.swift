import CoreGraphics
import Foundation
import RushlightCore
import SwiftUI

enum LUTColorSpaceOption: String, CaseIterable, Identifiable {
    case auto
    case rec709
    case sRGB
    case rec2020
    case hlg
    case displayP3

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (from footage)"
        case .rec709: return "Rec.709"
        case .sRGB: return "sRGB"
        case .rec2020: return "Rec.2020"
        case .hlg: return "Rec.2100 HLG"
        case .displayP3: return "Display P3"
        }
    }

    /// nil = auto (use the color space detected from the asset).
    var colorSpace: CGColorSpace? {
        switch self {
        case .auto: return nil
        case .rec709: return CGColorSpace(name: CGColorSpace.itur_709)
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
        case .rec2020: return CGColorSpace(name: CGColorSpace.itur_2020)
        case .hlg: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
        }
    }
}

/// Manages the LUT collection (built-in + user-imported .cube files) and the
/// user's LUT settings, pushing every change into `LUTEngine`.
@MainActor
final class LUTLibrary: ObservableObject {
    struct Entry: Identifiable, Hashable {
        enum Kind: Hashable {
            case none
            case builtinDLogM
            case file(URL)
        }

        let id: String
        let name: String
        let kind: Kind
    }

    @Published private(set) var entries: [Entry] = []
    @Published var lastError: String?

    @Published var selectedID: String {
        didSet {
            defaults.set(selectedID, forKey: Keys.selected)
            apply()
        }
    }

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            apply()
        }
    }

    @Published var intensity: Double {
        didSet {
            defaults.set(intensity, forKey: Keys.intensity)
            apply()
        }
    }

    @Published var colorSpaceOption: LUTColorSpaceOption {
        didSet {
            defaults.set(colorSpaceOption.rawValue, forKey: Keys.colorSpace)
            apply()
        }
    }

    private enum Keys {
        static let selected = "lut.selected"
        static let enabled = "lut.enabled"
        static let intensity = "lut.intensity"
        static let colorSpace = "lut.colorSpace"
    }

    static let noneID = "none"
    static let builtinDLogMID = "builtin.dlogm"

    private let defaults = UserDefaults.standard
    private var cubeCache: [String: CubeLUT] = [:]

    let lutsDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        lutsDirectory = appSupport.appendingPathComponent("Rushlight/LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: lutsDirectory, withIntermediateDirectories: true)

        selectedID = defaults.string(forKey: Keys.selected) ?? Self.builtinDLogMID
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        intensity = defaults.object(forKey: Keys.intensity) as? Double ?? 1.0
        colorSpaceOption = LUTColorSpaceOption(rawValue: defaults.string(forKey: Keys.colorSpace) ?? "") ?? .auto

        reload()
        apply()
    }

    var selectedEntry: Entry? {
        entries.first { $0.id == selectedID }
    }

    func reload() {
        var list: [Entry] = [
            Entry(id: Self.noneID, name: "None (original)", kind: .none),
            Entry(id: Self.builtinDLogMID, name: "D-Log M → Rec.709 (built-in approx.)", kind: .builtinDLogM),
        ]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: lutsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let cubes = files
            .filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in cubes {
            let name = url.deletingPathExtension().lastPathComponent
            list.append(Entry(id: "file:\(url.lastPathComponent)", name: name, kind: .file(url)))
        }
        entries = list

        if !entries.contains(where: { $0.id == selectedID }) {
            selectedID = Self.builtinDLogMID
        }
    }

    /// Validates and copies .cube files into the library, then selects the
    /// first imported one.
    func importLUTs(from urls: [URL]) {
        var firstImportedID: String?
        for url in urls where url.pathExtension.lowercased() == "cube" {
            do {
                _ = try CubeLUT.parse(contentsOf: url)
                var dest = lutsDirectory.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    let base = url.deletingPathExtension().lastPathComponent
                    var counter = 2
                    repeat {
                        dest = lutsDirectory.appendingPathComponent("\(base)-\(counter).cube")
                        counter += 1
                    } while FileManager.default.fileExists(atPath: dest.path)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                if firstImportedID == nil { firstImportedID = "file:\(dest.lastPathComponent)" }
            } catch {
                lastError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        reload()
        if let id = firstImportedID {
            selectedID = id
            isEnabled = true
        }
    }

    func removeLUT(_ entry: Entry) {
        guard case .file(let url) = entry.kind else { return }
        try? FileManager.default.removeItem(at: url)
        cubeCache[entry.id] = nil
        reload()
    }

    func toggleEnabled() {
        isEnabled.toggle()
    }

    private func resolveCube(for id: String) -> CubeLUT? {
        if let cached = cubeCache[id] { return cached }
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        let cube: CubeLUT?
        switch entry.kind {
        case .none:
            cube = nil
        case .builtinDLogM:
            cube = BuiltinLUT.dlogMToRec709()
        case .file(let url):
            do {
                cube = try CubeLUT.parse(contentsOf: url)
            } catch {
                lastError = "Could not load \(entry.name): \(error.localizedDescription)"
                cube = nil
            }
        }
        if let cube { cubeCache[id] = cube }
        return cube
    }

    private func apply() {
        let cube = resolveCube(for: selectedID)
        let enabled = isEnabled
        let amount = Float(intensity)
        let cs = colorSpaceOption.colorSpace
        LUTEngine.shared.update { state in
            state.cube = cube
            state.isEnabled = enabled
            state.intensity = amount
            state.colorSpaceOverride = cs
        }
    }
}
