import SwiftUI

/// Pre-export configuration: format, destination, and a note about clips the
/// LUT won't touch.
struct ExportSheet: View {
    @EnvironmentObject private var exporter: ExportManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Export with LUT", systemImage: "square.and.arrow.up")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                    .foregroundStyle(.secondary)
                if let note = skipNote {
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Format", selection: formatBinding) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            .pickerStyle(.radioGroup)

            HStack(spacing: 8) {
                Text("Save to:")
                Text(destinationLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Choose…") {
                    exporter.chooseDestination()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    exporter.cancelConfiguration()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export") {
                    exporter.startConfigured()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var summary: String {
        let count = exporter.config?.urls.count ?? 0
        if count == 1, let name = exporter.config?.urls.first?.lastPathComponent {
            return name
        }
        return "\(count) clips"
    }

    private var skipNote: String? {
        guard let config = exporter.config else { return nil }
        let lutCount = exporter.configuredLUTCount
        let skipped = config.urls.count - lutCount
        guard skipped > 0 else { return nil }
        if config.urls.count == 1 {
            return "The LUT is off/skipped for this clip — it will export unchanged."
        }
        return "\(skipped) of \(config.urls.count) clips play without the LUT (normal/HDR or LUT off) and will export unchanged."
    }

    private var destinationLabel: String {
        guard let destination = exporter.config?.destination else { return "—" }
        return destination.path.replacingOccurrences(
            of: NSHomeDirectory(), with: "~"
        )
    }

    private var formatBinding: Binding<ExportFormat> {
        Binding(
            get: { exporter.config?.format ?? .hevc },
            set: { exporter.config?.format = $0 }
        )
    }
}

/// Slim status strip above the transport bar; playback stays fully usable
/// while exports run.
struct ExportStatusStrip: View {
    @EnvironmentObject private var exporter: ExportManager

    var body: some View {
        if let active = exporter.active {
            HStack(spacing: 10) {
                ProgressView(value: active.overallProgress)
                    .frame(width: 140)
                Text(statusText(active))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Int(active.overallProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    exporter.cancel()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        } else if let message = exporter.finishedMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func statusText(_ active: ExportManager.ActiveExport) -> String {
        "Exporting \(min(active.completedCount + 1, active.totalCount))/\(active.totalCount): \(active.currentName)"
    }
}
