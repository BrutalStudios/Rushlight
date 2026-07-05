import Foundation

enum Format {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func resolution(width: Int, height: Int) -> String {
        let longest = max(width, height)
        switch longest {
        case 7600...: return "8K"
        case 3800...: return "4K"
        case 2600...: return "2.7K"
        case 1900...: return "1080p"
        case 1200...: return "720p"
        default: return "\(min(width, height))p"
        }
    }

    static func clipDetails(_ meta: VideoMeta?, sizeBytes: Int64) -> String {
        var parts: [String] = []
        if let d = meta?.durationSeconds { parts.append(time(d)) }
        if let w = meta?.width, let h = meta?.height, w > 0, h > 0 {
            var label = resolution(width: w, height: h)
            if let fps = meta?.fps {
                label += "/\(Int(fps.rounded()))"
            }
            parts.append(label)
        }
        if sizeBytes > 0 { parts.append(fileSize(sizeBytes)) }
        return parts.joined(separator: " · ")
    }
}
