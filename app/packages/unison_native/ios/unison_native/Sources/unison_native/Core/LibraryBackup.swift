import Foundation

/// The file a library is saved to and read back from: plain JSON, so that a person can look inside it. Songs are
/// listed once, and likes, playlists and listens point to them by video id. The same format as the Android app's, so
/// a library can move from one phone to the other.
enum LibraryBackup {
    /// The file is not a backup of ours, or is one from a newer app.
    struct FormatError: Error, LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private static let app = "unison"
    private static let version = 1
    private static let maxId = 32
    private static let maxText = 300

    static func toJson(_ backup: LibraryStore.Backup, at: Int64) -> String {
        var songs: [String: Any] = [:]
        func note(_ track: TrackRef) {
            songs[track.videoId] = ["title": track.title, "artist": track.artist, "thumb": track.thumb ?? NSNull(), "durMs": track.durMs] as [String: Any]
        }
        backup.liked.forEach { note($0.track) }
        backup.listens.forEach { note($0.track) }
        backup.playlists.forEach { $0.tracks.forEach(note) }
        let root: [String: Any] = [
            "app": app,
            "version": version,
            "exportedAt": at,
            "songs": songs,
            "liked": backup.liked.map { ["id": $0.track.videoId, "at": $0.at] as [String: Any] },
            "playlists": backup.playlists.map {
                ["name": $0.name, "createdAt": $0.createdAt, "updatedAt": $0.updatedAt, "songs": $0.tracks.map(\.videoId)] as [String: Any]
            },
            "history": backup.listens.map { ["id": $0.track.videoId, "at": $0.at] as [String: Any] },
        ]
        return JSONText.encode(root)
    }

    /// Reads a file written by [toJson]. References to songs the file does not describe are skipped.
    static func fromJson(_ text: String) throws -> LibraryStore.Backup {
        guard let root = JSON.parse(text), root.object != nil, root.at("app").string == app else { throw FormatError(message: "Not a Unison backup") }
        if (root.at("version").int ?? 0) > version { throw FormatError(message: "Made by a newer version of Unison") }
        guard let table = root.at("songs").object else { throw FormatError(message: "Not a Unison backup") }
        var songs: [String: TrackRef] = [:]
        for (id, value) in table {
            let song = JSON(value)
            let title = String((song.at("title").string ?? "").prefix(maxText))
            if id.trimmingCharacters(in: .whitespaces).isEmpty || id.count > maxId || title.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let thumb = song.at("thumb").string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            songs[id] = TrackRef(videoId: id, title: title, artist: String((song.at("artist").string ?? "").prefix(maxText)),
                                 thumb: thumb, durMs: max(song.at("durMs").int64 ?? 0, 0))
        }
        func entries(_ list: JSON) -> [LibraryStore.Entry] {
            list.array.compactMap { item in
                item.object == nil ? nil : songs[item.at("id").string ?? ""].map { LibraryStore.Entry(track: $0, at: item.at("at").int64 ?? 0) }
            }
        }
        let playlists = root.at("playlists").array.filter { $0.object != nil }.map { playlist in
            LibraryStore.SavedPlaylist(
                name: playlist.at("name").string ?? "",
                createdAt: playlist.at("createdAt").int64 ?? 0,
                updatedAt: playlist.at("updatedAt").int64 ?? 0,
                tracks: playlist.at("songs").array.compactMap { songs[$0.string ?? ""] }
            )
        }
        return LibraryStore.Backup(liked: entries(root.at("liked")), playlists: playlists, listens: entries(root.at("history")))
    }
}
