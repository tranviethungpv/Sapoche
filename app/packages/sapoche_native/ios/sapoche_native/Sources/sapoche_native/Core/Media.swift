import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Brings the file at an address onto the disk.
protocol FileFetcher: Sendable {
    /// Writes the body of [url] to [file] and gives back its size; throws when the answer is not all there. Stops
    /// when the calling task is cancelled.
    func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64

    /// The bytes [range] of [url]; throws when the answer is not a success or not all of them.
    func bytes(_ url: URL, range: ClosedRange<Int64>, headers: [String: String]) async throws -> Data
}

extension FileFetcher {
    /// A fetcher that only brings whole files: a song is then never streamed in pieces, but fetched whole.
    func bytes(_ url: URL, range: ClosedRange<Int64>, headers: [String: String]) async throws -> Data {
        throw URLError(.unsupportedURL)
    }
}

struct URLSessionFetcher: FileFetcher {
    /// YouTube's servers serve a range at full speed only up to about 10 MiB, and throttle a longer one to about
    /// real-time speed: a song is fetched in ranges of this size, one after the other.
    static let chunkBytes: Int64 = 8 * 1024 * 1024

    private let session: URLSession

    init(timeout: TimeInterval = 20, configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    func fetch(_ url: URL, headers: [String: String], to file: URL) async throws -> Int64 {
        let manager = FileManager.default
        try? manager.removeItem(at: file)
        manager.createFile(atPath: file.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var written: Int64 = 0
            while true {
                var request = URLRequest(url: url)
                // Asking for a range is what keeps a plain GET from being throttled
                request.setValue("bytes=\(written)-\(written + Self.chunkBytes - 1)", forHTTPHeaderField: "Range")
                headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                let (data, response) = try await load(request)
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                // A server that sent the whole file whatever was asked has nothing more to give
                if response.statusCode == 200 { return written }
                // A range answer says how long the whole file is; what arrived must be all of it
                guard let total = Self.total(response), !data.isEmpty, written <= total else { throw URLError(.networkConnectionLost) }
                if written == total { return written }
            }
        } catch {
            try? manager.removeItem(at: file)
            throw error
        }
    }

    func bytes(_ url: URL, range: ClosedRange<Int64>, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await load(request)
        guard response.statusCode == 206, data.count == range.count else { throw URLError(.networkConnectionLost) }
        return data
    }

    /// One answer; throws when it is not a success. Stops when the calling task is cancelled.
    private func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response = response as? HTTPURLResponse else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    guard response.statusCode == 200 || response.statusCode == 206 else {
                        continuation.resume(throwing: HTTPFailure(status: response.statusCode, service: "YouTube"))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// The length of the whole file, from "Content-Range: bytes 0-3449446/3449447".
    private static func total(_ response: HTTPURLResponse) -> Int64? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") else { return nil }
        return Int64(range[range.index(after: slash)...])
    }
}

/// Holds the task of a transfer so that cancelling the caller can reach it.
final class TaskBox: @unchecked Sendable {
    private var task: URLSessionTask?
    private var cancelled = false
    private let lock = NSLock()

    func set(_ new: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        task = new
        if cancelled { new.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

/// The songs kept on disk, in two places under the same name, the video id:
/// - downloads: songs the person chose to keep. Nothing ever removes them but the person.
/// - play: what was played, so hearing it again costs no data. The oldest goes first once it is full.
/// A song is one whole file; a file is only given a name once all of it is there.
final class MediaFiles: @unchecked Sendable {
    private let downloadsDir: URL
    private let playDir: URL
    private let lock = NSLock()
    private var playLimitBytes: Int64

    init(downloadsDir: URL, playDir: URL, playLimitBytes: Int64) {
        self.downloadsDir = downloadsDir
        self.playDir = playDir
        self.playLimitBytes = playLimitBytes
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: playDir, withIntermediateDirectories: true)
        // Half-written files from a run that was cut short are of no use
        for dir in [downloadsDir, playDir] {
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "part" || file.pathExtension == "remux" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func setPlayLimit(_ bytes: Int64) {
        lock.lock()
        playLimitBytes = bytes
        lock.unlock()
        trimPlay()
    }

    /// The file of [videoId], from the downloads if it is there, else from what was played; nil when neither has it.
    func file(_ videoId: String) -> URL? {
        let download = downloaded(videoId)
        if FileManager.default.fileExists(atPath: download.path) { return download }
        let played = played(videoId)
        guard FileManager.default.fileExists(atPath: played.path) else { return nil }
        // Used just now, so it is the last to go
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: played.path)
        return played
    }

    func isDownloaded(_ videoId: String) -> Bool { FileManager.default.fileExists(atPath: downloaded(videoId).path) }

    func downloaded(_ videoId: String) -> URL { downloadsDir.appendingPathComponent(Self.name(videoId) + ".m4a") }

    func played(_ videoId: String) -> URL { playDir.appendingPathComponent(Self.name(videoId) + ".m4a") }

    /// Where a file is written while it is not all there yet.
    func part(_ videoId: String, download: Bool) -> URL {
        (download ? downloadsDir : playDir).appendingPathComponent(Self.name(videoId) + ".part")
    }

    /// Gives the finished [part] its name; for the downloads, what was played of it is thrown away.
    func finish(_ videoId: String, download: Bool) throws {
        let part = part(videoId, download: download)
        let target = download ? downloaded(videoId) : played(videoId)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
        if download {
            try? FileManager.default.removeItem(at: played(videoId))
        } else {
            trimPlay()
        }
    }

    /// Moves what was played into the downloads, so that it need not be fetched again.
    @discardableResult
    func keepPlayed(_ videoId: String) -> Bool {
        let played = played(videoId)
        guard FileManager.default.fileExists(atPath: played.path) else { return false }
        let target = downloaded(videoId)
        try? FileManager.default.removeItem(at: target)
        return (try? FileManager.default.moveItem(at: played, to: target)) != nil
    }

    func removeDownload(_ videoId: String) {
        try? FileManager.default.removeItem(at: downloaded(videoId))
    }

    func clearDownloads() { empty(downloadsDir) }

    func clearPlay() { empty(playDir) }

    func downloadBytes() -> Int64 { size(of: downloadsDir) }

    func playBytes() -> Int64 { size(of: playDir) }

    func size(ofDownload videoId: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: downloaded(videoId).path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Lets the oldest played songs go until what is left fits the limit.
    func trimPlay() {
        lock.lock()
        let limit = playLimitBytes
        lock.unlock()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: playDir, includingPropertiesForKeys: keys) else { return }
        var entries = files.filter { $0.pathExtension == "m4a" }.map { file -> (URL, Date, Int64) in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (file, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0))
        }.sorted { $0.1 < $1.1 }
        var total = entries.reduce(0) { $0 + $1.2 }
        while total > limit, !entries.isEmpty {
            let oldest = entries.removeFirst()
            try? FileManager.default.removeItem(at: oldest.0)
            total -= oldest.2
        }
    }

    private func size(of dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "m4a" }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func empty(_ dir: URL) {
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // A video id has only letters, digits, - and _, but nothing is written with a name that came from outside unchecked
    private static func name(_ videoId: String) -> String {
        String(videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}

/// Resolves video ids to stream addresses and keeps them for a while. A stream address expires after about six hours.
actor StreamCache {
    struct Pick: Equatable {
        let url: String
        let itag: Int
        let contentLength: Int64
        let userAgent: String
        let track: TrackInfo
        let mimeType: String
        let bitrateKbps: Int
        let index: DashRanges?
    }

    private struct Entry {
        let resolved: Resolved
        let at: Date
    }

    private static let maxAge: TimeInterval = 4 * 60 * 60

    private let resolver: StreamResolver
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<Resolved, Error>] = [:]

    init(resolver: StreamResolver) {
        self.resolver = resolver
    }

    /// The best audio stream of [videoId], resolving if needed. One resolve per video at a time, so a preload and a play
    /// do not race. When it is longer than [limit] bytes, the best one that fits is taken, or the smallest if none does.
    func audio(_ videoId: String, within limit: Int64 = .max) async throws -> Pick {
        let resolved = try await resolved(videoId)
        let best = resolved.best.contentLength <= limit ? resolved.best
            : resolved.all.first { $0.contentLength <= limit } ?? resolved.all.last ?? resolved.best
        return Pick(url: best.url, itag: best.itag, contentLength: best.contentLength, userAgent: resolved.userAgent, track: resolved.track,
                    mimeType: best.mimeType, bitrateKbps: best.bitrateKbps, index: best.index)
    }

    /// The picture-only stream of [videoId] that fits [maxHeight], or nil when the video has none that an iPhone plays.
    func video(_ videoId: String, maxHeight: Int) async throws -> (source: VideoSource, userAgent: String)? {
        let resolved = try await resolved(videoId)
        guard let pick = VideoPicker.pick(resolved.videos, maxHeight: maxHeight) else { return nil }
        return (pick, resolved.userAgent)
    }

    /// What is known about the song: its title, artist, picture and length, from the same resolve as its stream.
    func track(_ videoId: String) async throws -> TrackInfo {
        try await resolved(videoId).track
    }

    /// Drops the kept address so the next [audio] resolves again.
    func invalidate(_ videoId: String) {
        entries[videoId] = nil
    }

    private func resolved(_ videoId: String) async throws -> Resolved {
        if let entry = entries[videoId], Date().timeIntervalSince(entry.at) < Self.maxAge { return entry.resolved }
        if let running = pending[videoId] { return try await running.value }
        let task = Task { try await resolver.resolve(videoId) }
        pending[videoId] = task
        defer { pending[videoId] = nil }
        let found = try await task.value
        entries[videoId] = Entry(resolved: found, at: Date())
        return found
    }
}

/// Where a song comes from when it is played or kept: a file on the disk, a playlist of the stream's pieces (see
/// [HlsPlaylist]), or the stream itself when neither works out.
struct Playable: Equatable {
    let url: URL
    let isFile: Bool
    let headers: [String: String]

    /// Whether this is a playlist kept in [HlsPlaylists], which the player reads through a resource loader.
    var isPlaylist: Bool { url.scheme == HlsPlaylists.scheme }
}

/// Brings songs onto the disk, as whole files, and tells where a song can be played from. A song that was played or
/// downloaded before is there already, and then nothing is fetched. A song that is not there can be played at once
/// from its stream, piece by piece, and a song too long to be worth keeping is only ever played that way.
actor MediaLibrary {
    /// A song longer than this is played from its stream in pieces, and not kept on the disk.
    static let keepLimitBytes: Int64 = 20 * 1024 * 1024
    /// When a song cannot be played in pieces: a song longer than this is fetched in a lower quality when it has one,
    /// so that it starts sooner.
    static let wholeLimitBytes: Int64 = 40 * 1024 * 1024
    /// When a song cannot be played in pieces: a song longer than this, in its lowest quality, is played from the
    /// stream, not fetched whole first.
    static let streamAboveBytes: Int64 = 256 * 1024 * 1024
    private static let attempts = 3

    /// The playlists of songs played in pieces, for the player to read.
    nonisolated let playlists = HlsPlaylists()

    private let files: MediaFiles
    private let streams: StreamCache
    private let fetcher: FileFetcher
    private let log: @Sendable (String) -> Void

    /// A transfer that is going on, and how many are waiting for it.
    private struct Transfer {
        let task: Task<Int64, Error>
        var waiters: Int
    }

    private var running: [String: Transfer] = [:]

    init(files: MediaFiles, streams: StreamCache, fetcher: FileFetcher, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.files = files
        self.streams = streams
        self.fetcher = fetcher
        self.log = log
    }

    /// Where to play [videoId] from with the least wait: its file when it is on the disk, else its stream in pieces, so
    /// that it starts once the first piece is there. When the stream cannot be laid out in pieces, as [playable].
    func playableAtOnce(_ videoId: String) async throws -> Playable {
        if let file = files.file(videoId) { return Playable(url: ordinary(file), isFile: true, headers: [:]) }
        if let pieces = try await inPieces(videoId) { return pieces }
        return try await playable(videoId, piecesWhenLong: false)
    }

    /// Where to play [videoId] from, fetching it first when it is not on the disk; the stream when it cannot be fetched.
    /// A song too long to keep is played from its stream in pieces instead, when [piecesWhenLong] and that works out.
    func playable(_ videoId: String, piecesWhenLong: Bool = true) async throws -> Playable {
        if let file = files.file(videoId) { return Playable(url: ordinary(file), isFile: true, headers: [:]) }
        if piecesWhenLong, let pick = try? await streams.audio(videoId), pick.contentLength > Self.keepLimitBytes,
           let pieces = try await inPieces(videoId) {
            return pieces
        }
        var problem: Error = ResolveFailure(message: "No stream for \(videoId)")
        for attempt in 1...Self.attempts {
            do {
                let pick = try await streams.audio(videoId, within: Self.wholeLimitBytes)
                guard let url = URL(string: pick.url) else { throw URLError(.badURL) }
                if pick.contentLength > Self.streamAboveBytes {
                    log("\(videoId) is \(pick.contentLength / 1_048_576) MB, played from the stream")
                    return Playable(url: url, isFile: false, headers: ["User-Agent": pick.userAgent])
                }
                _ = try await fetch(videoId, pick, download: false)
                if let file = files.file(videoId) { return Playable(url: file, isFile: true, headers: [:]) }
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as LoadFailure {
                // No network, or a video YouTube will not play: no other try or way of playing it will do better
                throw failure
            } catch {
                // A transfer that was stopped because nobody wants the song any more is not a failure to try again
                if Task.isCancelled { throw CancellationError() }
                problem = error
                log("\(videoId) attempt \(attempt) failed: \(error.localizedDescription)")
                // Often a stream address that stopped working: resolve again
                await streams.invalidate(videoId)
            }
        }
        // Nothing could be brought onto the disk: the player may still manage to read the stream itself
        if let stream = try? await streamed(videoId) {
            log("\(videoId) could not be fetched (\(problem.localizedDescription)), played from the stream")
            return stream
        }
        throw problem
    }

    /// Where [videoId] is streamed from, without a file; the way out when a file will not play.
    func streamed(_ videoId: String) async throws -> Playable {
        let pick = try await streams.audio(videoId)
        guard let url = URL(string: pick.url) else { throw URLError(.badURL) }
        return Playable(url: url, isFile: false, headers: ["User-Agent": pick.userAgent])
    }

    /// Throws away the file of [videoId] that was played, so that the next play fetches it again. A downloaded file stays.
    func forget(_ videoId: String) async {
        try? FileManager.default.removeItem(at: files.played(videoId))
        await streams.invalidate(videoId)
    }

    /// Drops the address [videoId] was streamed from, so that the next load resolves it again: an address that stopped
    /// working in the middle of a song (expired, or tied to a network the phone has left) does not mend by being retried.
    func refresh(_ videoId: String) async {
        await streams.invalidate(videoId)
    }

    /// Where the picture of [videoId] is streamed from, at most [maxHeight] tall; nil when it has none that plays.
    func video(_ videoId: String, maxHeight: Int) async throws -> Playable? {
        guard let pick = try await streams.video(videoId, maxHeight: maxHeight), let url = URL(string: pick.source.url) else { return nil }
        return Playable(url: url, isFile: false, headers: ["User-Agent": pick.userAgent])
    }

    /// The sound of [videoId] with its picture, at most [maxHeight] tall, both played from their streams in pieces: one
    /// playlist of the two. Nil when the video has no picture an iPhone plays or the picture has no index; throws
    /// when the pieces cannot be laid out.
    func pictured(_ videoId: String, maxHeight: Int) async throws -> Playable? {
        guard let picture = try await streams.video(videoId, maxHeight: maxHeight), let index = picture.source.index,
              let pictureURL = URL(string: picture.source.url) else { return nil }
        let sound = try await soundInPieces(videoId)
        let segments = try await pieces(pictureURL, index, contentLength: picture.source.contentLength, userAgent: picture.userAgent)
        let pictureList = playlists.add(HlsPlaylist.media(url: picture.source.url, initEnd: index.initEnd, segments: segments), name: videoId + "-picture")
        let master = HlsPlaylist.master(
            video: pictureList, videoCodec: picture.source.codec, audio: sound.url,
            audioCodec: HlsPlaylist.codec(ofType: sound.pick.mimeType), bandwidth: (picture.source.bitrateKbps + sound.pick.bitrateKbps) * 1000
        )
        return Playable(url: playlists.add(master, name: videoId + "-both"), isFile: false, headers: ["User-Agent": picture.userAgent])
    }

    /// Brings [videoId] onto the disk for next time while it plays from its stream, when it is short enough to keep.
    /// Stops when the calling task is cancelled.
    func keep(_ videoId: String) async {
        guard files.file(videoId) == nil else { return }
        do {
            let pick = try await streams.audio(videoId)
            guard pick.contentLength > 0, pick.contentLength <= Self.keepLimitBytes else { return }
            _ = try await fetch(videoId, pick, download: false)
        } catch {
            if !Task.isCancelled { log("\(videoId) could not be kept: \(error.localizedDescription)") }
        }
    }

    /// The stream of [videoId] as a playlist of its pieces, or nil when it cannot be laid out that way: no index, an
    /// index that does not add up, or one that could not be read twice, the second time with a fresh address.
    private func inPieces(_ videoId: String) async throws -> Playable? {
        for attempt in 1...2 {
            do {
                let sound = try await soundInPieces(videoId)
                return Playable(url: sound.url, isFile: false, headers: ["User-Agent": sound.pick.userAgent])
            } catch is NoIndex {
                return nil
            } catch let failure as LoadFailure {
                throw failure
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                log("\(videoId) could not be laid out in pieces (attempt \(attempt)): \(error.localizedDescription)")
                await streams.invalidate(videoId)
            }
        }
        return nil
    }

    /// The stream does not say where its pieces are.
    private struct NoIndex: Error {}

    /// The playlist of the best sound of [videoId], and the stream it was made from.
    private func soundInPieces(_ videoId: String) async throws -> (url: URL, pick: StreamCache.Pick) {
        let pick = try await streams.audio(videoId)
        guard let index = pick.index, let url = URL(string: pick.url) else { throw NoIndex() }
        let segments = try await pieces(url, index, contentLength: pick.contentLength, userAgent: pick.userAgent)
        let list = playlists.add(HlsPlaylist.media(url: pick.url, initEnd: index.initEnd, segments: segments), name: videoId + "-sound")
        return (list, pick)
    }

    /// The pieces of the file at [url], read from its index. They must follow the index without a gap and end where
    /// the file ends, or the index is not what it seems.
    private func pieces(_ url: URL, _ index: DashRanges, contentLength: Int64, userAgent: String) async throws -> [DashSegment] {
        let data = try await fetcher.bytes(url, range: index.indexStart...index.indexEnd, headers: ["User-Agent": userAgent])
        let segments = try DashIndex.segments(data, at: index.indexStart)
        guard let first = segments.first, let last = segments.last, first.offset == index.indexEnd + 1,
              contentLength <= 0 || last.offset + last.size == contentLength else {
            throw DashIndex.Failure(message: "The index does not match the file")
        }
        return segments
    }

    /// Brings the whole of [videoId] into the downloads and gives back its size; throws when that does not work. What
    /// was only played is moved there instead of being fetched again.
    func download(_ videoId: String) async throws -> Int64 {
        if files.isDownloaded(videoId) { return files.size(ofDownload: videoId) }
        if files.keepPlayed(videoId) { return files.size(ofDownload: videoId) }
        var problem: Error = ResolveFailure(message: "No stream for \(videoId)")
        for _ in 1...Self.attempts {
            do {
                let pick = try await streams.audio(videoId)
                return try await fetch(videoId, pick, download: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as LoadFailure {
                throw failure
            } catch {
                if Task.isCancelled { throw CancellationError() }
                problem = error
                await streams.invalidate(videoId)
            }
        }
        throw problem
    }

    private func fetch(_ videoId: String, _ pick: StreamCache.Pick, download: Bool) async throws -> Int64 {
        // Playing and downloading the same song at once share one transfer, and it stops when nobody waits for it any more
        let key = videoId + (download ? "#d" : "#p")
        if let other = running[videoId + (download ? "#p" : "#d")] { _ = try? await other.task.value }
        let task: Task<Int64, Error>
        if let shared = running[key] {
            running[key]?.waiters += 1
            task = shared.task
        } else {
            let files = files
            let fetcher = fetcher
            task = Task { () -> Int64 in
                defer { self.running[key] = nil }
                guard let url = URL(string: pick.url) else { throw URLError(.badURL) }
                let part = files.part(videoId, download: download)
                let size = try await fetcher.fetch(url, headers: ["User-Agent": pick.userAgent], to: part)
                if pick.contentLength > 0 && size != pick.contentLength {
                    try? FileManager.default.removeItem(at: part)
                    throw URLError(.networkConnectionLost)
                }
                Self.makeOrdinary(part, log: self.log)
                try files.finish(videoId, download: download)
                return size
            }
            running[key] = Transfer(task: task, waiters: 1)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            Task { await self.waiterLeft(key, task) }
        }
    }

    /// Songs that were kept by an earlier version are in fragments, as YouTube sends them.
    private func ordinary(_ file: URL) -> URL {
        Self.makeOrdinary(file, log: log)
        return file
    }

    /// YouTube sends a song in fragments, which Apple's player is not reliable with; the file is written again as an
    /// ordinary MP4. A file that cannot be converted is kept as it is, and left to the player.
    private static func makeOrdinary(_ file: URL, log: @Sendable (String) -> Void) {
        do {
            if try Mp4Remux.makeProgressive(file) { log("\(file.lastPathComponent) rewritten as an ordinary MP4") }
        } catch {
            log("\(file.lastPathComponent) could not be rewritten: \(error.localizedDescription)")
        }
    }

    /// One of those waiting for a transfer gave up; with nobody left the transfer is stopped.
    private func waiterLeft(_ key: String, _ task: Task<Int64, Error>) {
        guard var transfer = running[key], transfer.task == task else { return }
        transfer.waiters -= 1
        running[key] = transfer
        if transfer.waiters <= 0 { task.cancel() }
    }
}
