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

    var deviceName: String { UIDevice.current.name }

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
