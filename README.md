# Rushlight

A fast, native macOS player for reviewing log/raw camera footage **with a LUT applied in real time** — built for burning through hundreds of gigabytes of DJI Osmo Pocket 3 D-Log M clips without ever opening an editor.

> A *rushlight* is a humble candle that turns something raw into light — which is also what this app does to your rushes.

## Why

Log footage (D-Log M, S-Log3, V-Log, Apple Log, …) looks flat and gray in every stock player. Rushlight decodes your clips with hardware acceleration and pushes every frame through a 3D LUT on the GPU, so you watch your footage the way it will look after grading — at full 4K/60, with zero pre-processing or transcoding.

## Features

- **Real-time LUT playback** — any 3D `.cube` LUT, applied on the GPU via Core Image/Metal. Smooth at 4K.
- **Automatic log detection** — mixed folders just work: the LUT is only applied to clips detected as log footage, while normal (already-graded) and HDR videos play untouched. Detection combines DJI's `_D` filename convention, the file's color tags (HLG/PQ), and a histogram probe of sampled frames (lifted blacks + rolled highlights + muted color = log). Right-click any clip to override (`Apply LUT → Always / Never`), and toggle the whole behavior in the LUT menu.
- **Gapless clip-to-clip playback** — the next clip is always pre-buffered with its LUT composition attached, so auto-advance and manual next/previous are seamless.
- **Folder browsing** — open or drop entire folders (scanned recursively, e.g. `DCIM/`), multi-select files, natural sort (`DJI_0002` before `DJI_0010`) or sort by date.
- **Built-in D-Log M → Rec.709 approximation** so footage is watchable out of the box. For exact colors, import DJI's official *DLog-M to Rec.709* LUT (free from the [DJI Downloads](https://www.dji.com/downloads) page for your camera) via **⌘⇧L**.
- **Any camera, not just DJI** — import as many `.cube` LUTs as you like (Sony S-Log, Panasonic V-Log, Canon C-Log, Apple Log…), switch between them from the toolbar, and set the LUT input color space (auto-detected from the footage by default, including HLG/PQ).
- **LUT intensity slider** and instant **L** on/off toggle for before/after comparison.
- **Review-friendly transport** — frame stepping, 0.5×–2× speed, precise scrubbing, loop, fullscreen.
- Playlist, selected LUT, and settings persist between launches.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `↓` / `↑` | Next / previous clip (gapless) |
| `→` / `←` | Seek ±5 s (`⇧` for ±1 s) |
| `.` / `,` | Step one frame forward / back |
| `L` | Toggle LUT on/off |
| `F` | Fullscreen |
| `]` / `[` | Speed up / down |
| `⌘O` | Open videos or folder |
| `⌘⇧L` | Import LUTs |

## Building

Requires macOS 14+ and Xcode (or the Swift 5.9+ toolchain).

```sh
make app      # builds build/Rushlight.app
make run      # builds and launches it
make test     # runs the unit tests
```

Drag `build/Rushlight.app` to `/Applications` if you want it around permanently. `bash Scripts/build_app.sh --universal` produces an Intel+Apple Silicon binary.

## Supported formats

Anything AVFoundation decodes natively: H.264 / HEVC (8- and 10-bit, i.e. the Osmo Pocket 3's D-Log M and HLG files) and ProRes, in `.mp4`, `.mov`, and `.m4v` containers. Hardware decoding is used automatically.

## How the LUT pipeline works

1. Each clip gets an `AVVideoComposition` whose Core Image handler runs per frame on the GPU.
2. Before a clip first plays it is classified as **log / normal / HDR**: DJI `_D` filename → log; HLG/PQ transfer tags → HDR; otherwise a few tiny frames are decoded and their luma percentiles and saturation examined. Sidebar badges show the result, and in auto mode only log clips are graded.
3. The frame is converted into the footage's own encoded color space (auto-detected from the file's color tags — Rec.709, Rec.2020, HLG, PQ, P3 — or overridden manually in the LUT menu), which reconstructs the original code values camera LUTs expect.
4. `CIColorCubeWithColorSpace` applies the 3D LUT, optionally blended with the original by the intensity slider.
5. The handler reads LUT state dynamically, so switching or toggling LUTs, changing intensity, or overriding a clip never rebuilds the player pipeline — playback keeps rolling, gaplessly.

## License

MIT — see [LICENSE](LICENSE).
