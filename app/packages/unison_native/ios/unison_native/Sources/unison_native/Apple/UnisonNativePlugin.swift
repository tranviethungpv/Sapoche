import AVFoundation
import Flutter
import UIKit

/// [KeyValueStore] over the app's UserDefaults.
final class UserDefaultsStore: KeyValueStore {
    private let defaults: UserDefaults
    private let prefix = "unison."

    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(_ key: String) -> String? { defaults.string(forKey: prefix + key) }

    func int64(_ key: String) -> Int64? {
        (defaults.object(forKey: prefix + key) as? NSNumber)?.int64Value
    }

    func bool(_ key: String) -> Bool? {
        (defaults.object(forKey: prefix + key) as? NSNumber)?.boolValue
    }

    func set(_ value: String?, for key: String) { defaults.set(value, forKey: prefix + key) }
    func set(_ value: Int64, for key: String) { defaults.set(NSNumber(value: value), forKey: prefix + key) }
    func set(_ value: Bool, for key: String) { defaults.set(NSNumber(value: value), forKey: prefix + key) }
    func remove(_ key: String) { defaults.removeObject(forKey: prefix + key) }
}

/// Everything the native side is made of, built once when the app starts: the player, the room connection, the library,
/// YouTube access and the files. It lives as long as the app, so that music goes on while the screen is gone.
@MainActor
final class UnisonRuntime {
    static let shared = UnisonRuntime()

    let prefs = UserDefaultsStore()
    let platform = ApplePlatform()
    let controller: GroupController
    let bridge: Bridge
    private let engine: AVPlayerEngine
    private let nowPlaying: NowPlaying

    private init() {
        let manager = FileManager.default
        let support = (try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? manager.temporaryDirectory
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? manager.temporaryDirectory
        let prefs = prefs
        let region = Locale.current.regionCode ?? "US"
        let http = URLSessionHTTP()

        let music = MusicClient(region: { region }, http: http)
        let resolver = YouTubeResolver(http: http, music: music, region: region)
        let streams = StreamCache(resolver: resolver)

        let limitMb = prefs.int64("cache_limit_mb") ?? 256
        let files = MediaFiles(downloadsDir: support.appendingPathComponent("downloads", isDirectory: true),
                               playDir: caches.appendingPathComponent("playcache", isDirectory: true),
                               playLimitBytes: limitMb * 1024 * 1024)
        // Downloaded songs are the person's, not something to be backed up to a cloud they did not choose
        var downloadsURL = support.appendingPathComponent("downloads", isDirectory: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try? downloadsURL.setResourceValues(excluded)

        let media = MediaLibrary(files: files, streams: streams, fetcher: URLSessionFetcher(), log: { EventLog.d("media", $0) })
        let lyrics = LyricsStore(dir: caches.appendingPathComponent("lyrics", isDirectory: true))
        let feed = MusicFeed(music: music, lyricsClient: LyricsClient(http: http), lyricsStore: lyrics)

        let store: LibraryStore
        do {
            let language = { prefs.string("language") ?? "en" }
            store = try LibraryStore(
                path: support.appendingPathComponent("library.db").path,
                onChange: { Task { @MainActor in UnisonRuntime.shared.bridge.libraryChanged() } },
                untitled: { language() == "vi" ? "Chưa đặt tên" : "Untitled" }
            )
        } catch {
            // A library that cannot be opened is better replaced than left to crash the app
            EventLog.d("library", "could not open the library: \(error.localizedDescription)")
            store = try! LibraryStore(path: ":memory:")
        }

        let suggestions = SuggestionFeed(store: store, resolver: resolver, music: feed, log: { EventLog.d("suggest", $0) })
        let downloader = Downloader(store: store, fetch: { try await media.download($0) }, log: { EventLog.d("download", $0) })

        let engine = AVPlayerEngine(library: media, maxVideoHeight: { Int(prefs.int64("video_height") ?? 720) }, log: { EventLog.d("player", $0) })
        self.engine = engine
        controller = GroupController(
            engine: engine,
            prefs: prefs,
            queueFile: QueueFile(url: support.appendingPathComponent("local_queue.json")),
            config: { ServerConfig.load(prefs) },
            recordListen: { track in
                Task {
                    do { try await store.recordListen(track) } catch { EventLog.d("library", "could not write the history: \(error.localizedDescription)") }
                }
            },
            recordSkip: { track in
                Task {
                    do { try await store.recordSkip(track) } catch { EventLog.d("library", "could not write the skip: \(error.localizedDescription)") }
                }
            },
            moreLike: { videoId, exclude, count in try await suggestions.after(videoId, exclude: exclude, count: count) }
        )
        bridge = Bridge(controller: controller, prefs: prefs, platform: platform, store: store, resolver: resolver, streams: streams,
                        music: feed, suggestions: suggestions, media: media, files: files, downloader: downloader, http: http)
        nowPlaying = NowPlaying(controller: controller, engine: engine)
    }

    /// Where the picture of a song is drawn for Flutter.
    func attach(textures: FlutterTextureRegistry) {
        engine.textures = textures
    }

    /// Wires what has to be wired once everything exists: the lock screen follows the player, the room follows the network.
    func start() {
        let previous = engine.onChange
        engine.onChange = { [weak self] in
            previous?()
            self?.nowPlaying.refresh()
        }
        controller.view.observe { [weak self] _ in self?.nowPlaying.refresh() }.keep()
        platform.onNetwork = { [weak self] changed in self?.controller.networkChanged(changed: changed) }
        controller.recoverRoom()
    }
}

extension Subscription {
    /// Lets the observation go on for as long as the app runs.
    func keep() {
        UnisonRuntime.keptSubscriptions.append(self)
    }
}

extension UnisonRuntime {
    fileprivate static var keptSubscriptions: [Subscription] = []
}

/// The plugin that opens the channels the Flutter UI talks to the native side through: commands go in on
/// `app.unison/control`, state comes out on `app.unison/state`.
@MainActor
@objc(UnisonNativePlugin)
public final class UnisonNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private nonisolated static let openURL = Notification.Name("app.unison.openURL")
    private nonisolated static let pendingKey = "unison.pendingURL"

    private let runtime = UnisonRuntime.shared
    private var started = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = UnisonNativePlugin()
        let control = FlutterMethodChannel(name: "app.unison/control", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(plugin, channel: control)
        FlutterEventChannel(name: "app.unison/state", binaryMessenger: registrar.messenger()).setStreamHandler(plugin)
        plugin.runtime.attach(textures: registrar.textures())
        plugin.observeLifecycle()
        plugin.start()
    }

    private func start() {
        guard !started else { return }
        started = true
        runtime.start()
    }

    // ------------------------------------------------------------------ commands

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        let method = call.method
        Task { @MainActor in
            do {
                result(try await self.runtime.bridge.handle(method, arguments))
            } catch let error as BridgeError {
                result(FlutterError(code: error.code, message: error.message, details: nil))
            } catch is GroupController.NoRoom {
                result(FlutterError(code: "no_room", message: "Not in a room", details: nil))
            } catch {
                EventLog.d("bridge", "\(method) failed: \(error.localizedDescription)")
                result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
            }
        }
    }

    // ------------------------------------------------------------------ state stream

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        runtime.bridge.start { events($0) }
        // A link that opened the app before the screen was listening
        if let pending = UserDefaults.standard.string(forKey: Self.pendingKey), let url = URL(string: pending) {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            runtime.bridge.onLink(url)
        }
        // The screen is already in front when it starts listening
        if UIApplication.shared.applicationState == .active { runtime.bridge.setVisible(true) }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        runtime.bridge.stop()
        return nil
    }

    // ------------------------------------------------------------------ the app comes and goes

    private func observeLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.runtime.bridge.setVisible(true) }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.runtime.bridge.setVisible(false) }
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in UnisonRuntime.shared.controller.release() }
        }
        // The Runner passes on the links that open the app
        center.addObserver(forName: Self.openURL, object: nil, queue: .main) { [weak self] note in
            guard let url = note.object as? URL else { return }
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            Task { @MainActor in self?.runtime.bridge.onLink(url) }
        }
    }
}
