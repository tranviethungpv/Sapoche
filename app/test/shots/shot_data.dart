import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';

import '../fake_backend.dart';

/// The one set of songs, albums and people every screen of the picture set is drawn from, so that two runs on two
/// versions of the app show the same words and can be compared pixel by pixel. It is made to be awkward: long titles in
/// Vietnamese, a song with no length, one with no album, one with no plays.
const longVi = MusicTrack(
  videoId: 'long00000vi',
  title: 'Chúng Ta Của Hiện Tại (Phiên Bản Đặc Biệt Kèm Lời Bài Hát)',
  artist: 'Sơn Tùng M-TP',
  durMs: 305000,
  artistId: 'UCsontung',
  album: 'Chúng Ta Của Hiện Tại',
  albumId: 'MPREb_hientai',
  stats: '205M plays',
  isSong: true,
);
const noLength = MusicTrack(
  videoId: 'nolength000',
  title: 'No Length Yet',
  artist: 'Anna Lee',
  durMs: 0,
  artistId: 'UCanna',
  album: 'First Light',
  albumId: 'MPREb_first',
  isSong: true,
);
const noAlbum = MusicTrack(
  videoId: 'noalbum0000',
  title: 'Single With No Album',
  artist: 'Binh & The Long Named Band Of Friends',
  durMs: 187000,
  artistId: 'UCbinh',
  stats: '734K plays',
  isSong: true,
);
const hello = MusicTrack(
  videoId: 'hello000000',
  title: 'Hello',
  artist: 'Adele',
  durMs: 295000,
  artistId: 'UCadele',
  album: '25',
  albumId: 'MPREb_25',
  stats: '1.4B plays',
  isSong: true,
);
const clip = MusicTrack(
  videoId: 'clip0000000',
  title: 'Official Music Video',
  artist: 'Zen',
  durMs: 241000,
  artistId: 'UCzen',
  stats: '12M views',
);

const tracks = [longVi, noLength, noAlbum, hello, clip];

const albumPage = CollectionPage(
  id: 'MPREb_hientai',
  title: 'Chúng Ta Của Hiện Tại',
  kind: 'Album',
  year: '2020',
  owner: 'Sơn Tùng M-TP',
  ownerId: 'UCsontung',
  description: 'A single, released on its own.',
  stats: ['5 songs', '21 minutes'],
  tracks: tracks,
);

const artistPage = ArtistPage(
  id: 'UCsontung',
  name: 'Sơn Tùng M-TP',
  subscribers: '9.2M subscribers',
  description:
      'Nguyễn Thanh Tùng, known by his stage name Sơn Tùng M-TP, is a singer and songwriter. '
      'He began releasing songs online in 2011 and has been in the charts ever since.',
  topSongs: tracks,
  albums: [
    Release(
      id: 'MPREb_hientai',
      title: 'Chúng Ta Của Hiện Tại',
      subtitle: '2020',
    ),
    Release(id: 'MPREb_first', title: 'First Light', subtitle: '2017'),
  ],
  singles: [Release(id: 'MPREb_one', title: 'One Of Those', subtitle: '2021')],
  similar: [
    ArtistCard(id: 'UCanna', name: 'Anna Lee'),
    ArtistCard(id: 'UCbinh', name: 'Binh'),
  ],
);

const homeData = MusicHome(
  chips: [
    MoodChip(label: 'Relax', params: 'p-relax'),
    MoodChip(label: 'Workout', params: 'p-work'),
    MoodChip(label: 'Focus', params: 'p-focus'),
  ],
  shelves: [
    MusicShelf(title: 'Quick picks', tracks: tracks),
    MusicShelf(
      title: 'Featured playlists for you',
      playlists: [
        Release(id: 'PL1', title: 'Calm Evenings', subtitle: 'Playlist'),
        Release(id: 'PL2', title: 'Sơn Tùng M-TP Mix', subtitle: 'Mix'),
        Release(id: 'PL3', title: 'Morning Run', subtitle: 'Playlist'),
      ],
    ),
    MusicShelf(
      title: 'Albums for you',
      albums: [
        Release(
          id: 'MPREb_hientai',
          title: 'Chúng Ta Của Hiện Tại',
          subtitle: 'Sơn Tùng M-TP',
        ),
        Release(id: 'MPREb_first', title: 'First Light', subtitle: 'Anna Lee'),
        Release(id: 'MPREb_25', title: '25', subtitle: 'Adele'),
      ],
    ),
    MusicShelf(
      title: 'Similar artists',
      artists: [
        ArtistCard(id: 'UCanna', name: 'Anna Lee'),
        ArtistCard(id: 'UCbinh', name: 'Binh'),
        ArtistCard(id: 'UCadele', name: 'Adele'),
      ],
    ),
  ],
);

final searchData = SearchResults(
  chips: const [
    SearchChip(label: 'Songs', params: 'p-songs'),
    SearchChip(label: 'Albums', params: 'p-albums'),
  ],
  items: [
    for (final t in tracks)
      SearchItem(
        kind: t.isSong ? 'song' : 'video',
        id: t.videoId,
        title: t.title,
        subtitle: '${t.isSong ? 'Song' : 'Video'} · ${t.artist}',
        track: t,
      ),
    const SearchItem(
      kind: 'album',
      id: 'MPREb_hientai',
      title: 'Chúng Ta Của Hiện Tại',
      subtitle: 'Album · Sơn Tùng M-TP · 2020',
    ),
  ],
);

const lyricsData = Lyrics(
  lines: [
    LyricLine(0, 'Hello, it\'s me'),
    LyricLine(4000, 'I was wondering if after all these years'),
    LyricLine(9000, 'You\'d like to meet, to go over everything'),
    LyricLine(14000, 'They say that time\'s supposed to heal ya'),
  ],
);

/// A library as a person with taste would have it: liked songs, and songs played lately.
void fillLibrary(FakeBackend b) {
  final now = DateTime.now();
  b.likedSongs = [...tracks];
  b.recentSongs = [
    for (final (i, t) in tracks.indexed)
      // Days before today at noon, so that "Yesterday" stays yesterday whenever the pictures are drawn
      HistoryEntry(track: t, at: DateTime(now.year, now.month, now.day - 1 - i, 12), plays: 1 + i),
  ];
}

/// Three people in a room, a queue of five and the first song playing.
RoomSnapshot busyRoom({String phase = 'playing', int index = 0, Link link = Link.connected}) {
  final base = sampleRoom(phase: phase, index: index, songs: 0);
  return RoomSnapshot(
    room: base.room,
    link: link,
    you: base.you,
    phase: phase,
    index: index,
    ownerId: 'me',
    members: const [
      Member(id: 'me', name: 'Anna', ready: true),
      Member(id: 'b', name: 'Bình', ready: true),
      Member(id: 'c', name: 'Cường', ready: true),
    ],
    queue: [
      for (final (i, t) in tracks.indexed)
        QueueEntry(
          id: 'q$i',
          videoId: t.videoId,
          title: t.title,
          artist: t.artist,
          durMs: t.durMs,
          addedBy: const ['me', 'b', 'c'][i % 3],
        ),
    ],
  );
}
