import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unison/data/backend.dart';
import 'package:unison/data/models.dart';
import 'package:unison/data/music_models.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

Track song(String id, String title, String artist) =>
    Track(videoId: id, title: title, artist: artist, durMs: 200000);

HistoryEntry heard(Track track, {int days = 1, int plays = 1}) => HistoryEntry(
  track: track,
  at: DateTime.now().subtract(Duration(days: days)),
  plays: plays,
);

/// Starts on the home page, with what the native side knows already there.
Future<FakeBackend> openHome(
  WidgetTester tester, {
  void Function(FakeBackend backend)? prepare,
  bool inRoom = false,
}) async {
  final (backend, _) = await pumpApp(tester, listen: false);
  prepare?.call(backend);
  backend.emit(
    StateEvent(
      inRoom ? sampleRoom(songs: 0, phase: 'idle') : const RoomSnapshot(),
    ),
  );
  backend.emit(const LibraryEvent());
  await tester.pumpAndSettle();
  return backend;
}

void main() {
  final anna = song('annaaaaaaaa', 'Hello', 'Adele');
  final beck = song('beckaaaaaaa', 'Loser', 'Beck');
  final old = song('oldaaaaaaaa', 'Old Favourite', 'Cher');

  testWidgets(
    'a new person sees a welcome and what is the same for everybody',
    (tester) async {
      final backend = await openHome(
        tester,
        prepare: (b) => b.trendingResult = [
          MusicShelf(
            title: "Today's Hits",
            tracks: [
              MusicTrack(
                videoId: 'hit1aaaaaaa',
                title: 'Hit One',
                artist: 'Star',
                durMs: 1000,
              ),
            ],
          ),
        ],
      );
      expect(find.text('Your music starts here'), findsOneWidget);
      expect(find.text('Quick picks'), findsNothing);
      expect(find.text('Trending'), findsOneWidget);
      expect(find.text('Hit One'), findsOneWidget);
      expect(backend.calls, contains('musicTrending'));
    },
  );

  testWidgets('what was heard, liked and suggested fills the shelves', (
    tester,
  ) async {
    await openHome(
      tester,
      prepare: (b) {
        b.recentSongs = [heard(anna, plays: 5), heard(beck, plays: 2)];
        b.likedSongs = [old];
        b.forYouSongs = [song('newaaaaaaaa', 'Brand New', 'Fresh')];
        b.seedListsResult = [
          SeedList(
            seed: anna.videoId,
            tracks: [
              song('s1aaaaaaaaa', 'Similar One', 'A'),
              song('s2aaaaaaaaa', 'Similar Two', 'B'),
              song('s3aaaaaaaaa', 'Similar Three', 'C'),
            ],
          ),
        ];
      },
    );
    expect(find.text('Your music starts here'), findsNothing);
    expect(find.text('Quick picks'), findsOneWidget);
    expect(find.text('Brand New'), findsOneWidget);
    expect(find.text('Listen again'), findsOneWidget);
    expect(find.text('Mixed for you'), findsOneWidget);
    expect(find.text('Adele Mix'), findsOneWidget);
    expect(find.text('Because you listened to Hello'), findsOneWidget);
  });

  testWidgets(
    'a song that was liked long ago and not heard is a forgotten favourite',
    (tester) async {
      await openHome(
        tester,
        prepare: (b) {
          b.recentSongs = [heard(old, days: 90), heard(anna)];
          b.likedSongs = [old];
        },
      );
      await tester.scrollUntilVisible(
        find.text('Forgotten favorites'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(RefreshIndicator),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Forgotten favorites'), findsOneWidget);
    },
  );

  testWidgets('a touch on a song plays it in place of the queue', (
    tester,
  ) async {
    final backend = await openHome(
      tester,
      prepare: (b) => b.recentSongs = [heard(anna), heard(beck)],
    );
    await tester.tap(find.text('Loser'));
    await tester.pump();
    expect(
      backend.calls,
      containsAllInOrder([
        'clear',
        'addMany ${beck.videoId} next=false',
        'radio ${beck.videoId}',
      ]),
    );
  });

  testWidgets('in a room a touch puts the song on the queue instead', (
    tester,
  ) async {
    final backend = await openHome(
      tester,
      inRoom: true,
      prepare: (b) => b.recentSongs = [heard(anna)],
    );
    await tester.tap(find.text('Hello'));
    await tester.pump();
    expect(backend.calls, isNot(contains('clear')));
    expect(backend.calls.where((c) => c.startsWith('radio')), isEmpty);
    expect(backend.calls, contains('add ${anna.videoId} next=false'));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a mix starts from the radio of its best song', (tester) async {
    final backend = await openHome(
      tester,
      prepare: (b) {
        b.recentSongs = [heard(anna, plays: 5), heard(beck)];
        b.radioResult = SongRadio(
          tracks: [
            MusicTrack(
              videoId: anna.videoId,
              title: 'Hello',
              artist: 'Adele',
              durMs: 1000,
            ),
            MusicTrack(
              videoId: 'r1aaaaaaaaa',
              title: 'Radio One',
              artist: 'X',
              durMs: 1000,
            ),
          ],
        );
      },
    );
    await tester.tap(find.text('Adele Mix'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.calls, contains('musicNext ${anna.videoId}'));
    expect(
      backend.calls,
      containsAllInOrder([
        'clear',
        'addMany ${anna.videoId},r1aaaaaaaaa next=false',
      ]),
    );
  });

  testWidgets(
    'a mix falls back to its song when YouTube Music cannot be reached',
    (tester) async {
      final backend = await openHome(
        tester,
        prepare: (b) => b.recentSongs = [heard(anna, plays: 5), heard(beck)],
      );
      backend.musicFailWith = StateError('offline');
      await tester.tap(find.text('Adele Mix'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Couldn’t start the mix'), findsOneWidget);
      expect(
        backend.calls,
        containsAllInOrder(['clear', 'addMany ${anna.videoId} next=false']),
      );
    },
  );

  testWidgets('the gear opens the settings', (tester) async {
    await openHome(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Your music starts here'), findsOneWidget);
  });

  testWidgets('a trending playlist opens with its songs', (tester) async {
    final backend = await openHome(
      tester,
      prepare: (b) {
        b.trendingResult = [
          MusicShelf(
            title: 'Featured',
            playlists: [Release(id: 'PLabc', title: 'Chill Mix')],
          ),
        ];
        b.lookupResult = LinkResult(
          playlistTitle: 'Chill Mix',
          tracks: [song('pl1aaaaaaaa', 'Calm Song', 'Zen')],
        );
      },
    );
    await tester.tap(find.text('Chill Mix'));
    await tester.pumpAndSettle();
    expect(
      backend.calls,
      contains('lookup https://www.youtube.com/playlist?list=PLabc'),
    );
    expect(find.text('Calm Song'), findsOneWidget);
  });

  testWidgets('a touch on a song of a playlist plays from that song on', (
    tester,
  ) async {
    final backend = await openHome(
      tester,
      prepare: (b) {
        b.trendingResult = [
          MusicShelf(
            title: 'Featured',
            playlists: [Release(id: 'PLabc', title: 'Chill Mix')],
          ),
        ];
        b.lookupResult = LinkResult(
          playlistTitle: 'Chill Mix',
          tracks: [
            song('pl1aaaaaaaa', 'Calm Song', 'Zen'),
            song('pl2aaaaaaaa', 'Quiet Song', 'Zen'),
          ],
        );
      },
    );
    await tester.tap(find.text('Chill Mix'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quiet Song'));
    await tester.pump();
    expect(
      backend.calls,
      containsAllInOrder(['clear', 'addMany pl2aaaaaaaa next=false']),
    );
    await tester.pumpAndSettle();
  });
}
