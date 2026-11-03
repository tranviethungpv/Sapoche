import Foundation

/// What the person told the taste, kept beside the library as marks of one of these kinds.
enum TasteMarks {
    /// An artist (by `Taste.artistKey`) to be suggested less: not a seed, not known, nothing offered to a room.
    static let quietArtist = "quiet_artist"
    /// A song (by video id) that is not to count: whatever happened to it is left out of the taste.
    static let quietSong = "quiet_song"
    /// A song a new person chose an artist by (key: its video id; label: the song as JSON): counts as heard when chosen.
    static let starter = "starter"

    /// The song a `starter` mark stands for, heard at [at]; nil when its [label] is not a song.
    static func starter(label: String, at: Int64) -> Stamped? {
        guard let json = JSON.parse(label), let videoId = json["videoId"].string else { return nil }
        let track = TrackRef(videoId: videoId, title: json["title"].string ?? "", artist: json["artist"].string ?? "",
                             thumb: json["thumb"].string, durMs: json["durMs"].int64 ?? 0)
        return Stamped(track: track, at: at)
    }
}
