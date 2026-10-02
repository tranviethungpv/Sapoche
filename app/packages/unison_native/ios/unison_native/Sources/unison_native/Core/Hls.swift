import Foundation

/// One piece of a DASH file, as its index lists it: where it is in the file and how long it plays.
struct DashSegment: Equatable {
    let offset: Int64
    let size: Int64
    let seconds: Double
}

/// Reads the index of a DASH file, its `sidx` box, which says where each piece of the file is and how long it plays.
/// That is what lets the player fetch a song piece by piece, each piece a short range that YouTube does not throttle.
enum DashIndex {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The pieces listed by the `sidx` box at the start of [data], which was read from byte [start] of the file.
    static func segments(_ data: Data, at start: Int64) throws -> [DashSegment] {
        let bytes = [UInt8](data)
        func number(_ at: Int, _ count: Int) -> UInt64 {
            bytes[at..<at + count].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard bytes.count >= 8 else { throw Failure(message: "The index is cut short") }
        var size = number(0, 4)
        var at = 8
        if size == 1 {
            guard bytes.count >= 16 else { throw Failure(message: "The index is cut short") }
            size = number(8, 8)
            at = 16
        }
        guard String(decoding: bytes[4..<8], as: UTF8.self) == "sidx" else { throw Failure(message: "No index where it should be") }
        guard size <= UInt64(bytes.count), Int(size) >= at + 24 else { throw Failure(message: "The index is cut short") }
        let end = Int(size)

        let version = bytes[at]
        at += 8 // version and flags, reference id
        let timescale = number(at, 4)
        at += 4
        let firstOffset: UInt64
        if version == 0 {
            firstOffset = number(at + 4, 4) // after the earliest presentation time
            at += 8
        } else {
            guard end >= at + 20 else { throw Failure(message: "The index is cut short") }
            firstOffset = number(at + 8, 8)
            at += 16
        }
        let count = Int(number(at + 2, 2)) // after two reserved bytes
        at += 4
        guard timescale > 0, count > 0, at + count * 12 <= end else { throw Failure(message: "The index lists nothing") }

        // Offsets count from the first byte after the index
        var offset = start + Int64(size) + Int64(firstOffset)
        var segments: [DashSegment] = []
        segments.reserveCapacity(count)
        for _ in 0..<count {
            let reference = number(at, 4)
            let duration = number(at + 4, 4)
            // A piece that is itself an index would need another round of reading; YouTube's files have none
            guard reference & 0x8000_0000 == 0 else { throw Failure(message: "The index points to another index") }
            let length = Int64(reference & 0x7FFF_FFFF)
            guard length > 0, duration > 0 else { throw Failure(message: "The index lists an empty piece") }
            segments.append(DashSegment(offset: offset, size: length, seconds: Double(duration) / Double(timescale)))
            offset += length
            at += 12
        }
        return segments
    }
}

/// Writes HLS playlists that play a DASH file from where it is, piece by piece: the player gets the file's header and
/// then each piece as a range of the same address. Apple's player streams HLS best of all, and needs nothing re-encoded.
enum HlsPlaylist {
    /// The playlist of one stream: the file at [url], whose header ends at [initEnd], cut into [segments].
    static func media(url: String, initEnd: Int64, segments: [DashSegment]) -> String {
        let longest = segments.map(\.seconds).max() ?? 1
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(Int(longest.rounded(.up)), 1))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(url)\",BYTERANGE=\"\(initEnd + 1)@0\"",
        ]
        lines.reserveCapacity(lines.count + segments.count * 3 + 1)
        for segment in segments {
            lines.append("#EXTINF:\(String(format: "%.6f", segment.seconds)),")
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)")
            lines.append(url)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The playlist that plays the picture of [video] with the sound of [audio], two playlists of single streams.
    /// [bandwidth] is in bits per second. Codecs are left out when the sound's is not known, rather than told wrong.
    static func master(video: URL, videoCodec: String, audio: URL, audioCodec: String?, bandwidth: Int) -> String {
        let codecs = audioCodec.map { ",CODECS=\"\(videoCodec),\($0)\"" } ?? ""
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",NAME=\"Sound\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audio.absoluteString)\"",
            "#EXT-X-STREAM-INF:BANDWIDTH=\(max(bandwidth, 1))\(codecs),AUDIO=\"sound\"",
            video.absoluteString,
        ].joined(separator: "\n") + "\n"
    }

    /// The codec in a type such as `audio/mp4; codecs="mp4a.40.2"`.
    static func codec(ofType mimeType: String) -> String? {
        guard let start = mimeType.range(of: "codecs=\"") else { return nil }
        let rest = mimeType[start.upperBound...]
        guard let end = rest.firstIndex(of: "\""), end > rest.startIndex else { return nil }
        return String(rest[..<end])
    }
}

/// The playlists handed to the player, by address. Apple's player cannot be given a playlist as text: it asks for it at
/// an address of this scheme, through a resource loader that looks it up here. Only the last few are kept.
final class HlsPlaylists: @unchecked Sendable {
    static let scheme = "unison-hls"
    private static let kept = 16

    private let lock = NSLock()
    private var texts: [String: String] = [:]
    private var order: [String] = []
    private var added = 0

    /// Keeps [text] and gives the address it is asked for by; [name] only helps a person reading the logs.
    func add(_ text: String, name: String) -> URL {
        lock.lock()
        defer { lock.unlock() }
        added += 1
        let key = "\(added)-" + name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        texts[key] = text
        order.append(key)
        while order.count > Self.kept { texts[order.removeFirst()] = nil }
        return URL(string: "\(Self.scheme)://playlist/\(key).m3u8")!
    }

    /// The playlist at [url]; nil when it is not one of these, or was let go.
    func text(for url: URL) -> String? {
        guard url.scheme == Self.scheme else { return nil }
        let key = url.deletingPathExtension().lastPathComponent
        lock.lock()
        defer { lock.unlock() }
        return texts[key]
    }
}
