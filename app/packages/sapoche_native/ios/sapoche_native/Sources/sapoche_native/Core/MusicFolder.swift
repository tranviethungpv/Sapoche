import Foundation

/// What the tags inside a music file say; [durMs] is its length.
struct MusicTags: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var durMs: Int64
}

/// The music on an iPhone is in the folder of the app, the one the Files app shows as On My iPhone › Sapoche: a phone has
/// no list of music files to ask for, so the person copies their music in, or has it copied by [copyIn]. This lists what
/// is there. Reading the tags needs the system, so [readTags] is given: nil says the file is not music, or cannot be read.
struct MusicFolder {
    /// What an iPhone plays. Other music files (Ogg, Opus) are in the folder too, and are counted, not listed.
    static let playable: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]
    static let unplayable: Set<String> = ["ogg", "oga", "opus", "wma"]

    /// The file that says what the folder is for; it is made when the folder is first looked at, so that the folder shows.
    static let helpName = "Put your music here.txt"

    let root: URL
    let readTags: (URL) async -> MusicTags?
    let now: () -> Int64

    init(root: URL, readTags: @escaping (URL) async -> MusicTags?, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.root = root
        self.readTags = readTags
        self.now = now
    }

    /// Makes the file that tells what the folder is for, if it is not there.
    func prepare() {
        let help = root.appendingPathComponent(Self.helpName)
        if FileManager.default.fileExists(atPath: help.path) { return }
        let text = """
            Copy music files (MP3, M4A, AAC, WAV, AIFF, FLAC) into this folder and open "On this phone" in the Library of Sapoche.
            Chép các tệp nhạc (MP3, M4A, AAC, WAV, AIFF, FLAC) vào thư mục này rồi mở "Trên máy này" ở Thư viện của Sapoche.
            """
        try? text.write(to: help, atomically: true, encoding: .utf8)
    }

    /// The file at [key], a path inside the folder as the list gives it.
    func url(forKey key: String) -> URL { Self.url(in: root, key: key) }

    static func url(in root: URL, key: String) -> URL {
        key.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// The music files in the folder and in the folders inside it, and how many files are music this phone cannot play.
    /// Files shorter than a song, with no tags the system can read, or that are not music at all are left out.
    func scan() async -> (files: [LocalFile], unsupported: Int) {
        let base = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], 0) }
        var found: [LocalFile] = []
        var unsupported = 0
        // Walked in one go: an enumerator is not to be iterated from async code
        for url in walker.allObjects.compactMap({ $0 as? URL }) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            if Self.unplayable.contains(ext) {
                unsupported += 1
                continue
            }
            guard Self.playable.contains(ext) else { continue }
            guard let tags = await readTags(url), tags.durMs >= LocalMusic.minMs else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let key = String(path.dropFirst(base.count + 1))
            let name = url.deletingPathExtension().lastPathComponent
            let added = values?.creationDate ?? values?.contentModificationDate
            found.append(LocalFile(
                key: key,
                uri: key,
                title: Self.clean(tags.title) ?? name,
                artist: Self.clean(tags.artist) ?? "",
                album: Self.clean(tags.album) ?? "",
                durMs: tags.durMs,
                mime: Self.mime(ext),
                size: Int64(values?.fileSize ?? 0),
                addedAt: added.map { Int64($0.timeIntervalSince1970 * 1000) } ?? now()
            ))
        }
        // The walk comes in the order the disk likes: a fixed one keeps two scans of one folder alike
        return (found.sorted { $0.key < $1.key }, unsupported)
    }

    /// Copies [urls], files the person picked, into the folder; a name already taken gets a number. Gives back how many
    /// were copied; one that cannot be is skipped.
    func copyIn(_ urls: [URL]) -> Int {
        var copied = 0
        for source in urls {
            let ext = source.pathExtension
            let stem = source.deletingPathExtension().lastPathComponent
            var target = root.appendingPathComponent(source.lastPathComponent)
            var n = 1
            while FileManager.default.fileExists(atPath: target.path) {
                n += 1
                target = root.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            }
            if (try? FileManager.default.copyItem(at: source, to: target)) != nil { copied += 1 }
        }
        return copied
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func mime(_ ext: String) -> String {
        switch ext {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default: return "audio/" + ext
        }
    }
}
