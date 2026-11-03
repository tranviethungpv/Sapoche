import AVFoundation
import AVKit
import Foundation
import MediaPlayer
import Network
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// What the iPhone offers that the rest of the native side asks for through [PlatformServices].
@MainActor
final class ApplePlatform: NSObject, PlatformServices, UIDocumentPickerDelegate, UNUserNotificationCenterDelegate {
    let calm = StateFlow<Bool>(false)
    let output = StateFlow<AudioOutput>(AudioOutput(kind: "speaker", name: ""))
    let volume = StateFlow<Float>(AVAudioSession.sharedInstance().outputVolume)

    /// The network changed or came back; [Bool] says whether it is another one than before.
    var onNetwork: ((Bool) -> Void)?

    /// The person touched the notification of the chat of a room, given by its code.
    var onOpenChat: ((String) -> Void)?

    private let monitor = NWPathMonitor()
    private var metered = true
    private var satisfied = false
    private var interfaces: Set<NWInterface.InterfaceType> = []
    private var picking: CheckedContinuation<URL?, Never>?
    private var pickingMany: CheckedContinuation<[URL], Never>?

    /// The system's own button for choosing where to play to, kept out of sight: it is pressed by [pickOutput], for the
    /// system draws the list of places and nothing else can.
    private lazy var routePicker: AVRoutePickerView = {
        let view = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        return view
    }()

    /// The system's own volume slider, kept out of sight: a program may only move the volume of the phone through it.
    private lazy var volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        view.alpha = 0.01
        return view
    }()

    /// Watches the volume of the phone, buttons included.
    private var volumeObservation: NSKeyValueObservation?

    override init() {
        super.init()
        calm.set(readCalm())
        // The session has to be active for its volume to be read and to move
        try? AVAudioSession.sharedInstance().setActive(true)
        volume.set(AVAudioSession.sharedInstance().outputVolume)
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let level = change.newValue else { return }
            Task { @MainActor in self?.volume.set(level) }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateCalm() }
        }
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateCalm() }
        }
        output.set(readOutput())
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.output.set(self.readOutput())
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            let ok = path.status == .satisfied
            let types = Set([NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet].filter { path.usesInterfaceType($0) })
            Task { @MainActor in self?.pathChanged(metered: expensive || !ok, satisfied: ok, interfaces: types) }
        }
        monitor.start(queue: DispatchQueue(label: "sapoche.network"))
        UNUserNotificationCenter.current().delegate = self
    }

    // ------------------------------------------------------------------ PlatformServices

    var deviceModel: String { UIDevice.current.model }

    var isMetered: Bool { metered }

    // ------------------------------------------------------------------ notifications of the chat

    func noticePermission() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        default: return "undecided"
        }
    }

    func askForNotices() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func showNotice(room: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // The notices of one room are kept together in the list of notifications
        content.threadIdentifier = room
        content.userInfo = ["room": room]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func clearNotices() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let room = response.notification.request.content.userInfo["room"] as? String else { return }
        await MainActor.run { self.onOpenChat?(room) }
    }

    func share(_ text: String) {
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        present(sheet)
    }

    func exportFile(name: String, contents: String) async throws -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = self
        let chosen = await pick(picker)
        try? FileManager.default.removeItem(at: file)
        return chosen != nil
    }

    func importFile() async throws -> String? {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .data])
        picker.delegate = self
        guard let url = await pick(picker) else { return nil }
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func whileInBackground(_ work: @escaping () async -> Void) async {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "sapoche.work") {
            // Time is up: the song being fetched stays on the list as it was
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            task = .invalid
        }
        await work()
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    // ------------------------------------------------------------------ music on this phone

    /// The folder of the app that the Files app shows as On My iPhone › Sapoche (the app lists it in its Info.plist).
    var musicFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    func musicTags(_ url: URL) async -> MusicTags? {
        let asset = AVURLAsset(url: url)
        do {
            let (playable, duration, metadata) = try await asset.load(.isPlayable, .duration, .commonMetadata)
            // A file that does not play (a damaged one, one with copy protection) is not offered
            guard playable, duration.isNumeric, !duration.isIndefinite else { return nil }
            func text(_ identifier: AVMetadataIdentifier) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first else { return nil }
                return try? await item.load(.stringValue)
            }
            return MusicTags(
                title: await text(.commonIdentifierTitle),
                artist: await text(.commonIdentifierArtist),
                album: await text(.commonIdentifierAlbumName),
                durMs: Int64(CMTimeGetSeconds(duration) * 1000)
            )
        } catch {
            return nil
        }
    }

    func musicCover(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first else { return nil }
        return try? await item.load(.dataValue)
    }

    func pickMusicFiles() async throws -> [URL] {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        pickingMany?.resume(returning: [])
        return await withCheckedContinuation { continuation in
            pickingMany = continuation
            present(picker)
        }
    }

    // ------------------------------------------------------------------ videos for the chat

    /// What an export preset is: its short side and about the bits a second it makes (the presets give no way to ask), from
    /// the best to the least. The first that should fit is tried; one that did not fit gives way to the next.
    /// Soft on purpose: a chat video is watched on a phone for a few seconds, so nothing above 480p.
    private static let videoSteps: [(preset: String, shortSide: Int, bps: Double)] = [
        (AVAssetExportPreset640x480, 480, 1_000_000),
        (AVAssetExportPresetMediumQuality, 360, 600_000),
        (AVAssetExportPresetLowQuality, 240, 250_000),
    ]

    func prepareVideo(path: String, maxBytes: Int) async throws -> PreparedVideo {
        let unreadable = BridgeError(code: "video_unreadable", message: "Cannot read the video")
        let source = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let length = try? await asset.load(.duration), length.seconds > 0, length.seconds.isFinite,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { throw unreadable }
        let shown = natural.applying(transform)
        let width = Int(abs(shown.width)), height = Int(abs(shown.height))
        guard width > 0, height > 0 else { throw unreadable }
        let seconds = length.seconds

        // A frame a little way in (the first is often black), at most 480 px on its longer side
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let at = NSValue(time: CMTime(seconds: min(1, seconds / 10), preferredTimescale: 600))
        // (The version of this that waits is for iOS 16 and later; the app takes 15)
        let frame: CGImage? = await withCheckedContinuation { done in
            generator.generateCGImagesAsynchronously(forTimes: [at]) { _, image, _, _, _ in done.resume(returning: image) }
        }
        guard let frame, let poster = UIImage(cgImage: frame).jpegData(compressionQuality: 0.75) else { throw unreadable }

        let budget = Double(maxBytes) * 0.93
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mp4")
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? Int.max

        // Already an MP4 or MOV of H.264 that is light (1.5 MB) and no bigger than 480p: nothing is gained by squeezing it again
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let isH264 = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }
        if isH264, ["mp4", "m4v", "mov"].contains(source.pathExtension.lowercased()), size <= 1_500_000,
           min(width, height) <= 480 {
            try FileManager.default.copyItem(at: source, to: out)
            return PreparedVideo(path: out.path, w: width, h: height, durMs: Int(seconds * 1000), poster: poster)
        }

        // Start with the best step that should fit, and go down while it does not
        let start = Self.videoSteps.firstIndex { $0.bps * seconds / 8 <= budget && ($0.shortSide <= min(width, height) || $0.shortSide == 240) }
            ?? Self.videoSteps.count - 1
        for step in Self.videoSteps[start...] {
            try? FileManager.default.removeItem(at: out)
            guard let session = AVAssetExportSession(asset: asset, presetName: step.preset) else { continue }
            session.outputURL = out
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { done.resume() }
            }
            guard session.status == .completed else { continue }
            let made = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? Int.max
            guard made <= maxBytes else { continue }
            // The presets scale to their own size and keep the shape
            let scale = min(1, Double(step.shortSide) / Double(min(width, height)))
            func even(_ v: Double) -> Int { (Int(v) + 1) / 2 * 2 }
            return PreparedVideo(path: out.path, w: even(Double(width) * scale), h: even(Double(height) * scale),
                                 durMs: Int(seconds * 1000), poster: poster)
        }
        try? FileManager.default.removeItem(at: out)
        throw BridgeError(code: "video_too_big", message: "The video is too long to fit")
    }

    // ------------------------------------------------------------------ the clipboard

    /// The pictures of a clip are many at most, and no more than the chat has room for in a message.
    private static let clipboardMax = 10

    /// What the app reads as it is; a GIF that moves must not be touched. The rest is turned into a picture it reads.
    private static let kept: [UTType] = [.gif, .png, .jpeg, .webP, .bmp]

    var clipboardHasPhotos: Bool { UIPasteboard.general.hasImages }

    func clipboardPhotos() -> [ClipboardPhoto] {
        let board = UIPasteboard.general
        guard board.hasImages else { return [] }
        var found: [ClipboardPhoto] = []
        for item in board.items {
            // The kinds a copied picture comes in; the one the app reads as it is comes first
            let types = item.keys.compactMap { key in UTType(key).map { (key, $0) } }.filter { $0.1.conforms(to: .image) }
            guard let (key, type) = types.first(where: { pair in Self.kept.contains { pair.1.conforms(to: $0) } }) ?? types.first
            else { continue }
            let bytes: Data?
            switch item[key] {
            case let data as Data where Self.kept.contains(where: { type.conforms(to: $0) }):
                bytes = data
            case let data as Data:
                bytes = Self.converted(UIImage(data: data))
            case let image as UIImage:
                bytes = Self.converted(image)
            default:
                bytes = nil
            }
            guard let bytes, !bytes.isEmpty else { continue }
            found.append(ClipboardPhoto(name: "pasted-\(found.count + 1).\(type.preferredFilenameExtension ?? "img")", bytes: bytes))
            if found.count >= Self.clipboardMax { break }
        }
        return found
    }

    /// [image] as a PNG where it has see-through places, a JPEG where it has none; nil when there is no picture.
    private static func converted(_ image: UIImage?) -> Data? {
        guard let image, let cg = image.cgImage else { return nil }
        let alpha = cg.alphaInfo
        let seeThrough = alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
        return seeThrough ? image.pngData() : image.jpegData(compressionQuality: 0.95)
    }

    // ------------------------------------------------------------------ where the sound goes

    func setVolume(_ level: Float) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }
        if volumeView.superview !== window { window.addSubview(volumeView) }
        let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        slider?.value = min(max(level, 0), 1)
        volume.set(slider?.value ?? level)
    }

    func pickOutput() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }
        if routePicker.superview !== window { window.addSubview(routePicker) }
        routePicker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
    }

    private func readOutput() -> AudioOutput {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return AudioOutput(kind: "speaker", name: "")
        }
        let kind: String
        switch port.portType {
        case .headphones: kind = "headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: kind = "bluetooth"
        case .airPlay: kind = "airplay"
        case .carAudio: kind = "car"
        case .builtInSpeaker, .builtInReceiver: kind = "speaker"
        default: kind = "other"
        }
        return AudioOutput(kind: kind, name: kind == "speaker" ? "" : port.portName)
    }

    // ------------------------------------------------------------------ warm or saving power

    private func readCalm() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func updateCalm() {
        let now = readCalm()
        if now != calm.value { EventLog.d("heat", now ? "calm: warm or saving power" : "calm over") }
        calm.set(now)
    }

    // ------------------------------------------------------------------ network

    private func pathChanged(metered newMetered: Bool, satisfied newSatisfied: Bool, interfaces newInterfaces: Set<NWInterface.InterfaceType>) {
        let changed = !interfaces.isEmpty && newSatisfied && newInterfaces != interfaces
        let cameBack = newSatisfied && !satisfied
        metered = newMetered
        satisfied = newSatisfied
        if newSatisfied { interfaces = newInterfaces }
        if changed || cameBack { onNetwork?(changed) }
    }

    // ------------------------------------------------------------------ pickers

    /// Shows a picker and waits for the person to choose or back out.
    private func pick(_ picker: UIDocumentPickerViewController) async -> URL? {
        picking?.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            picking = continuation
            present(picker)
        }
    }

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task { @MainActor in
            self.picking?.resume(returning: urls.first)
            self.picking = nil
            self.pickingMany?.resume(returning: urls)
            self.pickingMany = nil
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in
            self.picking?.resume(returning: nil)
            self.picking = nil
            self.pickingMany?.resume(returning: [])
            self.pickingMany = nil
        }
    }

    private func present(_ controller: UIViewController) {
        guard var top = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        // On an iPad a sheet needs a place to point at
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(controller, animated: true)
    }
}
