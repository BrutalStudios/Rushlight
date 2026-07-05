import AppKit
import AVFoundation
import Combine
import CoreImage
import Foundation

/// Drives an `AVQueuePlayer` over the playlist. The clip after the current one
/// is always pre-built (asset parsed, LUT composition attached) and enqueued,
/// so both auto-advance and manual next are gapless. Assets and compositions
/// are cached so jumping back is instant too.
@MainActor
final class PlayerController: ObservableObject {
    let player = AVQueuePlayer()
    private let playlist: Playlist
    private let classifications: ClassificationStore

    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    @Published var playbackRate: Float {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: Keys.rate)
            if isPlaying { player.rate = playbackRate }
        }
    }

    @Published var loopPlaylist: Bool {
        didSet { UserDefaults.standard.set(loopPlaylist, forKey: Keys.loop) }
    }

    static let speedSteps: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private enum Keys {
        static let rate = "player.rate"
        static let loop = "player.loop"
    }

    private var cancellables = Set<AnyCancellable>()
    private var timeObserver: Any?

    /// Bumped on every explicit jump to cancel stale async item builds.
    private var generation = 0

    private var isScrubbing = false
    private var wasPlayingBeforeScrub = false

    private struct PreparedComposition {
        let composition: AVVideoComposition?
    }

    private var assetCache: [URL: AVURLAsset] = [:]
    private var compositionCache: [URL: PreparedComposition] = [:]
    private var cacheOrder: [URL] = []
    private let cacheLimit = 24

    init(playlist: Playlist, classifications: ClassificationStore) {
        self.playlist = playlist
        self.classifications = classifications

        let defaults = UserDefaults.standard
        let savedRate = defaults.float(forKey: Keys.rate)
        playbackRate = Self.speedSteps.contains(savedRate) ? savedRate : 1.0
        loopPlaylist = defaults.bool(forKey: Keys.loop)

        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false

        player.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                self?.currentItemDidChange(item)
            }
            .store(in: &cancellables)

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
            }
            .store(in: &cancellables)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in self?.itemDidPlayToEnd(item) }
        }

        NotificationCenter.default.addObserver(
            forName: .rushlightLUTChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPausedFrame() }
        }
    }

    // MARK: - Playback control

    func play(at index: Int, autostart: Bool = true) {
        guard playlist.items.indices.contains(index) else { return }
        let targetURL = playlist.items[index].url
        generation += 1
        let gen = generation

        let queued = player.items()

        // Restarting the clip that is already current.
        if let current = queued.first, Self.url(of: current) == targetURL {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            if autostart { player.playImmediately(atRate: playbackRate) }
            return
        }

        // Gapless fast path: the target is already prepared and enqueued.
        if queued.count >= 2, Self.url(of: queued[1]) == targetURL {
            player.advanceToNextItem()
            if autostart { player.playImmediately(atRate: playbackRate) }
            return
        }

        Task {
            guard let item = await makeItem(for: targetURL) else { return }
            guard gen == self.generation else { return }
            player.removeAllItems()
            player.insert(item, after: nil)
            if autostart { player.playImmediately(atRate: playbackRate) }
        }
    }

    func next() {
        guard let i = playlist.currentIndex else { return }
        if i + 1 < playlist.items.count {
            play(at: i + 1)
        } else if loopPlaylist, !playlist.items.isEmpty {
            play(at: 0)
        }
    }

    func previous() {
        guard let i = playlist.currentIndex else { return }
        if i > 0 {
            play(at: i - 1)
        } else if loopPlaylist, playlist.items.count > 1 {
            play(at: playlist.items.count - 1)
        } else {
            seek(to: 0)
        }
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else if player.currentItem != nil {
            player.playImmediately(atRate: playbackRate)
        } else if !playlist.items.isEmpty {
            play(at: playlist.currentIndex ?? 0)
        }
    }

    func cycleSpeed(forward: Bool) {
        let steps = Self.speedSteps
        guard let idx = steps.firstIndex(of: playbackRate) else {
            playbackRate = 1.0
            return
        }
        let target = forward ? min(idx + 1, steps.count - 1) : max(idx - 1, 0)
        playbackRate = steps[target]
    }

    // MARK: - Seeking

    func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func seek(to seconds: Double, precise: Bool = true) {
        guard let item = player.currentItem else { return }
        let itemDuration = duration > 0 ? duration : item.duration.seconds
        let upper = itemDuration.isFinite ? max(0, itemDuration - 0.05) : seconds
        let target = min(max(0, seconds), upper)
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
        currentTime = target
    }

    func beginScrub() {
        guard !isScrubbing else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        player.pause()
    }

    func scrub(to seconds: Double) {
        currentTime = seconds
        seek(to: seconds, precise: false)
    }

    func endScrub() {
        isScrubbing = false
        seek(to: currentTime, precise: true)
        if wasPlayingBeforeScrub {
            player.playImmediately(atRate: playbackRate)
        }
    }

    func stepFrames(_ count: Int) {
        player.pause()
        player.currentItem?.step(byCount: count)
    }

    func toggleFullscreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    // MARK: - Queue management

    private static func url(of item: AVPlayerItem) -> URL? {
        (item.asset as? AVURLAsset)?.url
    }

    private func currentItemDidChange(_ item: AVPlayerItem?) {
        let url = item.flatMap(Self.url(of:))
        currentURL = url
        currentTime = 0
        duration = 0

        if let url, let idx = playlist.index(of: url) {
            playlist.currentIndex = idx
        }

        if let item {
            Task {
                if let d = try? await item.asset.load(.duration), d.seconds.isFinite,
                   player.currentItem == item {
                    duration = d.seconds
                }
            }
        }

        Task { await topUpQueue() }
    }

    /// Keeps exactly one prepared follow-up item enqueued behind the current
    /// one so the transition to the next clip is seamless.
    private func topUpQueue() async {
        guard let url = currentURL, let idx = playlist.index(of: url) else { return }
        let nextIndex = idx + 1
        let queued = player.items()

        guard nextIndex < playlist.items.count else {
            for extra in queued.dropFirst() { player.remove(extra) }
            return
        }
        let nextURL = playlist.items[nextIndex].url

        if queued.count >= 2, Self.url(of: queued[1]) == nextURL, queued.count == 2 {
            return
        }
        for extra in queued.dropFirst() { player.remove(extra) }

        let gen = generation
        guard let item = await makeItem(for: nextURL) else { return }
        guard gen == generation, currentURL == url, player.items().count == 1 else { return }
        player.insert(item, after: nil)
    }

    private func itemDidPlayToEnd(_ item: AVPlayerItem?) {
        guard let item, let url = Self.url(of: item) else { return }
        // Only the final clip matters here; mid-list transitions are handled
        // by AVQueuePlayer's automatic advance to the preloaded item.
        guard url == playlist.items.last?.url else { return }
        if loopPlaylist, !playlist.items.isEmpty {
            play(at: 0)
        }
    }

    private func refreshPausedFrame() {
        guard !isPlaying, player.currentItem != nil else { return }
        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Item construction

    private func makeItem(for url: URL) async -> AVPlayerItem? {
        let asset = cachedAsset(for: url)
        _ = try? await asset.load(.tracks, .duration)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        if let composition = await composition(for: asset, url: url) {
            item.videoComposition = composition
        }
        return item
    }

    private func cachedAsset(for url: URL) -> AVURLAsset {
        if let asset = assetCache[url] { return asset }
        let asset = AVURLAsset(url: url)
        assetCache[url] = asset
        rememberInCache(url)
        return asset
    }

    private func rememberInCache(_ url: URL) {
        cacheOrder.removeAll { $0 == url }
        cacheOrder.append(url)
        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            assetCache[evicted] = nil
            compositionCache[evicted] = nil
        }
    }

    private func composition(for asset: AVAsset, url: URL) async -> AVVideoComposition? {
        if let prepared = compositionCache[url] { return prepared.composition }

        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !videoTracks.isEmpty else {
            compositionCache[url] = PreparedComposition(composition: nil)
            return nil
        }

        let assetColorSpace = await Self.detectColorSpace(of: videoTracks[0])
        // Make sure the log/normal verdict is known before the first frame
        // renders; the handler then reads live state per frame.
        _ = await classifications.classification(for: url)
        let composition = try? await AVMutableVideoComposition.videoComposition(
            with: asset
        ) { request in
            let output = LUTEngine.shared.process(
                request.sourceImage,
                assetColorSpace: assetColorSpace,
                clipURL: url
            )
            request.finish(with: output, context: LUTEngine.renderContext)
        }

        compositionCache[url] = PreparedComposition(composition: composition)
        return composition
    }

    /// Maps the track's tagged color primaries/transfer to a CGColorSpace so
    /// the LUT can be applied to reconstructed original code values.
    private static func detectColorSpace(of track: AVAssetTrack) async -> CGColorSpace? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first
        else { return nil }

        let primaries = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
        ) as? String
        let transfer = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String

        if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
            return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                ?? CGColorSpace(name: CGColorSpace.itur_2020)
        }
        if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                ?? CGColorSpace(name: CGColorSpace.itur_2020)
        }

        if primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
            return CGColorSpace(name: CGColorSpace.itur_2020)
        }
        if primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) {
            return CGColorSpace(name: CGColorSpace.displayP3)
        }
        return CGColorSpace(name: CGColorSpace.itur_709)
    }
}
