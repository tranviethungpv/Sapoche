import Foundation

/// What a person keeps in the app: songs they liked and what they listened to. It lives here in the native side, not
/// in the UI, because the playback records listens while the screen is gone.
///
/// All of it runs one statement after another, so a like tapped right after a listen is written after it. [tracks]
/// holds the details of every song something points to, so lists can be shown without the network.
actor LibraryStore {
    /// A song with the time it was liked or last heard, and how often it was heard.
    struct Entry: Equatable {
        let track: TrackRef
        let at: Int64
        var plays = 0
    }

    /// A song or an artist the person asked not to be offered: [kind] is `song` (the key is its video id) or `artist`.
    struct Blocked: Equatable {
        let kind: String
        let key: String
        let label: String
    }

    /// A song to keep: [state] is queued, waiting (for Wi-Fi and a charger), done or failed.
    struct Download: Equatable {
        let track: TrackRef
        let state: String
        let bytes: Int64
    }

    /// Songs YouTube suggested for a seed, and when they were fetched.
    struct Cached: Equatable {
        let tracks: [TrackRef]
        let fetchedAt: Int64
    }

    /// A playlist as listed: its cover is made of the pictures of its first songs, `coverParts` at most, each once.
    struct Playlist: Equatable {
        let id: Int64
        let name: String
        let count: Int
        let thumbs: [String]
        let updatedAt: Int64
    }

    /// A playlist as kept in a backup: what it is called, when, and its songs in order.
    struct SavedPlaylist: Equatable {
        let name: String
        let createdAt: Int64
        let updatedAt: Int64
        let tracks: [TrackRef]
    }

    /// What is worth carrying to another phone: likes, playlists and every listen, each with its time.
    struct Backup: Equatable {
        let liked: [Entry]
        let playlists: [SavedPlaylist]
        let listens: [Entry]
    }

    /// How much of a backup was new to this phone.
    struct Restored: Equatable {
        let liked: Int
        let playlists: Int
        let listens: Int
    }

    static let recentLimit = 100
    static let historyKeep = 2000
    static let maxPlaylist = 500
    static let maxName = 60
    static let coverParts = 4
    static let skipsKeep = 300
    static let queued = "queued"
    static let waiting = "waiting"
    static let done = "done"
    static let failed = "failed"
    static let maxTries = 3
    private static let version = 5

    private let db: SQLite
    private let onChange: @Sendable () -> Void
    private let untitled: @Sendable () -> String

    /// [path] of the database file, or `:memory:`. [onChange] is called after every write, so a screen that shows the
    /// library can refresh; [untitled] is the name given to a playlist whose name is empty.
    init(path: String, onChange: @escaping @Sendable () -> Void = {}, untitled: @escaping @Sendable () -> String = { "Untitled" }) throws {
        db = try SQLite(path: path)
        self.onChange = onChange
        self.untitled = untitled
        try Self.migrate(db)
    }

    private static func migrate(_ db: SQLite) throws {
        let found = db.version
        if found >= version { return }
        try db.transaction {
            // Each step brings the database one version forward
            if found < 1 {
                try db.run("CREATE TABLE tracks(video_id TEXT PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, thumb TEXT, dur_ms INTEGER NOT NULL)")
                try db.run("CREATE TABLE likes(video_id TEXT PRIMARY KEY REFERENCES tracks(video_id), liked_at INTEGER NOT NULL)")
                try db.run("CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT, video_id TEXT NOT NULL REFERENCES tracks(video_id), played_at INTEGER NOT NULL)")
                try db.run("CREATE INDEX history_by_song ON history(video_id)")
            }
            if found < 2 {
                try db.run("CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)")
                // A song is in a playlist once; position gives the order and may have gaps
                try db.run("CREATE TABLE playlist_items(playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE, video_id TEXT NOT NULL REFERENCES tracks(video_id), position INTEGER NOT NULL, PRIMARY KEY(playlist_id, video_id))")
                try db.run("CREATE INDEX playlist_items_by_song ON playlist_items(video_id)")
            }
            if found < 3 {
                // What YouTube listed beside a seed song, kept so suggestions show without the network
                try db.run("CREATE TABLE suggestions(seed_video_id TEXT PRIMARY KEY, json TEXT NOT NULL, fetched_at INTEGER NOT NULL)")
            }
            if found < 4 {
                // Songs to keep on this phone; the files are in the downloads folder, this says which and how far along
                try db.run("CREATE TABLE downloads(video_id TEXT PRIMARY KEY REFERENCES tracks(video_id), state TEXT NOT NULL, bytes INTEGER NOT NULL DEFAULT 0, tries INTEGER NOT NULL DEFAULT 0, at INTEGER NOT NULL)")
            }
            if found < 5 {
                // What tells the suggestions what not to offer: songs left after a few seconds, and what was blocked on purpose
                try db.run("CREATE TABLE skips(id INTEGER PRIMARY KEY AUTOINCREMENT, video_id TEXT NOT NULL REFERENCES tracks(video_id), skipped_at INTEGER NOT NULL)")
                try db.run("CREATE TABLE blocked(kind TEXT NOT NULL, key TEXT NOT NULL, label TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(kind, key))")
            }
        }
        db.version = version
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // ------------------------------------------------------------------ likes

    /// Liked songs, the most recently liked first.
    func liked() throws -> [Entry] {
        try entries(db.rows("""
            SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, l.liked_at, 0
            FROM likes l JOIN tracks t ON t.video_id = l.video_id ORDER BY l.liked_at DESC, t.video_id
            """))
    }

    func setLiked(_ track: TrackRef, _ liked: Bool, at: Int64 = LibraryStore.now()) throws {
        try db.transaction {
            if liked {
                try upsertTrack(track)
                // Liking a song that is already liked keeps the time it was first liked
                try db.run("INSERT OR IGNORE INTO likes(video_id, liked_at) VALUES(?, ?)", [.text(track.videoId), .int(at)])
            } else {
                try db.run("DELETE FROM likes WHERE video_id = ?", [.text(track.videoId)])
                try dropUnusedTracks()
            }
        }
        onChange()
    }

    // ------------------------------------------------------------------ history

    /// Songs heard, once each, the one heard last first.
    func recent(limit: Int = LibraryStore.recentLimit) throws -> [Entry] {
        try entries(db.rows("""
            SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, MAX(h.played_at) AS last_at, COUNT(*)
            FROM history h JOIN tracks t ON t.video_id = h.video_id
            GROUP BY h.video_id ORDER BY last_at DESC, t.video_id LIMIT ?
            """, [.int(Int64(limit))]))
    }

    /// [track] was heard. Only the last [historyKeep] listens are kept.
    func recordListen(_ track: TrackRef, at: Int64 = LibraryStore.now()) throws {
        try db.transaction {
            try upsertTrack(track)
            try db.run("INSERT INTO history(video_id, played_at) VALUES(?, ?)", [.text(track.videoId), .int(at)])
            try db.run("DELETE FROM history WHERE id <= (SELECT id FROM history ORDER BY id DESC LIMIT 1 OFFSET \(Self.historyKeep))")
            try dropUnusedTracks()
        }
        onChange()
    }

    /// Every listen, the latest first, each with its own time: what the taste is worked out from.
    func listens(limit: Int = LibraryStore.historyKeep) throws -> [Entry] {
        try entries(db.rows("""
            SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, h.played_at, 1
            FROM history h JOIN tracks t ON t.video_id = h.video_id ORDER BY h.played_at DESC, h.id DESC LIMIT ?
            """, [.int(Int64(limit))]))
    }

    /// [track] was left after a few seconds. Only the last [skipsKeep] are kept. It is not announced: nothing shows it.
    func recordSkip(_ track: TrackRef, at: Int64 = LibraryStore.now()) throws {
        try db.transaction {
            try upsertTrack(track)
            try db.run("INSERT INTO skips(video_id, skipped_at) VALUES(?, ?)", [.text(track.videoId), .int(at)])
            try db.run("DELETE FROM skips WHERE id <= (SELECT id FROM skips ORDER BY id DESC LIMIT 1 OFFSET \(Self.skipsKeep))")
            try dropUnusedTracks()
        }
    }

    /// Songs left after a few seconds, the latest first, each time one entry.
    func skipped() throws -> [Entry] {
        try entries(db.rows("""
            SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, s.skipped_at, 1
            FROM skips s JOIN tracks t ON t.video_id = s.video_id ORDER BY s.skipped_at DESC, s.id DESC
            """))
    }

    func clearHistory() throws {
        try db.transaction {
            try db.run("DELETE FROM history")
            // What was left is part of the listening a person asked to forget
            try db.run("DELETE FROM skips")
            try dropUnusedTracks()
        }
        onChange()
    }

    // ------------------------------------------------------------------ playlists

    /// Playlists, the one changed last first.
    func playlists() throws -> [Playlist] {
        try db.rows("""
            SELECT p.id, p.name, p.updated_at, COUNT(i.video_id)
            FROM playlists p LEFT JOIN playlist_items i ON i.playlist_id = p.id
            GROUP BY p.id ORDER BY p.updated_at DESC, p.id DESC
            """).map { Playlist(id: $0[0].int, name: $0[1].text ?? "", count: Int($0[3].int), thumbs: try coverThumbs($0[0].int), updatedAt: $0[2].int) }
    }

    private func coverThumbs(_ playlistId: Int64) throws -> [String] {
        try db.rows("""
            SELECT t.thumb FROM playlist_items f JOIN tracks t ON t.video_id = f.video_id
            WHERE f.playlist_id = ? AND t.thumb IS NOT NULL GROUP BY t.thumb ORDER BY MIN(f.position) LIMIT \(LibraryStore.coverParts)
            """, [.int(playlistId)]).compactMap { $0[0].text }
    }

    /// The songs of a playlist in order; empty when there is no such playlist.
    func playlistTracks(_ id: Int64) throws -> [TrackRef] {
        try entries(db.rows("""
            SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, 0, 0
            FROM playlist_items i JOIN tracks t ON t.video_id = i.video_id WHERE i.playlist_id = ? ORDER BY i.position
            """, [.int(id)])).map(\.track)
    }

    /// Makes a playlist, with [tracks] in it if given, and returns its id.
    func createPlaylist(_ name: String, _ tracks: [TrackRef] = [], at: Int64 = LibraryStore.now()) throws -> Int64 {
        let id = try db.transaction { () -> Int64 in
            try db.run("INSERT INTO playlists(name, created_at, updated_at) VALUES(?, ?, ?)", [.text(cleanName(name)), .int(at), .int(at)])
            let created = db.lastInsertRowId
            _ = try appendTracks(created, tracks)
            return created
        }
        onChange()
        return id
    }

    func renamePlaylist(_ id: Int64, _ name: String, at: Int64 = LibraryStore.now()) throws {
        try changePlaylist(id, at) {
            try db.run("UPDATE playlists SET name = ? WHERE id = ?", [.text(cleanName(name)), .int(id)])
        }
    }

    /// Deletes the playlist; the songs stay wherever else they are kept.
    func deletePlaylist(_ id: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM playlists WHERE id = ?", [.int(id)])
            try dropUnusedTracks()
        }
        onChange()
    }

    /// Adds songs at the end; those already in the playlist are left where they are. Returns how many were added.
    func addToPlaylist(_ id: Int64, _ tracks: [TrackRef], at: Int64 = LibraryStore.now()) throws -> Int {
        var added = 0
        try changePlaylist(id, at) { added = try appendTracks(id, tracks) }
        return added
    }

    func removeFromPlaylist(_ id: Int64, _ videoId: String, at: Int64 = LibraryStore.now()) throws {
        try changePlaylist(id, at) {
            try db.run("DELETE FROM playlist_items WHERE playlist_id = ? AND video_id = ?", [.int(id), .text(videoId)])
            try dropUnusedTracks()
        }
    }

    /// Puts a song at place [toIndex] (0 is the top) of the playlist.
    func movePlaylistItem(_ id: Int64, _ videoId: String, toIndex: Int, at: Int64 = LibraryStore.now()) throws {
        try changePlaylist(id, at) {
            var order = try db.rows("SELECT video_id FROM playlist_items WHERE playlist_id = ? ORDER BY position", [.int(id)]).compactMap { $0[0].text }
            guard let from = order.firstIndex(of: videoId) else { return }
            order.remove(at: from)
            order.insert(videoId, at: min(max(toIndex, 0), order.count))
            for (position, video) in order.enumerated() {
                try db.run("UPDATE playlist_items SET position = ? WHERE playlist_id = ? AND video_id = ?", [.int(Int64(position)), .int(id), .text(video)])
            }
        }
    }

    /// Runs [change] on one playlist in a transaction, stamps it as changed and announces it.
    private func changePlaylist(_ id: Int64, _ at: Int64, _ change: () throws -> Void) throws {
        try db.transaction {
            try change()
            try db.run("UPDATE playlists SET updated_at = ? WHERE id = ?", [.int(at), .int(id)])
        }
        onChange()
    }

    private func appendTracks(_ id: Int64, _ tracks: [TrackRef]) throws -> Int {
        let state = try db.rows("SELECT COALESCE(MAX(position) + 1, 0), COUNT(*) FROM playlist_items WHERE playlist_id = ?", [.int(id)])
        var next = state[0][0].int
        var room = Self.maxPlaylist - Int(state[0][1].int)
        var added = 0
        for track in tracks {
            if room <= 0 { break }
            try upsertTrack(track)
            try db.run("INSERT OR IGNORE INTO playlist_items(playlist_id, video_id, position) VALUES(?, ?, ?)", [.int(id), .text(track.videoId), .int(next)])
            if db.changes == 0 { continue }
            next += 1
            room -= 1
            added += 1
        }
        return added
    }

    private func cleanName(_ name: String) -> String {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxName))
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? untitled() : trimmed
    }

    // ------------------------------------------------------------------ backup

    /// Everything that [restore] can put back. Downloads are not in it: they are the audio itself, and can be fetched again.
    func backup() throws -> Backup {
        let liked = try entries(db.rows("""
            SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, l.liked_at, 0
            FROM likes l JOIN tracks t ON t.video_id = l.video_id ORDER BY l.liked_at, t.video_id
            """))
        let listens = try entries(db.rows("""
            SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, h.played_at, 0
            FROM history h JOIN tracks t ON t.video_id = h.video_id ORDER BY h.played_at, h.id
            """))
        var playlists: [SavedPlaylist] = []
        for row in try db.rows("SELECT id, name, created_at, updated_at FROM playlists ORDER BY id") {
            let songs = try entries(db.rows("""
                SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, 0, 0
                FROM playlist_items i JOIN tracks t ON t.video_id = i.video_id WHERE i.playlist_id = ? ORDER BY i.position
                """, [.int(row[0].int)])).map(\.track)
            playlists.append(SavedPlaylist(name: row[1].text ?? "", createdAt: row[2].int, updatedAt: row[3].int, tracks: songs))
        }
        return Backup(liked: liked, playlists: playlists, listens: listens)
    }

    /// Adds what [backup] holds to what is here; nothing is removed or overwritten, so restoring twice, or on the phone
    /// it came from, changes nothing. A playlist with the name of one already here gets the songs it lacks.
    func restore(_ backup: Backup) throws -> Restored {
        var liked = 0
        var playlists = 0
        var listens = 0
        try db.transaction {
            for entry in backup.liked {
                try upsertTrack(entry.track)
                try db.run("INSERT OR IGNORE INTO likes(video_id, liked_at) VALUES(?, ?)", [.text(entry.track.videoId), .int(entry.at)])
                if db.changes > 0 { liked += 1 }
            }
            // Names of the playlists there were before: two in the backup with one name stay two
            var here: [String: Int64] = [:]
            for row in try db.rows("SELECT name, id FROM playlists ORDER BY id DESC") {
                if let name = row[0].text { here[name] = row[1].int }
            }
            for playlist in backup.playlists {
                let name = cleanName(playlist.name)
                if let id = here[name] {
                    // An old playlist that gained songs is not moved to the top
                    if try appendTracks(id, playlist.tracks) > 0 { playlists += 1 }
                } else {
                    try db.run("INSERT INTO playlists(name, created_at, updated_at) VALUES(?, ?, ?)", [.text(name), .int(playlist.createdAt), .int(playlist.updatedAt)])
                    _ = try appendTracks(db.lastInsertRowId, playlist.tracks)
                    playlists += 1
                }
            }
            for entry in backup.listens.sorted(by: { $0.at < $1.at }) {
                let seen = try !db.rows("SELECT 1 FROM history WHERE video_id = ? AND played_at = ?", [.text(entry.track.videoId), .int(entry.at)]).isEmpty
                if seen { continue }
                try upsertTrack(entry.track)
                try db.run("INSERT INTO history(video_id, played_at) VALUES(?, ?)", [.text(entry.track.videoId), .int(entry.at)])
                listens += 1
            }
            // Listens from a backup are older than the ones here, so what is over the limit goes by time, not by row
            try db.run("DELETE FROM history WHERE id IN (SELECT id FROM history ORDER BY played_at DESC, id DESC LIMIT -1 OFFSET \(Self.historyKeep))")
            try dropUnusedTracks()
        }
        onChange()
        return Restored(liked: liked, playlists: playlists, listens: listens)
    }

    // ------------------------------------------------------------------ suggestions

    // ------------------------------------------------------------------ blocked

    /// Block `song` (key: video id) or `artist` (key: [Taste.artistKey]); blocking again changes the label.
    func block(kind: String, key: String, label: String, at: Int64 = LibraryStore.now()) throws {
        try db.run("INSERT OR REPLACE INTO blocked(kind, key, label, at) VALUES(?, ?, ?, ?)", [.text(kind), .text(key), .text(label), .int(at)])
        onChange()
    }

    func unblock(kind: String, key: String) throws {
        try db.run("DELETE FROM blocked WHERE kind = ? AND key = ?", [.text(kind), .text(key)])
        onChange()
    }

    /// What was blocked, the latest first.
    func blocked() throws -> [Blocked] {
        try db.rows("SELECT kind, key, label FROM blocked ORDER BY at DESC, key").map {
            Blocked(kind: $0[0].text ?? "", key: $0[1].text ?? "", label: $0[2].text ?? "")
        }
    }

    /// Ids of the songs heard since [since].
    func heardSince(_ since: Int64) throws -> Set<String> {
        Set(try db.rows("SELECT DISTINCT video_id FROM history WHERE played_at >= ?", [.int(since)]).compactMap { $0[0].text })
    }

    func likedIds() throws -> Set<String> {
        Set(try db.rows("SELECT video_id FROM likes").compactMap { $0[0].text })
    }

    /// What was kept for [seed], or nil.
    func cachedSuggestions(_ seed: String) throws -> Cached? {
        guard let row = try db.rows("SELECT json, fetched_at FROM suggestions WHERE seed_video_id = ?", [.text(seed)]).first,
              let json = row[0].text.flatMap({ JSON.parse($0) }), json.raw is [Any] else { return nil }
        let tracks = json.array.compactMap { item -> TrackRef? in
            guard let id = item.at("v").string, let title = item.at("t").string else { return nil }
            let thumb = item.at("i").string.flatMap { $0.isEmpty ? nil : $0 }
            return TrackRef(videoId: id, title: title, artist: item.at("a").string ?? "", thumb: thumb, durMs: item.at("d").int64 ?? 0)
        }
        return Cached(tracks: tracks, fetchedAt: row[1].int)
    }

    func putSuggestions(_ seed: String, _ tracks: [TrackRef], at: Int64 = LibraryStore.now()) throws {
        let json = tracks.map { ["v": $0.videoId, "t": $0.title, "a": $0.artist, "i": $0.thumb ?? "", "d": $0.durMs] as [String: Any] }
        try db.run("INSERT OR REPLACE INTO suggestions(seed_video_id, json, fetched_at) VALUES(?, ?, ?)",
                   [.text(seed), .text(JSONText.encode(json)), .int(at)])
        onChange()
    }

    /// Forgets what was kept for every seed but [seeds].
    func keepSuggestionsFor(_ seeds: [String]) throws {
        let marks = seeds.map { _ in "?" }.joined(separator: ",")
        try db.run("DELETE FROM suggestions WHERE seed_video_id NOT IN (\(marks))", seeds.map { .text($0) })
    }

    // ------------------------------------------------------------------ downloads

    /// Puts songs on the list to download. Done ones are left alone; failed ones try again; with [waiting] they wait for
    /// Wi-Fi and a charger instead of starting at once, unless already asked for the plain way.
    func requestDownloads(_ tracks: [TrackRef], waiting: Bool = false, at: Int64 = LibraryStore.now()) throws {
        let wanted = waiting ? Self.waiting : Self.queued
        try db.transaction {
            for track in tracks {
                try upsertTrack(track)
                try db.run("INSERT OR IGNORE INTO downloads(video_id, state, at) VALUES(?, ?, ?)", [.text(track.videoId), .text(wanted), .int(at)])
                if db.changes > 0 { continue }
                // Already listed: asking again in the plain way beats waiting, and a failed one gets another go
                try db.run("UPDATE downloads SET state = ?, tries = 0 WHERE video_id = ? AND (state = ? OR (state = ? AND ? = ?))",
                           [.text(wanted), .text(track.videoId), .text(Self.failed), .text(Self.waiting), .text(wanted), .text(Self.queued)])
            }
        }
        onChange()
    }

    /// The oldest song still to download in [state], other than those in [skip].
    func nextDownload(_ state: String, skip: Set<String> = []) throws -> String? {
        try db.rows("SELECT video_id FROM downloads WHERE state = ? ORDER BY rowid", [.text(state)])
            .compactMap { $0[0].text }.first { !skip.contains($0) }
    }

    func finishDownload(_ videoId: String, bytes: Int64, at: Int64 = LibraryStore.now()) throws {
        try db.run("UPDATE downloads SET state = ?, bytes = ?, at = ?, tries = 0 WHERE video_id = ?", [.text(Self.done), .int(bytes), .int(at), .text(videoId)])
        onChange()
    }

    /// One try failed. After [maxTries] the song is marked failed; true when that happened.
    func failDownload(_ videoId: String) throws -> Bool {
        try db.run("UPDATE downloads SET tries = tries + 1 WHERE video_id = ?", [.text(videoId)])
        try db.run("UPDATE downloads SET state = ? WHERE video_id = ? AND tries >= ?", [.text(Self.failed), .text(videoId), .int(Int64(Self.maxTries))])
        onChange()
        return try db.rows("SELECT state FROM downloads WHERE video_id = ?", [.text(videoId)]).first?[0].text == Self.failed
    }

    /// Takes a song off the list (the caller removes its file).
    func removeDownload(_ videoId: String) throws {
        try db.transaction {
            try db.run("DELETE FROM downloads WHERE video_id = ?", [.text(videoId)])
            try dropUnusedTracks()
        }
        onChange()
    }

    func clearDownloads() throws {
        try db.transaction {
            try db.run("DELETE FROM downloads")
            try dropUnusedTracks()
        }
        onChange()
    }

    /// The list: what is on the phone first, the most recent first, then what is still to come.
    func downloads() throws -> [Download] {
        try db.rows("""
            SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, d.at, 0, d.state, d.bytes
            FROM downloads d JOIN tracks t ON t.video_id = d.video_id
            ORDER BY d.state = ? DESC, CASE WHEN d.state = ? THEN d.at END DESC, d.rowid
            """, [.text(Self.done), .text(Self.done)]).map {
            Download(track: track($0), state: $0[7].text ?? "", bytes: $0[8].int)
        }
    }

    /// Liked songs that are not on the list yet (or failed), for downloading them by themselves.
    func likedToDownload() throws -> [TrackRef] {
        try entries(db.rows("""
            SELECT t.video_id, t.title, t.artist, t.thumb, t.dur_ms, 0, 0 FROM likes l
            JOIN tracks t ON t.video_id = l.video_id LEFT JOIN downloads d ON d.video_id = l.video_id
            WHERE d.video_id IS NULL ORDER BY l.liked_at DESC
            """)).map(\.track)
    }

    // ------------------------------------------------------------------ helpers

    /// Adds the song's details, or brings them up to date. A length that is not known does not erase one that is.
    private func upsertTrack(_ track: TrackRef) throws {
        try db.run("INSERT OR IGNORE INTO tracks(video_id, title, artist, thumb, dur_ms) VALUES(?, ?, ?, ?, ?)",
                   [.text(track.videoId), .text(track.title), .text(track.artist), SQLValue(track.thumb), .int(track.durMs)])
        if db.changes > 0 { return }
        try db.run("UPDATE tracks SET title = ?, artist = ?, thumb = ?, dur_ms = CASE WHEN ? > 0 THEN ? ELSE dur_ms END WHERE video_id = ?",
                   [.text(track.title), .text(track.artist), SQLValue(track.thumb), .int(track.durMs), .int(track.durMs), .text(track.videoId)])
    }

    /// Forgets songs nothing points to any more. Every table that refers to a song must be listed here, or its songs
    /// would be lost.
    private func dropUnusedTracks() throws {
        try db.run("""
            DELETE FROM tracks WHERE video_id NOT IN (SELECT video_id FROM likes)
            AND video_id NOT IN (SELECT video_id FROM history)
            AND video_id NOT IN (SELECT video_id FROM playlist_items)
            AND video_id NOT IN (SELECT video_id FROM downloads)
            AND video_id NOT IN (SELECT video_id FROM skips)
            """)
    }

    private func track(_ row: [SQLValue]) -> TrackRef {
        TrackRef(videoId: row[0].text ?? "", title: row[1].text ?? "", artist: row[2].text ?? "", thumb: row[3].text, durMs: row[4].int)
    }

    private func entries(_ rows: [[SQLValue]]) -> [Entry] {
        rows.map { Entry(track: track($0), at: $0[5].int, plays: Int($0[6].int)) }
    }
}
