import Foundation

/// A song as YouTube Music describes it. [isSong] tells its audio release ("Song", art track) from a video of it
/// (official clip, or one somebody else uploaded); [counterpart] is the other one when YouTube says which.
final class MusicTrack {
    let videoId: String
    let title: String
    let artist: String
    let artistId: String?
    let album: String?
    let albumId: String?
    let year: String?
    let durationSec: Int64
    let thumbUrl: String?
    let isSong: Bool
    /// What YouTube says about a video's reach, like "1.8B views · 19M likes"; nil for a song.
    let stats: String?
    let counterpart: MusicTrack?

    init(videoId: String, title: String, artist: String, artistId: String? = nil, album: String? = nil, albumId: String? = nil,
         year: String? = nil, durationSec: Int64 = 0, thumbUrl: String? = nil, isSong: Bool = false, stats: String? = nil,
         counterpart: MusicTrack? = nil) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.album = album
        self.albumId = albumId
        self.year = year
        self.durationSec = durationSec
        self.thumbUrl = thumbUrl
        self.isSong = isSong
        self.stats = stats
        self.counterpart = counterpart
    }

    func with(counterpart other: MusicTrack?) -> MusicTrack {
        MusicTrack(videoId: videoId, title: title, artist: artist, artistId: artistId, album: album, albumId: albumId, year: year,
                   durationSec: durationSec, thumbUrl: thumbUrl, isSong: isSong, stats: stats, counterpart: other)
    }

    var ref: TrackRef {
        TrackRef(videoId: videoId, title: title, artist: artist, thumb: thumbUrl, durMs: durationSec * 1000)
    }
}

/// An artist, or a channel that puts music out.
struct ArtistCard: Equatable {
    let id: String
    let name: String
    let subtitle: String?
    let thumbUrl: String?
}

struct AlbumCard: Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let thumbUrl: String?
}

struct PlaylistCard: Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let thumbUrl: String?
}

/// What plays after a song: [tracks] is the radio of the song, the song itself first. The other two are where the
/// lyrics and the "related" page of this song are asked for, when it has them.
struct WatchNext {
    let tracks: [MusicTrack]
    let lyricsId: String?
    let relatedId: String?
}

/// The "related" page of a song.
struct Related {
    let more: [MusicTrack]
    let otherPerformances: [MusicTrack]
    let artists: [ArtistCard]
    let playlists: [PlaylistCard]
    /// Text about the artist.
    let about: String?
}

struct ArtistPage {
    let id: String
    let name: String
    let description: String?
    let subscribers: String?
    let thumbUrl: String?
    let topSongs: [MusicTrack]
    let albums: [AlbumCard]
    let singles: [AlbumCard]
    let similar: [ArtistCard]
}

/// A titled row of a home page: songs, playlists, or both.
struct MusicShelf {
    let title: String
    let tracks: [MusicTrack]
    var playlists: [PlaylistCard] = []
}

/// The part of YouTube Music this app reads; the rest of the app only knows this interface.
protocol MusicSource {
    /// The radio of [videoId] (what plays after it), or only the song itself without [radio].
    func watchNext(_ videoId: String, radio: Bool) async throws -> WatchNext

    func related(_ relatedId: String) async throws -> Related

    /// The words of a song, as plain text without times; nil when there are none.
    func lyrics(_ lyricsId: String) async throws -> String?

    func artist(_ artistId: String) async throws -> ArtistPage

    /// Songs (audio releases) matching [query].
    func searchSongs(_ query: String) async throws -> [MusicTrack]

    /// Videos matching [query].
    func searchVideos(_ query: String) async throws -> [MusicTrack]

    /// The songs of a playlist, with its title.
    func playlist(_ playlistId: String) async throws -> (title: String?, tracks: [MusicTrack])

    /// What YouTube Music shows everybody on its home page, with the shelf names in [language] (a code like "vi").
    func trending(language: String) async throws -> [MusicShelf]
}

extension MusicSource {
    func watchNext(_ videoId: String) async throws -> WatchNext {
        try await watchNext(videoId, radio: true)
    }
}
