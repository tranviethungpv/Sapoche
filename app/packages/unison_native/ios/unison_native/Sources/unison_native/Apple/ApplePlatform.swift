import Foundation
import Network
import UIKit
import UniformTypeIdentifiers

/// What the iPhone offers that the rest of the native side asks for through [PlatformServices].
@MainActor
final class ApplePlatform: NSObject, PlatformServices, UIDocumentPickerDelegate {
    let calm = StateFlow<Bool>(false)

    /// The network changed or came back; [Bool] says whether it is another one than before.
    var onNetwork: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private var metered = true
    private var satisfied = false
    private var interfaces: Set<NWInterface.InterfaceType> = []
    private var picking: CheckedContinuation<URL?, Never>?

    override init() {
        super.init()
        calm.set(readCalm())
        let center = NotificationCenter.default
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateCalm() }
        }
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateCalm() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            let ok = path.status == .satisfied
            let types = Set([NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet].filter { path.usesInterfaceType($0) })
            Task { @MainActor in self?.pathChanged(metered: expensive || !ok, satisfied: ok, interfaces: types) }
        }
        monitor.start(queue: DispatchQueue(label: "unison.network"))
    }

    // ------------------------------------------------------------------ PlatformServices

    var deviceName: String { UIDevice.current.name }

    var deviceModel: String { UIDevice.current.model }

    var isMetered: Bool { metered }

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
        task = UIApplication.shared.beginBackgroundTask(withName: "unison.work") {
            // Time is up: the song being fetched stays on the list as it was
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            task = .invalid
        }
        await work()
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
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
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in
            self.picking?.resume(returning: nil)
            self.picking = nil
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
