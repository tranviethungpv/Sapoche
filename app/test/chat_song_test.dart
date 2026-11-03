import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/chat_extra.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/widgets/chat_song_card.dart';
import 'package:sapoche/ui/widgets/track_tile.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

const song = Track(videoId: 'dQw4w9WgXcQ', title: 'Never Gonna', artist: 'Rick', durMs: 200000);
const other = Track(videoId: 'bNp9pn0ni3I', title: 'Other One', artist: 'Else', durMs: 180000);
const liked = Track(videoId: 'aaaaaaaaaaa', title: 'Liked One', artist: 'L', durMs: 100000);
const heard = Track(videoId: 'bbbbbbbbbbb', title: 'Heard One', artist: 'H', durMs: 100000);
const onPhone = Track(videoId: 'local:42', title: 'On Phone', artist: 'P', durMs: 100000);

QueueEntry entry(String id, Track t) =>
    QueueEntry(id: id, videoId: t.videoId, title: t.title, artist: t.artist, durMs: t.durMs, addedBy: 'b');

/// A room with [queue] in it; [ownerIsB] makes the other member the owner, who limits the guests.
RoomSnapshot room(
  List<QueueEntry> queue, {
  int index = 0,
  String phase = 'paused',
  GuestControl guestControl = GuestControl.all,
  bool ownerIsB = false,
}) => RoomSnapshot(
  room: 'ABC234',
  link: Link.connected,
  you: 'me',
  phase: phase,
  index: index,
  queue: queue,
  guestControl: guestControl,
  ownerId: ownerIsB ? 'b' : null,
  members: [
    const Member(id: 'me', name: 'Anna', ready: true),
    Member(id: 'b', name: 'Binh', ready: true, owner: ownerIsB),
  ],
);

ChatMessage songMessage(int id, SongExtra extra, {String by = 'b', String? text}) => ChatMessage(
  id: id,
  by: by,
  name: by == 'me' ? 'Anna' : 'Binh',
  text: text ?? extra.standIn,
  at: 1790660600000 + id * 1000,
  x: extra.toJson(),
);

ChatEvent history(List<ChatMessage> messages) => ChatEvent(room: 'ABC234', messages: messages, replace: true);

/// The app in [snapshot], whose chat holds [messages]; the chat is open.
Future<(FakeBackend, RoomController)> openChat(
  WidgetTester tester,
  RoomSnapshot snapshot,
  List<ChatMessage> messages, {
  void Function(FakeBackend backend)? prepare,
}) async {
  final (backend, controller) = await pumpApp(tester, prepare: prepare);
  backend.emit(StateEvent(snapshot));
  backend.emit(history(messages));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip(S.chat));
  await tester.pumpAndSettle();
  return (backend, controller);
}

Finder get card => find.byKey(const ValueKey('song-card'));
Finder get play => find.byKey(const ValueKey('song-card-play'));
Finder get add => find.byKey(const ValueKey('song-card-add'));
Finder get playing => find.byKey(const ValueKey('song-card-playing'));

void main() {
  final extra = SongExtra.fromTrack(song);

  group('a song in the chat', () {
    testWidgets('is drawn as a card with the song, not as the words that stand in for it', (tester) async {
      await openChat(tester, room([entry('q0', other)]), [songMessage(1, extra)]);
      expect(card, findsOneWidget);
      expect(find.text('Never Gonna'), findsOneWidget);
      expect(find.text('Rick · 3:20'), findsOneWidget);
      expect(find.textContaining('music.youtube.com'), findsNothing);
      expect(find.byKey(const ValueKey('song-card-like')), findsOneWidget);
      // 62 per cent of the screen, but not wider than 224 dp (540 dp in the test)
      expect(tester.getSize(card).width, closeTo(ChatSongCard.maxWidth, 1));
      expect(find.byKey(const ValueKey('song-card-record')), findsOneWidget);
    });

    testWidgets('the buttons do what they say', (tester) async {
      final (backend, _) = await openChat(tester, room([entry('q0', other)]), [songMessage(1, extra)]);
      expect(find.byTooltip(S.chatSongPlayNow), findsOneWidget);
      expect(find.byTooltip(S.addToQueue), findsOneWidget);

      await tester.tap(add);
      await tester.pump();
      expect(backend.calls, contains('add dQw4w9WgXcQ next=false'));

      await tester.tap(find.byKey(const ValueKey('song-card-like')));
      await tester.pump();
      expect(backend.calls, contains('like dQw4w9WgXcQ true'));
      await tester.pump(const Duration(milliseconds: 400));

      // Play now puts the song next, and then jumps to it once the room has it
      await tester.tap(play);
      await tester.pump();
      expect(backend.calls, contains('add dQw4w9WgXcQ next=true'));
      backend.emit(StateEvent(room([entry('q0', other), entry('q1', song)])));
      await tester.pump();
      await tester.pump();
      expect(backend.calls.last, 'jump q1');
    });

    testWidgets('a song that waits in the queue is jumped to, and not added again', (tester) async {
      final (backend, _) = await openChat(tester, room([entry('q0', other), entry('q1', song)]), [
        songMessage(1, extra),
      ]);
      expect(find.byTooltip(S.chatSongQueued), findsOneWidget);
      await tester.tap(add);
      await tester.pump();
      expect(backend.calls.where((c) => c.startsWith('add')), isEmpty);

      await tester.tap(play);
      await tester.pump();
      expect(backend.calls.last, 'jump q1');
      expect(backend.calls.where((c) => c.startsWith('add')), isEmpty);
    });

    testWidgets('the song playing says so, and has nothing to press but the heart', (tester) async {
      await openChat(tester, room([entry('q0', song)]), [songMessage(1, extra)]);
      expect(playing, findsOneWidget);
      expect(find.text(S.chatSongPlaying), findsOneWidget);
      expect(play, findsNothing);
      expect(add, findsNothing);
      expect(find.byKey(const ValueKey('song-card-like')), findsOneWidget);
    });

    testWidgets('a guest who may only add songs is offered only to add', (tester) async {
      final (backend, _) = await openChat(
        tester,
        room([entry('q0', other)], guestControl: GuestControl.add, ownerIsB: true),
        [songMessage(1, extra)],
      );
      expect(play, findsNothing);
      expect(find.byTooltip(S.chatSongPlayNow), findsNothing);
      await tester.tap(add);
      await tester.pump();
      expect(backend.calls, contains('add dQw4w9WgXcQ next=false'));
    });

    testWidgets('opens what is known about the song when the card is touched', (tester) async {
      await openChat(tester, room([entry('q0', other)]), [songMessage(1, extra)]);
      await tester.tap(find.byKey(const ValueKey('song-card-body')));
      await tester.pumpAndSettle();
      expect(find.text(S.infoLength), findsOneWidget);
    });

    testWidgets('keeps the long press menu of a message', (tester) async {
      await openChat(tester, room([entry('q0', other)]), [songMessage(1, extra)]);
      await tester.longPress(find.text('Never Gonna'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-reply')), findsOneWidget);
    });

    testWidgets('a song that is not one of YouTube, or is damaged, shows the words that stand in for it', (
      tester,
    ) async {
      ChatMessage damaged(int id, Map<String, Object?> x, String text) =>
          ChatMessage(id: id, by: 'b', name: 'Binh', text: text, at: 1790660600000 + id * 1000, x: x);
      await openChat(tester, room([entry('q0', other)]), [
        damaged(1, {'k': 'song', 'v': 'local:42', 'ti': 'T'}, 'a file of mine'),
        damaged(2, {'k': 'song', 'ti': 'no id'}, 'no id here'),
        damaged(3, {'k': 'song-of-the-future', 'v': 'dQw4w9WgXcQ'}, 'the future'),
      ]);
      expect(card, findsNothing);
      expect(find.text('a file of mine'), findsOneWidget);
      expect(find.text('no id here'), findsOneWidget);
      expect(find.text('the future'), findsOneWidget);
    });

    testWidgets('a reply with a song keeps its quote above the card', (tester) async {
      final reply = ChatMessage(
        id: 2,
        by: 'b',
        name: 'Binh',
        text: extra.standIn,
        at: 1790660602000,
        x: extra.toJson(),
        reply: const ChatQuote(id: 1, by: 'me', name: 'Anna', text: 'play something'),
      );
      await openChat(tester, room([entry('q0', other)]), [reply]);
      expect(card, findsOneWidget);
      expect(find.text('play something'), findsOneWidget);
    });

    test('the veil keeps white words 4.5 to 1 even on a white cover', () {
      const white = 255.0;
      final shade = white * (1 - 0.58);
      final channel = shade / 255;
      // sRGB to linear for a grey
      final linear = channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4);
      expect(1.05 / (linear + 0.05), greaterThanOrEqualTo(4.5));
    });
  });

  group('sending a song', () {
    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('chat-add-song')));
      await tester.pumpAndSettle();
    }

    Future<(FakeBackend, RoomController)> chat(WidgetTester tester) => openChat(
      tester,
      room([entry('q0', song)]),
      [ChatMessage(id: 1, by: 'b', name: 'Binh', text: 'hello', at: 1790660601000)],
      prepare: (b) {
        b.likedSongs = [liked, onPhone, song];
        b.recentSongs = [
          HistoryEntry(track: heard, at: DateTime(2026, 11, 1)),
          HistoryEntry(track: liked, at: DateTime(2026, 11, 1)),
          HistoryEntry(track: onPhone, at: DateTime(2026, 11, 1)),
        ];
      },
    );

    testWidgets('has a button next to the photos', (tester) async {
      await chat(tester);
      expect(find.byTooltip(S.chatAddSong), findsOneWidget);
      expect(find.byTooltip(S.chatAddPhoto), findsOneWidget);
    });

    testWidgets('the sheet opens on the song playing, the liked and the heard, each once, none from a file', (
      tester,
    ) async {
      await chat(tester);
      await openPicker(tester);
      expect(find.text(S.chatAddSong), findsWidgets);
      expect(
        find.descendant(of: find.byKey(const ValueKey('song-picker-start')), matching: find.text(S.nowPlaying)),
        findsOneWidget,
      );
      expect(find.text(S.likedSongs), findsOneWidget);
      expect(find.text(S.recentlyPlayed), findsOneWidget);
      // The song playing is also liked: it is under "now playing" only
      expect(find.byKey(const ValueKey('song-picker-dQw4w9WgXcQ')), findsOneWidget);
      // Liked and heard: under "liked" only
      expect(find.byKey(const ValueKey('song-picker-aaaaaaaaaaa')), findsOneWidget);
      expect(find.byKey(const ValueKey('song-picker-bbbbbbbbbbb')), findsOneWidget);
      expect(find.text('On Phone'), findsNothing);
    });

    testWidgets('searches as words are typed, and offers only songs of YouTube', (tester) async {
      final (backend, _) = await chat(tester);
      backend.searchResults = [other, onPhone];
      backend.suggestions = ['never gonna give'];
      await openPicker(tester);
      await tester.enterText(find.byKey(const ValueKey('song-picker-field')), 'never');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.calls, contains('search never songs'));
      expect(backend.calls, contains('suggest never'));
      expect(find.text('never gonna give'), findsOneWidget);
      expect(find.text('Other One'), findsOneWidget);
      expect(find.text('On Phone'), findsNothing);

      backend.searchResults = const [];
      await tester.enterText(find.byKey(const ValueKey('song-picker-field')), 'nothing');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(S.chatSongNoResults), findsOneWidget);
    });

    testWidgets('a song picked waits above the field, can be dropped, and goes with an empty field', (tester) async {
      final (backend, _) = await chat(tester);
      await openPicker(tester);
      await tester.tap(find.byKey(const ValueKey('song-picker-aaaaaaaaaaa')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-song-banner')), findsOneWidget);
      expect(find.text('Liked One'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-song-banner-drop')));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-song-banner')), findsNothing);
      // Nothing to send now
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send_rounded)).onPressed, isNull);

      await openPicker(tester);
      await tester.tap(find.byKey(const ValueKey('song-picker-aaaaaaaaaaa')));
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send_rounded)).onPressed, isNotNull);
      await tester.tap(find.byTooltip(S.chatSend));
      await tester.pump();
      expect(find.byKey(const ValueKey('chat-song-banner')), findsNothing);
      expect(backend.lastExtra, SongExtra.fromTrack(liked).toJson());
      expect(backend.calls.where((c) => c.startsWith('sendChat')), [
        'sendChat 🎵 Liked One · L  https://music.youtube.com/watch?v=aaaaaaaaaaa',
      ]);
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('what is written goes after the song, as a message of its own', (tester) async {
      final (backend, _) = await chat(tester);
      await openPicker(tester);
      await tester.tap(find.byKey(const ValueKey('song-picker-bbbbbbbbbbb')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('chat-field')), 'listen to this');
      await tester.pump();
      await tester.tap(find.byTooltip(S.chatSend));
      await tester.pump();
      expect(backend.calls.where((c) => c.startsWith('sendChat')), [
        'sendChat 🎵 Heard One · H  https://music.youtube.com/watch?v=bbbbbbbbbbb',
        'sendChat listen to this',
      ]);
      // The last one sent was the plain words
      expect(backend.lastExtra, isNull);
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('the song answers the message that is being replied to', (tester) async {
      final (backend, _) = await chat(tester);
      await tester.longPress(find.text('hello'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-reply')));
      await tester.pumpAndSettle();
      await openPicker(tester);
      await tester.tap(find.byKey(const ValueKey('song-picker-bbbbbbbbbbb')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chatSend));
      await tester.pump();
      expect(backend.calls.where((c) => c.startsWith('sendChat')).single, endsWith('reply 1'));
      expect(backend.lastQuote?.text, 'hello');
      expect(find.byKey(const ValueKey('chat-reply-banner')), findsNothing);
      await tester.pump(const Duration(seconds: 40));
    });
  });

  group('"send to room chat" in the menu of a song', () {
    Future<(FakeBackend, RoomController)> search(WidgetTester tester, {bool inRoom = true, bool chat = true}) async {
      final (backend, controller) = await pumpApp(tester);
      backend.emit(inRoom ? StateEvent(room([entry('q0', other)])) : const StateEvent(RoomSnapshot()));
      if (inRoom && chat) backend.emit(history([]));
      backend.searchResults = const [Track(videoId: 'aaaaaaaaaaa', title: 'Found', artist: 'x', durMs: 1000)];
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'found');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.descendant(of: find.widgetWithText(TrackTile, 'Found'), matching: find.byIcon(Icons.more_horiz_rounded)),
      );
      await tester.pumpAndSettle();
      return (backend, controller);
    }

    testWidgets('sends the song at once and says so', (tester) async {
      final (backend, _) = await search(tester);
      expect(find.text(S.songSendToChat), findsOneWidget);
      await tester.tap(find.text(S.songSendToChat));
      await tester.pump();
      expect(backend.calls.last, 'sendChat 🎵 Found · x  https://music.youtube.com/watch?v=aaaaaaaaaaa');
      expect(backend.lastExtra?['k'], 'song');
      expect(backend.lastExtra?['v'], 'aaaaaaaaaaa');
      expect(find.text(S.songSentToChat), findsOneWidget);
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('is not there in a room that has no chat', (tester) async {
      await search(tester, chat: false);
      expect(find.text(S.songSendToChat), findsNothing);
      expect(find.text(S.playNext), findsOneWidget);
    });

    testWidgets('is not there outside a room', (tester) async {
      await search(tester, inRoom: false);
      expect(find.text(S.songSendToChat), findsNothing);
      expect(find.text(S.playNext), findsOneWidget);
    });
  });

  group('the words that stand in for a song', () {
    test('are the song and a link, and the id is checked', () {
      expect(extra.standIn, '🎵 Never Gonna · Rick  https://music.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(SongExtra.isVideoId('dQw4w9WgXcQ'), isTrue);
      expect(SongExtra.isVideoId('local:42'), isFalse);
      expect(SongExtra.isVideoId('video0'), isFalse);
      expect(SongExtra.isVideoId('dQw4w9WgXcQ0'), isFalse);
    });

    test('a long title is cut so the message stays within what the chat takes', () {
      final long = SongExtra(videoId: 'dQw4w9WgXcQ', title: 'T' * 600, artist: 'A' * 600, durMs: 1);
      expect(long.standIn.characters.length, lessThan(400));
    });

    test('a cover that is not an address on the internet is dropped, and an id that is no video\'s is refused', () {
      final read = SongExtra.fromJson({'k': 'song', 'v': 'dQw4w9WgXcQ', 'ti': 'T', 'art': 'file:///etc/passwd'});
      expect(read.art, isNull);
      expect(
        SongExtra.fromJson({'k': 'song', 'v': 'dQw4w9WgXcQ', 'art': 'https://i.ytimg.com/x'}).art,
        'https://i.ytimg.com/x',
      );
      expect(() => SongExtra.fromJson({'k': 'song', 'v': 'local:42'}), throwsFormatException);
    });
  });
}
