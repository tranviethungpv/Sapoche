import Foundation
import MediaPlayer
import UIKit

/// What the lock screen, Control Center and headphone buttons show and do: the song that plays and play, pause, next,
/// previous and the slider. While joined to a room these control the whole room, and outside one the personal queue,
/// because they go through the [GroupController] like the buttons of the app.
@MainActor
final class NowPlaying {
    private let controller: GroupController
    private let engine: PlayerEngine

    /// The picture inside the music file of a song from this phone, by the id of the song.
    private let localCover: (String) async -> Data?
    private var shownVideoId: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var artworkCache: [String: UIImage] = [:]

    /// What the lock screen was last given and when. The system moves the time on by itself while the rate says the song
    /// plays, so the same song, state and length at the time they should be at are not given again: in a room the
    /// player changes twice a second (its drift), and each of those woke the lock screen for nothing, screen off or on.
    private var given: (signature: String, positionMs: Int64, at: TimeInterval)?

    /// The widgets, the lock screen accessories, Control Center and the Live Activity of the room.
    private let widgets = WidgetBridge()

    init(controller: GroupController, engine: PlayerEngine, localCover: @escaping (String) async -> Data? = { _ in nil }) {
        self.controller = controller
        self.engine = engine
        self.localCover = localCover
        connectButtons()
        widgets.start { [weak self] command in self?.widgetCommand(command) }
    }

    /// A button of a widget, of the lock screen or of Control Center: it does what the buttons of the lock screen do.
    private func widgetCommand(_ command: WidgetCommand) {
        EventLog.d("session", "\(command.rawValue) asked from a widget")
        switch command {
        case .playPause:
            if engine.wantsSound { controller.pauseFromOutside() } else { controller.requestPlay() }
        case .next:
            if mayMoveRoom() { controller.requestNext() }
        case .previous:
            if mayMoveRoom() { controller.requestPrev() }
        }
    }

    // ------------------------------------------------------------------ buttons

    private func connectButtons() {
        let center = MPRemoteCommandCenter.shared()
        // Each press is written to the log: from a car it is the only way to tell a button that never arrived from one that
        // arrived and did nothing
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                EventLog.d("session", "play asked from outside")
                self?.controller.requestPlay()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                EventLog.d("session", "pause asked from outside")
                self?.controller.pauseFromOutside()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                EventLog.d("session", "play or pause asked from outside (sound wanted: \(self.engine.wantsSound))")
                if self.engine.wantsSound { self.controller.pauseFromOutside() } else { self.controller.requestPlay() }
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.mayMoveRoom() else { return .commandFailed }
            Task { @MainActor in
                EventLog.d("session", "next asked from outside")
                self.controller.requestNext()
            }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.mayMoveRoom() else { return .commandFailed }
            Task { @MainActor in
                EventLog.d("session", "previous asked from outside")
                self.controller.requestPrev()
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.mayMoveRoom(), let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let ms = Int64(event.positionTime * 1000)
            Task { @MainActor in self.controller.requestSeek(ms) }
            return .success
        }
        // Skipping by seconds is not what these buttons are for
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    /// Skipping and seeking move the whole room, which the server refuses a guest of a room that only lets guests add songs.
    /// The car and the lock screen grey those buttons out instead of pressing them for nothing.
    private func mayMoveRoom() -> Bool {
        let allowed = controller.view.value.snapshot.canSteer
        if !allowed { EventLog.d("session", "a button outside the app asked to move the room, which this device may not") }
        return allowed
    }

    private var steerShown: Bool?

    private func showSteering() {
        let allowed = controller.view.value.snapshot.canSteer
        guard steerShown != allowed else { return }
        steerShown = allowed
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = allowed
        center.previousTrackCommand.isEnabled = allowed
        center.changePlaybackPositionCommand.isEnabled = allowed
    }

    // ------------------------------------------------------------------ what is shown

    /// Brings the lock screen up to date with the player; called whenever the player or the queue changed.
    func refresh() {
        showSteering()
        let center = MPNowPlayingInfoCenter.default()
        guard let item = engine.loadedItem ?? shownItem() else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            shownVideoId = nil
            artwork = nil
            given = nil
            publishWidgets(item: nil, info: nil)
            return
        }
        let info = engine.playerInfo()
        if shownVideoId != item.videoId {
            shownVideoId = item.videoId
            artwork = nil
            loadArtwork(item)
        }
        let duration = info.durationMs > 0 ? info.durationMs : item.durMs
        publishWidgets(item: item, info: info, duration: duration)
        let signature = "\(item.videoId)|\(item.title)|\(item.artist)|\(info.playing)|\(duration)|\(artwork != nil)"
        let now = ProcessInfo.processInfo.systemUptime
        if let given, given.signature == signature {
            let expected = given.positionMs + (info.playing ? Int64((now - given.at) * 1000) : 0)
            if abs(expected - info.positionMs) < 1500 { return }
        }
        given = (signature: signature, positionMs: info.positionMs, at: now)
        var fields: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(info.positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if duration > 0 { fields[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000 }
        if let artwork { fields[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = fields
        // Read by the system besides the rate, when it decides what a car or a watch shows the song as doing
        center.playbackState = info.playing ? .playing : .paused
    }

    /// Hands what plays to the widgets and, in a room, to its Live Activity; they draw it themselves from then on.
    private func publishWidgets(item: QueueItem?, info: PlayerInfo?, duration: Int64 = 0) {
        let view = controller.view.value
        let inRoom = view.roomCode != nil
        let state = view.snapshot.state
        let queue = inRoom ? (state?.queue ?? []) : view.local.queue
        let index = inRoom ? (state?.index ?? 0) : view.local.index
        let names = Dictionary(view.snapshot.members.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let listening = view.snapshot.members.filter { !$0.away }
        let next = queue.dropFirst(index + 1).prefix(WidgetSnapshot.nextRows).map {
            WidgetSnapshot.Row(title: $0.title, artist: $0.artist, by: inRoom ? names[$0.addedBy] : nil)
        }
        let started = info.map { Date().addingTimeInterval(-Double($0.positionMs) / 1000) }
        let snapshot = WidgetSnapshot(
            title: item?.title ?? "", artist: item?.artist ?? "", playing: info?.playing ?? false,
            room: view.roomCode.map { "\(state?.name ?? $0) · \(listening.count)" }, roomCode: view.roomCode,
            crew: inRoom ? listening.prefix(3).map(\.name) : [], next: Array(next), canSteer: view.snapshot.canSteer,
            startedAt: started, endsAt: duration > 0 ? started?.addingTimeInterval(Double(duration) / 1000) : nil
        )
        let address = item?.thumb
        widgets.publish(snapshot, coverFor: address, cover: address.flatMap { artworkCache[$0] }.flatMap(Self.thumbnail))
        widgets.updateRoomActivity(
            room: view.roomCode.map { (name: state?.name ?? $0, code: $0) }, snapshot: snapshot, members: listening.count
        )
    }

    /// A small JPEG of a cover for the widgets, which have little memory to draw with.
    private static func thumbnail(_ image: UIImage) -> Data? {
        let side: CGFloat = 320
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.75) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The song the queue is on while the player has nothing loaded (after a restart), so the lock screen is not blank.
    private func shownItem() -> QueueItem? {
        let view = controller.view.value
        if view.roomCode != nil { return view.snapshot.state?.current }
        return view.local.queue.isEmpty ? nil : view.local.current
    }

    private func loadArtwork(_ item: QueueItem) {
        artworkTask?.cancel()
        guard let address = item.thumb, let url = URL(string: address) else { return }
        if let image = artworkCache[address] {
            show(image, for: item.videoId)
            return
        }
        artworkTask = Task { [weak self] in
            // A song from a file has its picture inside the file; any other has an address to fetch it from
            let data: Data?
            if address.hasPrefix(LocalMusic.coverPrefix), let self {
                data = await self.localCover(String(address.dropFirst(LocalMusic.coverPrefix.count)))
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
            guard let data, let image = UIImage(data: data) else { return }
            guard let self, !Task.isCancelled else { return }
            if self.artworkCache.count > 20 { self.artworkCache.removeAll() }
            self.artworkCache[address] = image
            self.show(image, for: item.videoId)
        }
    }

    private func show(_ image: UIImage, for videoId: String) {
        guard shownVideoId == videoId else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        refresh()
    }
}
