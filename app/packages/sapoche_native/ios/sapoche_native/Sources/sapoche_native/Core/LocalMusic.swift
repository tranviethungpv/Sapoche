import Foundation

/// A music file on this phone, as the scan reports it. [key] says where it is, and does not change while it stays there.
struct LocalFile: Equatable {
    let key: String
    let uri: String
    let title: String
    let artist: String
    let album: String
    let durMs: Int64
    let mime: String
    let size: Int64
    let addedAt: Int64
}

/// A music file the library already knows, with whether anything (a like, a playlist, a listen) points to its song.
struct KnownLocal: Equatable {
    let id: String
    let key: String
    let title: String
    let artist: String
    let durMs: Int64
    let referenced: Bool
}

/// What a scan changes: [files] are written under their ids, [missing] are kept but marked as gone, [forget] are dropped.
struct LocalPlan: Equatable {
    struct Placed: Equatable {
        let id: String
        let file: LocalFile
    }

    let files: [Placed]
    let missing: [String]
    let forget: [String]
}

/// Songs from the music files on this phone. They mirror `LocalMusic.kt`.
enum LocalMusic {
    static let prefix = "local:"

    /// Where the picture of a local song is asked for: `thumb` of a song that has a file on this phone.
    static let coverPrefix = "sapoche-local:"

    /// A song shorter than this is not music (a voice message, a ringtone): the same length that counts a song as heard.
    static let minMs: Int64 = 30_000

    /// Two lengths this far apart still are the same song.
    static let sameLengthMs: Int64 = 2_000

    static func isLocal(_ videoId: String) -> Bool { videoId.hasPrefix(prefix) }

    static func cover(_ videoId: String) -> String { coverPrefix + videoId }

    /// The id of a song for the file at [key]: `local:` and 16 hexadecimal digits (FNV-1a, 64 bits). The colon is why it can
    /// never be the id of a YouTube video, and why a room, whose server wants those, never takes it. [attempt] > 0 makes
    /// another id for the same key, for the rare file whose first id is taken.
    static func id(_ key: String, attempt: Int = 0) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // the FNV offset basis
        for byte in (attempt == 0 ? key : "\(key)#\(attempt)").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return prefix + String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Works out what to do with what a scan [found] given what is [known]. A file is known by where it is; a new one that
    /// is the only one that looks like the single file that went missing (same title and artist, almost the same length) is
    /// that file, moved, and takes its song over so likes and playlists stay; with several candidates nothing is joined.
    static func plan(found: [LocalFile], known: [KnownLocal]) -> LocalPlan {
        let byKey = Dictionary(known.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var unmatched: [LocalFile] = []
        var files: [LocalPlan.Placed] = []
        for file in found {
            if let existing = byKey[file.key] {
                if seen.insert(existing.id).inserted { files.append(.init(id: existing.id, file: file)) }
            } else {
                unmatched.append(file)
            }
        }
        var gone = known.filter { !seen.contains($0.id) }
        var taken = Set(known.map(\.id))
        for file in unmatched {
            let twins = gone.filter { same($0, file) }
            if twins.count == 1, let twin = twins.first, unmatched.filter({ same(twin, $0) }).count == 1 {
                gone.removeAll { $0.id == twin.id }
                seen.insert(twin.id)
                files.append(.init(id: twin.id, file: file))
                continue
            }
            var attempt = 0
            var id = Self.id(file.key)
            while taken.contains(id) {
                attempt += 1
                id = Self.id(file.key, attempt: attempt)
            }
            taken.insert(id)
            files.append(.init(id: id, file: file))
        }
        return LocalPlan(
            files: files,
            missing: gone.filter(\.referenced).map(\.id),
            forget: gone.filter { !$0.referenced }.map(\.id)
        )
    }

    private static func same(_ known: KnownLocal, _ file: LocalFile) -> Bool {
        norm(known.title) == norm(file.title) && norm(known.artist) == norm(file.artist)
            && abs(known.durMs - file.durMs) <= sameLengthMs
    }

    private static func norm(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
