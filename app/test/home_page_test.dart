import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

Track song(String id, String title, String artist) =>
    Track(videoId: id, title: title, artist: artist, durMs: 200000);

MusicTrack musicSong(String id, String title, String artist) =>
    MusicTrack(videoId: id, title: title, artist: artist, durMs: 200000);

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
  Map<String, Object> prefs = const {},
}) async {
  final (backend, _) = await pumpApp(tester, listen: false, prefs: prefs);
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
    // The mix of the artist heard most is the card at the top
    expect(find.text('Adele Mix'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Because you listened to Hello'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(RefreshIndicator),
            matching: find.byType(Scrollable),
          )
          .first,
    );
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

  testWidgets('the value of a setting sits against the right edge of its row', (
    tester,
  ) async {
    await openHome(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('settings-appearance'));
    final value = find.descendant(of: row, matching: find.text('Light'));
    final chevron = find.descendant(
      of: row,
      matching: find.byIcon(Icons.chevron_right_rounded),
    );
    // The arrow is against the edge of the row (16 points of padding), the words next to it
    expect(
      tester.getTopRight(chevron).dx,
      closeTo(tester.getTopRight(row).dx - 16, 1),
    );
    expect(
      tester.getTopRight(value).dx,
      closeTo(tester.getTopLeft(chevron).dx - 10, 1),
    );
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
        b.collectionResult = CollectionPage(
          id: 'PLabc',
          title: 'Chill Mix',
          kind: 'Playlist',
          tracks: [musicSong('pl1aaaaaaaa', 'Calm Song', 'Zen')],
        );
      },
    );
    await tester.tap(find.text('Chill Mix'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('musicCollection PLabc'));
    expect(find.text('Calm Song'), findsOneWidget);
  });

  group('a playlist opens inside the tab', () {
    Future<void> openChillMix(WidgetTester tester) async {
      await openHome(
        tester,
        prepare: (b) {
          b.trendingResult = [
            MusicShelf(
              title: 'Featured',
              playlists: [Release(id: 'PLabc', title: 'Chill Mix')],
            ),
          ];
          b.collectionResult = CollectionPage(
            id: 'PLabc',
            title: 'Chill Mix',
            kind: 'Playlist',
            tracks: [musicSong('pl1aaaaaaaa', 'Calm Song', 'Zen')],
          );
        },
      );
      await tester.tap(find.text('Chill Mix'));
      await tester.pumpAndSettle();
      expect(find.text('Calm Song'), findsOneWidget);
    }

    testWidgets('the tab bar is still there to move on', (tester) async {
      await openChillMix(tester);
      // The tab bar is drawn over the page, so its labels are found, and a touch on one leaves the page
      expect(find.text('Library'), findsOneWidget);
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      expect(find.text('Calm Song'), findsNothing);
      // The page waits in its tab: coming back finds it where it was
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.text('Calm Song'), findsOneWidget);
    });

    testWidgets('touching the tab that is open goes back to its first page', (
      tester,
    ) async {
      await openChillMix(tester);
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.text('Calm Song'), findsNothing);
      expect(find.text('Chill Mix'), findsOneWidget);
    });

    testWidgets('Back closes the page and not the app', (tester) async {
      await openChillMix(tester);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Calm Song'), findsNothing);
      expect(find.text('Chill Mix'), findsOneWidget);
    });
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
        b.collectionResult = CollectionPage(
          id: 'PLabc',
          title: 'Chill Mix',
          kind: 'Playlist',
          tracks: [
            musicSong('pl1aaaaaaaa', 'Calm Song', 'Zen'),
            musicSong('pl2aaaaaaaa', 'Quiet Song', 'Zen'),
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

  testWidgets('the new shelves show, a held song can be refused and let back', (
    tester,
  ) async {
    final backend = await openHome(
      tester,
      prepare: (b) {
        b.forYouSongs = [beck];
        b.discoverSongs = [anna];
        b.contextMixResult = ContextMix(bucket: 'evening', tracks: [old]);
      },
    );
    expect(find.text('Try something new'), findsOneWidget);
    expect(find.text('Your evening mix'), findsOneWidget);

    await tester.longPress(find.text('Hello'));
    await tester.pumpAndSettle();
    expect(find.text('Don’t suggest this song'), findsOneWidget);
    expect(find.text('Don’t suggest Adele'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('not-interested-artist')));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('block artist Adele'));
    expect(find.text('Got it, we won’t suggest that again'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-suggestions')));
    await tester.pumpAndSettle();
    expect(find.text('Adele'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('blocked-artist-adele')));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('unblock artist adele'));
    expect(find.textContaining('Nothing here'), findsOneWidget);
  });

  group('the Room chip', () {
    final recent = {
      'recent_rooms': jsonEncode([
        {
          'code': 'XYZ234',
          'name': 'Home',
          'at': DateTime.now().millisecondsSinceEpoch,
        },
      ]),
    };

    testWidgets(
      'says Room, and opens the sheet, when there is nothing to go back to',
      (tester) async {
        await openHome(tester);
        expect(find.text(S.tabRoom), findsOneWidget);
        await tester.tap(find.text(S.tabRoom));
        await tester.pumpAndSettle();
        expect(find.text(S.listenTogether), findsOneWidget);
      },
    );

    testWidgets(
      'says Rejoin, and a touch goes straight back into the last room',
      (tester) async {
        final backend = await openHome(tester, prefs: recent);
        // Opening the app does not go into a room by itself
        expect(backend.calls.where((c) => c.startsWith('join')), isEmpty);
        expect(find.text(S.rejoinChip), findsOneWidget);
        await tester.tap(find.text(S.rejoinChip));
        await tester.pumpAndSettle();
        expect(backend.calls, contains(startsWith('join XYZ234 ')));
        // No sheet in between
        expect(find.text(S.listenTogether), findsNothing);
      },
    );

    testWidgets('holding it opens the list of rooms instead', (tester) async {
      final backend = await openHome(tester, prefs: recent);
      await tester.longPress(find.text(S.rejoinChip));
      await tester.pumpAndSettle();
      expect(find.text(S.recentRooms), findsOneWidget);
      expect(backend.calls.where((c) => c.startsWith('join')), isEmpty);
    });

    testWidgets('shows the code while in a room, and a touch opens the room', (
      tester,
    ) async {
      await openHome(tester, inRoom: true, prefs: recent);
      expect(find.text('ABC234'), findsOneWidget);
      expect(find.text(S.rejoinChip), findsNothing);
      await tester.tap(find.text('ABC234'));
      await tester.pumpAndSettle();
      expect(find.text(S.listenTogether), findsNothing);
      expect(find.text(S.leaveRoom), findsOneWidget);
    });
  });
}
