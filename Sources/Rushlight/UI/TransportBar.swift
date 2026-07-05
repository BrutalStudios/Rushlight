import SwiftUI

struct TransportBar: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var playlist: Playlist

    var body: some View {
        HStack(spacing: 14) {
            transportButtons
            timeline
            trailingControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var transportButtons: some View {
        HStack(spacing: 10) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Previous clip (↑)")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 28)
            }
            .help("Play / Pause (Space)")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .help("Next clip (↓)")
        }
        .buttonStyle(.borderless)
        .disabled(playlist.items.isEmpty)
    }

    private var timeline: some View {
        HStack(spacing: 10) {
            Text(Format.time(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            TimelineSlider()

            Text(Format.time(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(PlayerController.speedSteps, id: \.self) { speed in
                    Button {
                        player.playbackRate = speed
                    } label: {
                        if speed == player.playbackRate {
                            Label(speedLabel(speed), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(speed))
                        }
                    }
                }
            } label: {
                Text(speedLabel(player.playbackRate))
                    .font(.caption.monospacedDigit())
                    .frame(width: 42)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed ([ and ])")

            Toggle(isOn: $player.loopPlaylist) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Loop playlist")

            Button {
                player.toggleFullscreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Fullscreen (F)")
        }
    }

    private func speedLabel(_ speed: Float) -> String {
        speed == speed.rounded()
            ? "\(Int(speed))×"
            : String(format: "%g×", speed)
    }
}

/// Scrubber that pauses while dragging and lands with a frame-accurate seek.
private struct TimelineSlider: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Slider(
            value: Binding(
                get: { player.currentTime },
                set: { player.scrub(to: $0) }
            ),
            in: 0...max(player.duration, 0.01),
            onEditingChanged: { editing in
                if editing {
                    player.beginScrub()
                } else {
                    player.endScrub()
                }
            }
        )
        .controlSize(.small)
        .disabled(player.duration <= 0)
    }
}
