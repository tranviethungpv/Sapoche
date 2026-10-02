import AVFoundation
import Combine
import Flutter
import Foundation
import UIKit

/// Plays the queue's songs with AVQueuePlayer: the song that plays and, behind it, the one after it, so that the next
/// song follows with no gap. A song that is on the disk plays from its file. One that is not starts at once from its
/// stream, piece by piece through an HLS playlist (see [MediaLibrary.playableAtOnce]), while its file is fetched for
/// next time; the next song is fetched whole before it is put behind the current one, unless it is too long to keep.
/// With the picture on, the picture and the sound are played from their streams through one HLS playlist, and drawn
/// into a texture for Flutter.
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
    private let loader: PlaylistLoader
    private let maxVideoHeight: () -> Int
    private let log: (String) -> Void

    /// The song the player is on, and the item that holds it; streamed when any of it comes from the network.
    private var current: QueueItem?
    private var currentPlayerItem: AVPlayerItem?
    private var currentHasVideo = false
    private var currentStreamed = false
    /// The song that plays without its picture because none could be had, so it is not tried again and the screen
    /// shows the cover instead of waiting.
    private var pictureless: String?

    /// The song wanted after it, and the item that was made for it once its file was there.
    private var queuedNext: QueueItem?
    private var queuedPlayerItem: AVPlayerItem?
    private var queuedHasVideo = false
    private var queuedStreamed = false
    private var nextTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    /// Fetches the file of the song that plays from its stream, for next time.
    private var keepTask: Task<Void, Never>?

    private var speed: Float = 1
    private var pauseAtEnd = false
    private var pausedAtEnd = false
    private var wasPlayingBeforeInterruption = false
    private var cancellables: Set<AnyCancellable> = []
    private var itemCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    private var sessionActive = false
    /// The last item whose failure was told, so that it is told once.
    private weak var reportedFailure: AVPlayerItem?

    private var videoOn = false
    private var videoVisible = false
    private var texture: VideoTexture?
    private var textureId: Int64?
    private var ticker: CADisplayLink?

    init(library: MediaLibrary, maxVideoHeight: @escaping () -> Int, log: @escaping (String) -> Void = { _ in }) {
        self.library = library
        self.loader = PlaylistLoader(playlists: library.playlists, log: log)
        self.maxVideoHeight = maxVideoHeight
        self.log = log
        super.init()
        // A file has nothing to wait for; a song that streams changes this, see adopt
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        watchPlayer()
        watchSystem()
    }

    // ------------------------------------------------------------------ PlayerPort

    func prepare(_ item: QueueItem, seekToMs: Int64) async throws {
        cancelNext()
        rebuildTask?.cancel()
        keepTask?.cancel()
        var playable = try await library.playableAtOnce(item.videoId)
        var pictureInPieces = true
        while true {
            try Task.checkCancellation()
            let built = await build(item, playable, pictureInPieces: pictureInPieces)
            try Task.checkCancellation()
            activateSession()

            player.pause()
            player.removeAllItems()
            forgetItems(keeping: built.item)
            pausedAtEnd = false
            current = item
            queuedNext = nil
            adopt(built)
            player.insert(built.item, after: nil)
            watch(built.item)
            do {
                try await waitUntilReady(built.item)
                break
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if built.inPieces && built.video {
                    // The picture and the sound in pieces would not play: the picture is added the way it was before
                    log("'\(item.title)' would not play with its picture in pieces (\(error.localizedDescription)), trying it another way")
                    pictureInPieces = false
                } else if playable.isPlaylist {
                    // The stream in pieces would not play: the song is fetched whole, as it was before
                    log("'\(item.title)' would not play in pieces (\(error.localizedDescription)), fetching it whole")
                    playable = try await library.playable(item.videoId, piecesWhenLong: false)
                } else if playable.isFile {
                    // A file the player will not open: forget it, and play the song from the stream instead
                    log("the player could not open the file of '\(item.title)' (\(error.localizedDescription)), using the stream")
                    await library.forget(item.videoId)
                    playable = try await library.streamed(item.videoId)
                } else {
                    throw error
                }
            }
        }
        if playable.isPlaylist { keepForLater(item) }
        pictureless = wantsVideo && !currentHasVideo ? item.videoId : nil
        showPicture(wantsVideo)
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
        if currentStreamed {
            // At once, with what is there: the room counts on the start, and the player still waits out a stall later
            player.playImmediately(atRate: speed)
        } else {
            player.play()
            if speed != 1 { player.rate = speed }
        }
        onChange?()
    }

    func pause() {
        player.pause()
        onChange?()
    }

    func stop() {
        cancelNext()
        rebuildTask?.cancel()
        keepTask?.cancel()
        player.pause()
        player.removeAllItems()
        forgetItems()
        current = nil
        currentPlayerItem = nil
        currentHasVideo = false
        currentStreamed = false
        pictureless = nil
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
                let built = await self.build(item, playable, pictureInPieces: true)
                try Task.checkCancellation()
                self.insertNext(item, built)
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
            videoHeight: Int(size.height),
            noPicture: wantsVideo && current != nil && !currentHasVideo && pictureless == current?.videoId
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

    /// Shows or hides the picture. A song that has its picture keeps it and only turns it on or off, which costs no gap
    /// in the sound: when the app goes to the background, when it comes back, when the person switches to sound only.
    /// A song loaded without one is loaded again with it, once it is wanted and could be had; a new song gets its
    /// picture only while somebody looks, so nothing is fetched for nobody.
    private func applyVideo() {
        showPicture(wantsVideo)
        if wantsVideo, current != nil, !currentHasVideo, pictureless != current?.videoId {
            rebuildTask?.cancel()
            rebuildTask = Task { [weak self] in await self?.rebuildCurrent() }
        }
        // The queued song is not heard yet: it is simply made again, with or without its picture
        if let next = queuedNext, wantsVideo != queuedHasVideo {
            cancelNext()
            setNext(next)
        }
        updateTicker()
        onChange?()
    }

    /// Turns the picture of the current and the queued item on or off where they are.
    private func showPicture(_ shown: Bool) {
        for item in [currentPlayerItem, queuedPlayerItem].compactMap({ $0 }) {
            for track in item.tracks where track.assetTrack?.mediaType == .video && track.isEnabled != shown {
                track.isEnabled = shown
            }
        }
    }

    /// Puts the same song in again with its picture, at the moment it has got to, playing if it was playing. When no
    /// picture can be had the song is left as it plays.
    private func rebuildCurrent() async {
        guard let item = current, let old = currentPlayerItem else { return }
        let next = queuedNext
        do {
            let playable = try await library.playableAtOnce(item.videoId)
            let built = await build(item, playable, pictureInPieces: true)
            try Task.checkCancellation()
            guard current?.id == item.id, currentPlayerItem === old else { return }
            guard built.video else {
                if wantsVideo { pictureless = item.videoId }
                onChange?()
                return
            }
            // Taken now, not before the item was made: that took a moment, and the song went on meanwhile
            let resume = player.timeControlStatus != .paused
            let position = positionMs()
            cancelNext()
            player.pause()
            player.removeAllItems()
            forgetItems(keeping: built.item)
            adopt(built)
            player.insert(built.item, after: nil)
            watch(built.item)
            try await waitUntilReady(built.item)
            showPicture(wantsVideo)
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

    /// An item made for a song: whether it shows the picture, whether the picture and the sound come in pieces from
    /// one playlist, and whether any of it comes from the network.
    private struct Built {
        let item: AVPlayerItem
        let video: Bool
        let inPieces: Bool
        let streamed: Bool
    }

    /// Makes the item for a song: its sound, and its picture with it when that is wanted and the video has one. The two
    /// come in pieces from one playlist, unless [pictureInPieces] is off or that cannot be laid out; then the picture
    /// stream is put beside the sound in a composition.
    private func build(_ queued: QueueItem, _ playable: Playable, pictureInPieces: Bool) async -> Built {
        if wantsVideo && pictureInPieces {
            do {
                if let both = try await library.pictured(queued.videoId, maxHeight: maxVideoHeight()) {
                    return Built(item: withPicture(plain(asset(both))), video: true, inPieces: true, streamed: true)
                }
            } catch {
                // Cancelled when the song was changed meanwhile: nothing went wrong
                if !Task.isCancelled { log("could not lay out the picture of '\(queued.title)' in pieces: \(error.localizedDescription)") }
            }
        }
        let audio = asset(playable)
        if wantsVideo {
            do {
                if let picture = try await library.video(queued.videoId, maxHeight: maxVideoHeight()) {
                    let item = try await withTimeout(ms: 20_000) { try await Self.compose(audio: audio, picture: self.asset(picture)) }
                    item.audioTimePitchAlgorithm = .timeDomain
                    return Built(item: withPicture(item), video: true, inPieces: false, streamed: true)
                }
                log("'\(queued.title)' has no picture an iPhone plays")
            } catch {
                if !Task.isCancelled { log("could not add the picture of '\(queued.title)': \(error.localizedDescription)") }
            }
        }
        return Built(item: plain(audio), video: false, inPieces: false, streamed: !playable.isFile)
    }

    /// Lets the picture of [item] be drawn into the texture.
    private func withPicture(_ item: AVPlayerItem) -> AVPlayerItem {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
        item.add(output)
        outputs[ObjectIdentifier(item)] = output
        return item
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
        let wanted = texture != nil && currentHasVideo && wantsVideo
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
        if playable.isPlaylist {
            // The playlist is read through the loader; its pieces are fetched by the player, and need no particular agent
            let asset = AVURLAsset(url: playable.url)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            return asset
        }
        return AVURLAsset(url: playable.url, options: ["AVURLAssetHTTPHeaderFieldsKey": playable.headers])
    }

    private func plain(_ asset: AVURLAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        // Pitch stays where it is when the speed is nudged to keep in step with the room
        item.audioTimePitchAlgorithm = .timeDomain
        return item
    }

    /// What the player is on now.
    private func adopt(_ built: Built) {
        adopt(built.item, hasVideo: built.video, streamed: built.streamed)
    }

    private func adopt(_ item: AVPlayerItem, hasVideo: Bool, streamed: Bool) {
        currentPlayerItem = item
        currentHasVideo = hasVideo
        currentStreamed = streamed
        // A song from the network waits out a stall and goes on by itself; a file never stalls
        player.automaticallyWaitsToMinimizeStalling = streamed
        updateTicker()
    }

    /// Fetches the file of [item], which plays from its stream, so that the next time it plays from the disk.
    private func keepForLater(_ item: QueueItem) {
        keepTask?.cancel()
        let library = library
        keepTask = Task { await library.keep(item.videoId) }
    }

    /// Puts the next song behind the one that plays, if that is still the song wanted.
    private func insertNext(_ item: QueueItem, _ built: Built) {
        guard current != nil, queuedNext?.id == item.id, queuedNext?.videoId == item.videoId, queuedPlayerItem == nil,
              let last = player.items().last else { return }
        queuedPlayerItem = built.item
        queuedHasVideo = built.video
        queuedStreamed = built.streamed
        player.insert(built.item, after: last)
        watch(built.item)
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
        queuedStreamed = false
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
            throw PlayerNotReady(message: "The player did not get ready (item status \(item.status.rawValue), waiting for \(waiting))")
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
                self.failed(item, item.error ?? URLError(.cannotDecodeContentData))
            }
    }

    /// Tells the owner of the queue that the song broke, once per item (the player tells it in two ways); the owner
    /// loads the song again. A song from the network gets a fresh address first, as the one it had may be what broke.
    private func failed(_ item: AVPlayerItem, _ error: Error) {
        guard item !== reportedFailure, let song = current else { return }
        reportedFailure = item
        guard currentStreamed else {
            onError?(error)
            return
        }
        Task { [weak self] in
            await self?.library.refresh(song.videoId)
            self?.onError?(error)
        }
    }

    private func currentItemChanged(_ item: AVPlayerItem?) {
        guard let item, item === queuedPlayerItem, let next = queuedNext else { return }
        // Only a natural move to the queued successor; our own loads put other items in
        current = next
        adopt(item, hasVideo: queuedHasVideo, streamed: queuedStreamed)
        // The queued song is made again whenever its picture becomes wanted (see applyVideo): without one now, it has none
        pictureless = wantsVideo && !queuedHasVideo ? next.videoId : nil
        queuedNext = nil
        queuedPlayerItem = nil
        queuedHasVideo = false
        queuedStreamed = false
        showPicture(wantsVideo)
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
                guard let self, let item = note.object as? AVPlayerItem, item === self.currentPlayerItem else { return }
                self.failed(item, error ?? URLError(.networkConnectionLost))
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
