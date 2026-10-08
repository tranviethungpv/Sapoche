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

/// An artist, or a profile (somebody who is not an artist but puts videos and playlists up). [shelves] are the other
/// rows of the page (videos, live performances, playlists); [topSongsId] is the playlist that holds all of the top songs.
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
    var shelves: [MusicShelf] = []
    var topSongsId: String?
}

/// A mood or activity on the home page of YouTube Music (Relax, Workout...); [params] asks for the shelves that suit it.
struct MoodChip: Equatable {
    let label: String
    let params: String
}

/// The home page of YouTube Music: the moods it offers and its shelves, for a mood when one was asked for.
struct MusicHome {
    let chips: [MoodChip]
    let shelves: [MusicShelf]
}

/// A titled row of a page: songs, albums, playlists or artists, any mix of them.
struct MusicShelf {
    let title: String
    let tracks: [MusicTrack]
    var playlists: [PlaylistCard] = []
    var albums: [AlbumCard] = []
    var artists: [ArtistCard] = []
}

/// An album, single, EP or playlist: what it is, who made it and its songs. [more] is where the songs after these are
/// asked for (a long playlist comes a hundred at a time); nil when these are all of them.
struct CollectionPage {
    let id: String
    let title: String
    /// What YouTube calls it: "Album", "Single", "EP", "Playlist".
    let kind: String?
    let year: String?
    /// The artist of an album, or who made the playlist, and where their page is when there is one.
    let owner: String?
    let ownerId: String?
    let description: String?
    let thumbUrl: String?
    /// The facts under the title, like "18 songs" and "1 hour, 13 minutes".
    let stats: [String]
    let tracks: [MusicTrack]
    let more: String?
    /// Other rows of the page: more by the artist, similar playlists.
    let shelves: [MusicShelf]
}

/// One result of a search. [kind] is `song`, `video`, `episode`, `album` (an album, single or EP), `artist`, `profile` or
/// `playlist` (a playlist or a podcast); [id] is the video to play or the page to open. [label] is what YouTube calls it
/// when it says so ("Single", "EP"). [track] is there for what plays: song, video and episode.
struct SearchItem {
    let kind: String
    let id: String
    let title: String
    let subtitle: String?
    let label: String?
    let thumbUrl: String?
    var track: MusicTrack?
}

/// A filter YouTube Music offers for a search, and the code that asks for it.
struct SearchChip: Equatable {
    let label: String
    let params: String
}

/// What a search found: the [top] result when YouTube picks one, the [items] in the order it lists them, and the [chips]
/// to narrow it down. [more] is where the results after these are asked for; nil when these are all.
struct SearchPage {
    let chips: [SearchChip]
    let top: SearchItem?
    let items: [SearchItem]
    let more: String?
}

/// The songs after those of a [CollectionPage].
struct Continuation {
    let tracks: [MusicTrack]
    let more: String?
}

/// The part of YouTube Music this app reads; the rest of the app only knows this interface.
protocol MusicSource {
    /// The radio of [videoId] (what plays after it), or only the song itself without [radio].
    func watchNext(_ videoId: String, radio: Bool) async throws -> WatchNext

    func related(_ relatedId: String) async throws -> Related

    /// The words of a song, as plain text without times; nil when there are none.
    func lyrics(_ lyricsId: String) async throws -> String?

    func artist(_ artistId: String) async throws -> ArtistPage

    /// An album or a playlist, by the id of its page (`MPRE…` for an album, a playlist id otherwise).
    func collection(_ id: String) async throws -> CollectionPage

    /// The songs of a long playlist after [token], which an earlier answer gave.
    func more(_ token: String) async throws -> Continuation

    /// Everything that matches [query], or what a filter of [SearchChip.params] keeps of it.
    func searchPage(_ query: String, params: String?) async throws -> SearchPage

    /// The results of a search after [token], which an earlier answer gave.
    func searchMore(_ token: String) async throws -> SearchPage

    /// Songs (audio releases) matching [query].
    func searchSongs(_ query: String) async throws -> [MusicTrack]

    /// Videos matching [query].
    func searchVideos(_ query: String) async throws -> [MusicTrack]

    /// The songs of a playlist, with its title.
    func playlist(_ playlistId: String) async throws -> (title: String?, tracks: [MusicTrack])

    /// What YouTube Music shows everybody on its home page, with the shelf names in [language] (a code like "vi").
    func trending(language: String) async throws -> [MusicShelf]

    /// The home page with the moods it offers; with a mood's [params] the shelves that suit that mood.
    func home(language: String, params: String?) async throws -> MusicHome

    /// The charts of the person's country: playlists of what is played most, and the artists played most.
    func charts() async throws -> [MusicShelf]
}

extension MusicSource {
    func watchNext(_ videoId: String) async throws -> WatchNext {
        try await watchNext(videoId, radio: true)
    }
}
