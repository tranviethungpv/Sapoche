import AVFoundation
import Combine
import Flutter
import Foundation
import UIKit

/// Plays the queue's songs with AVQueuePlayer: the song that plays and, behind it, the one after it, so that the next
/// song follows with no gap. A song is a whole file on the disk by the time it is played, see [MediaLibrary], so
/// seeking is exact and nothing stalls for the network in the middle of a song. With the picture on, the picture
/// stream is played beside the file in one composition, and drawn into a texture for Flutter.
@MainActor
final class AVPlayerEngine: NSObject, PlayerEngine {
    var onEnded: (() -> Void)?
    var onAdvanced: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onChange: (() -> Void)?
    var onSongEndPause: (() -> Void)?

    /// Where textures are made for the picture; given by the plugin once Flutter is up.
    var textures: FlutterTextureRegistry?

    private let player = AVQueuePlayer()
    private let library: MediaLibrary
    private let maxVideoHeight: () -> Int
    private let log: (String) -> Void

    /// The song the player is on, and the item that holds it.
    private var current: QueueItem?
    private var currentPlayerItem: AVPlayerItem?
    private var currentHasVideo = false

    /// The song wanted after it, and the item that was made for it once its file was there.
    private var queuedNext: QueueItem?
    private var queuedPlayerItem: AVPlayerItem?
    private var queuedHasVideo = false
    private var nextTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?

    private var speed: Float = 1
    private var pauseAtEnd = false
    private var pausedAtEnd = false
    private var wasPlayingBeforeInterruption = false
    private var cancellables: Set<AnyCancellable> = []
    private var itemCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    private var sessionActive = false

    private var videoOn = false
    private var videoVisible = false
    private var texture: VideoTexture?
    private var textureId: Int64?
    private var ticker: CADisplayLink?

    init(library: MediaLibrary, maxVideoHeight: @escaping () -> Int, log: @escaping (String) -> Void = { _ in }) {
        self.library = library
        self.maxVideoHeight = maxVideoHeight
        self.log = log
        super.init()
        // The next song is only inserted once its file is there, so there is nothing to gain from waiting for the network
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        watchPlayer()
        watchSystem()
    }

    // ------------------------------------------------------------------ PlayerPort

    func prepare(_ item: QueueItem, seekToMs: Int64) async throws {
        cancelNext()
        rebuildTask?.cancel()
        var playable = try await library.playable(item.videoId)
        while true {
            try Task.checkCancellation()
            let built = await build(item, playable)
            try Task.checkCancellation()
            activateSession()

            player.pause()
            player.removeAllItems()
            forgetItems(keeping: built.item)
            pausedAtEnd = false
            current = item
            queuedNext = nil
            adopt(built.item, hasVideo: built.video)
            player.insert(built.item, after: nil)
            watch(built.item)
            do {
                try await waitUntilReady(built.item)
                break
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // A file the player will not open: forget it, and play the song from the stream instead
                guard playable.isFile else { throw error }
                log("the player could not open the file of '\(item.title)' (\(error.localizedDescription)), using the stream")
                await library.forget(item.videoId)
                playable = try await library.streamed(item.videoId)
            }
        }
        if seekToMs > 0 { _ = await seek(to: seekToMs) }
        onChange?()
    }

    func seekTo(_ positionMs: Int64) async throws {
        pausedAtEnd = false
        _ = await seek(to: positionMs)
        try Task.checkCancellation()
        onChange?()
    }

    func play() {
        guard current != nil else { return }
        activateSession()
        if pausedAtEnd {
            // The song ended with the sleep timer waiting for it; the person wants to go on, so the next one starts
            pausedAtEnd = false
            player.actionAtItemEnd = pauseAtEnd ? .pause : .advance
            if queuedPlayerItem != nil { player.advanceToNextItem() }
        }
        player.play()
        if speed != 1 { player.rate = speed }
        onChange?()
    }

    func pause() {
        player.pause()
        onChange?()
    }

    func stop() {
        cancelNext()
        rebuildTask?.cancel()
        player.pause()
        player.removeAllItems()
        forgetItems()
        current = nil
        currentPlayerItem = nil
        currentHasVideo = false
        queuedNext = nil
        queuedPlayerItem = nil
        pausedAtEnd = false
        updateTicker()
        onChange?()
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        // Setting a rate on a paused player would start it
        if player.timeControlStatus != .paused, player.rate != newSpeed { player.rate = newSpeed }
    }

    func setNext(_ item: QueueItem?) {
        guard current != nil else { return }
        if item?.id == queuedNext?.id && item?.videoId == queuedNext?.videoId { return }
        cancelNext()
        queuedNext = item
        guard let item else { return }
        nextTask = Task { [weak self] in
            guard let self else { return }
            do {
                let playable = try await self.library.playable(item.videoId)
                try Task.checkCancellation()
                let built = await self.build(item, playable)
                try Task.checkCancellation()
                self.insertNext(item, built.item, hasVideo: built.video)
            } catch is CancellationError {
                // Replaced by a newer choice
            } catch {
                self.log("could not prepare the next song '\(item.title)': \(error.localizedDescription)")
            }
        }
    }

    func positionMs() -> Int64 {
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? max(Int64(seconds * 1000), 0) : 0
    }

    func isPlaying() -> Bool { player.timeControlStatus == .playing }

    // ------------------------------------------------------------------ PlayerEngine

    var loadedItem: QueueItem? { current }

    var wantsSound: Bool { current != nil && player.timeControlStatus != .paused }

    func playerInfo() -> PlayerInfo {
        let seconds = currentPlayerItem.map { CMTimeGetSeconds($0.duration) } ?? 0
        let size = currentHasVideo ? currentPlayerItem?.presentationSize ?? .zero : .zero
        return PlayerInfo(
            playing: player.timeControlStatus == .playing,
            buffering: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            positionMs: positionMs(),
            durationMs: seconds.isFinite && seconds > 0 ? Int64(seconds * 1000) : 0,
            videoWidth: Int(size.width),
            videoHeight: Int(size.height)
        )
    }

    func resumeLocally() {
        play()
    }

    func setVolume(_ volume: Float) {
        player.volume = volume
    }

    func setPauseAtSongEnd(_ on: Bool) {
        pauseAtEnd = on
        player.actionAtItemEnd = on ? .pause : .advance
    }

    // ------------------------------------------------------------------ the picture

    func setVideoMode(_ on: Bool) {
        if videoOn == on { return }
        videoOn = on
        applyVideo()
    }

    func setVideoVisible(_ visible: Bool) {
        if videoVisible == visible { return }
        videoVisible = visible
        applyVideo()
    }

    func videoSurface() throws -> Int64 {
        if let textureId { return textureId }
        guard let textures else { throw VideoUnavailable() }
        let made = VideoTexture()
        let id = textures.register(made)
        texture = made
        textureId = id
        updateTicker()
        return id
    }

    private var wantsVideo: Bool { videoOn && videoVisible }

    /// Loads the song again with or without its picture when that is not what it is playing with; the picture is only
    /// fetched while somebody looks at it.
    private func applyVideo() {
        if current != nil, wantsVideo != currentHasVideo {
            rebuildTask?.cancel()
            rebuildTask = Task { [weak self] in await self?.rebuildCurrent() }
        }
        if let next = queuedNext, wantsVideo != queuedHasVideo {
            cancelNext()
            setNext(next)
        }
        updateTicker()
    }

    /// Puts the same song in again, at the same moment, playing if it was playing.
    private func rebuildCurrent() async {
        guard let item = current, let old = currentPlayerItem else { return }
        let resume = player.timeControlStatus != .paused
        let position = positionMs()
        let next = queuedNext
        do {
            let playable = try await library.playable(item.videoId)
            let built = await build(item, playable)
            try Task.checkCancellation()
            guard current?.id == item.id, currentPlayerItem === old else { return }
            cancelNext()
            player.pause()
            player.removeAllItems()
            forgetItems(keeping: built.item)
            adopt(built.item, hasVideo: built.video)
            player.insert(built.item, after: nil)
            watch(built.item)
            try await waitUntilReady(built.item)
            if position > 0 { _ = await seek(to: position) }
            if resume { play() }
            if let next { setNext(next) }
            onChange?()
        } catch is CancellationError {
            // The song changed meanwhile
        } catch {
            log("could not change the picture of '\(item.title)': \(error.localizedDescription)")
        }
    }

    /// Makes the item for a song: its file, and its picture beside it when that is wanted and the video has one.
    private func build(_ queued: QueueItem, _ playable: Playable) async -> (item: AVPlayerItem, video: Bool) {
        let audio = asset(playable)
        if wantsVideo {
            do {
                if let picture = try await library.video(queued.videoId, maxHeight: maxVideoHeight()) {
                    let item = try await withTimeout(ms: 20_000) { try await Self.compose(audio: audio, picture: self.asset(picture)) }
                    item.audioTimePitchAlgorithm = .timeDomain
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
                    item.add(output)
                    outputs[ObjectIdentifier(item)] = output
                    return (item, true)
                }
                log("'\(queued.title)' has no picture an iPhone plays")
            } catch {
                log("could not add the picture of '\(queued.title)': \(error.localizedDescription)")
            }
        }
        return (plain(audio), false)
    }

    /// The song's sound and the video's picture as one thing to play, so that they stay in step.
    private static func compose(audio: AVURLAsset, picture: AVURLAsset) async throws -> AVPlayerItem {
        async let soundTracks = audio.loadTracks(withMediaType: .audio)
        async let pictureTracks = picture.loadTracks(withMediaType: .video)
        let (sounds, pictures) = try await (soundTracks, pictureTracks)
        guard let sound = sounds.first, let video = pictures.first else { throw URLError(.cannotDecodeContentData) }
        let length = try await audio.load(.duration)
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)

        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: length)
        guard let soundOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let pictureOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw URLError(.cannotDecodeContentData) }
        try soundOut.insertTimeRange(range, of: sound, at: .zero)
        try pictureOut.insertTimeRange(range, of: video, at: .zero)
        pictureOut.preferredTransform = transform
        composition.naturalSize = size
        return AVPlayerItem(asset: composition)
    }

    private func updateTicker() {
        let wanted = texture != nil && currentHasVideo && videoVisible
        if wanted, ticker == nil {
            let link = CADisplayLink(target: TickTarget { [weak self] in self?.drawFrame() }, selector: #selector(TickTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
            link.add(to: .main, forMode: .common)
            ticker = link
        } else if !wanted, let link = ticker {
            link.invalidate()
            ticker = nil
        }
    }

    /// Hands the newest picture to Flutter.
    private func drawFrame() {
        guard let texture, let textureId, let item = currentPlayerItem, let output = outputs[ObjectIdentifier(item)] else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        texture.set(buffer)
        textures?.textureFrameAvailable(textureId)
    }

    // ------------------------------------------------------------------ items

    private func asset(_ playable: Playable) -> AVURLAsset {
        if playable.isFile { return AVURLAsset(url: playable.url) }
        return AVURLAsset(url: playable.url, options: ["AVURLAssetHTTPHeaderFieldsKey": playable.headers])
    }

    private func plain(_ asset: AVURLAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        // Pitch stays where it is when the speed is nudged to keep in step with the room
        item.audioTimePitchAlgorithm = .timeDomain
        return item
    }

    /// What the player is on now.
    private func adopt(_ item: AVPlayerItem, hasVideo: Bool) {
        currentPlayerItem = item
        currentHasVideo = hasVideo
        updateTicker()
    }

    /// Puts the next song behind the one that plays, if that is still the song wanted.
    private func insertNext(_ item: QueueItem, _ playerItem: AVPlayerItem, hasVideo: Bool) {
        guard current != nil, queuedNext?.id == item.id, queuedNext?.videoId == item.videoId, queuedPlayerItem == nil,
              let last = player.items().last else { return }
        queuedPlayerItem = playerItem
        queuedHasVideo = hasVideo
        player.insert(playerItem, after: last)
        watch(playerItem)
    }

    private func cancelNext() {
        nextTask?.cancel()
        nextTask = nil
        if let queued = queuedPlayerItem {
            player.remove(queued)
            itemCancellables[ObjectIdentifier(queued)] = nil
            outputs[ObjectIdentifier(queued)] = nil
        }
        queuedPlayerItem = nil
        queuedHasVideo = false
        queuedNext = nil
    }

    /// Lets go of what was kept for the items that left the player, other than [keeping].
    private func forgetItems(keeping: AVPlayerItem? = nil) {
        itemCancellables.removeAll()
        let kept = keeping.flatMap { item in outputs[ObjectIdentifier(item)].map { (ObjectIdentifier(item), $0) } }
        outputs.removeAll()
        if let kept { outputs[kept.0] = kept.1 }
    }

    /// Waits until the item can start at once; throws when it cannot be played or takes too long.
    private func waitUntilReady(_ item: AVPlayerItem) async throws {
        do {
            try await withTimeout(ms: 20_000) {
                // The status is looked at, not observed: a change that comes between two looks cannot be missed, which
                // a file that opens at once could do to an observer
                while true {
                    switch item.status {
                    case .readyToPlay: return
                    case .failed: throw item.error ?? URLError(.cannotDecodeContentData)
                    default: try await Task.sleep(nanoseconds: 40_000_000)
                    }
                }
            }
        } catch is TimedOut {
            let waiting = player.reasonForWaitingToPlay?.rawValue ?? "nothing"
            throw PlayerNotReady(message: "The player did not get ready (item status \(item.status.rawValue), playable \(item.asset.isPlayable), waiting for \(waiting))")
        }
    }

    private func seek(to positionMs: Int64) async -> Bool {
        let target = CMTime(value: positionMs, timescale: 1000)
        return await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // ------------------------------------------------------------------ what the player reports

    private func watchPlayer() {
        // Play, pause and buffering: the screen shows them at once
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onChange?() }
            .store(in: &cancellables)
        // The player moving on to the song queued behind the current one, by itself
        player.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.currentItemChanged(item) }
            .store(in: &cancellables)
    }

    private func watch(_ item: AVPlayerItem) {
        // A song that breaks while it plays: the owner of the queue loads it again
        itemCancellables[ObjectIdentifier(item)] = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, status == .failed, item === self.currentPlayerItem else { return }
                self.log("the player failed: \(item.error?.localizedDescription ?? "unknown")")
                self.onError?(item.error ?? URLError(.cannotDecodeContentData))
            }
    }

    private func currentItemChanged(_ item: AVPlayerItem?) {
        guard let item, item === queuedPlayerItem, let next = queuedNext else { return }
        // Only a natural move to the queued successor; our own loads put other items in
        current = next
        adopt(item, hasVideo: queuedHasVideo)
        queuedNext = nil
        queuedPlayerItem = nil
        queuedHasVideo = false
        onAdvanced?()
        onChange?()
    }

    private func itemEnded(_ item: AVPlayerItem) {
        guard item === currentPlayerItem else { return }
        if queuedPlayerItem != nil {
            if pauseAtEnd {
                // The sleep timer waits for the end of this song: stay here, and go on when asked
                pausedAtEnd = true
                player.pause()
                onSongEndPause?()
            }
            // Otherwise the queue player moves on by itself and the change of item tells us
            return
        }
        onEnded?()
        if pauseAtEnd { onSongEndPause?() }
        onChange?()
    }

    // ------------------------------------------------------------------ the system

    private func watchSystem() {
        let center = NotificationCenter.default
        center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in self?.itemEnded(item) }
        }
        center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self, (note.object as? AVPlayerItem) === self.currentPlayerItem else { return }
                self.onError?(error ?? URLError(.networkConnectionLost))
            }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in self?.interruption(raw, options) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.routeChanged(raw) }
        }
    }

    /// A call or an alarm took the sound: the player stopped by itself; when the other thing is over, it goes on if it was playing.
    private func interruption(_ rawType: UInt?, _ rawOptions: UInt?) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = player.timeControlStatus != .paused
            onChange?()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
            if wasPlayingBeforeInterruption && options.contains(.shouldResume) {
                log("the interruption is over, playing again")
                play()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    /// Headphones pulled out: the music must not go on through the speaker.
    private func routeChanged(_ rawReason: UInt?) {
        guard let rawReason, AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
        log("the output went away, pausing")
        pause()
    }

    /// Lets the system know sound is about to play: it is only done once there is something to play, so that opening the
    /// app does not stop what another app plays.
    private func activateSession() {
        guard !sessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            sessionActive = true
        } catch {
            log("could not take the audio session: \(error.localizedDescription)")
        }
    }
}

/// The player took too long to get ready; the message says what state it was in.
struct PlayerNotReady: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// The picture of the playing song, as Flutter asks for it: the newest frame the player made.
final class VideoTexture: NSObject, FlutterTexture {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func set(_ new: CVPixelBuffer) {
        lock.lock()
        buffer = new
        lock.unlock()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        return buffer.map { Unmanaged.passRetained($0) }
    }
}

/// Lets a display link call a closure without being kept alive by it.
private final class TickTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func tick() {
        action()
    }
}
