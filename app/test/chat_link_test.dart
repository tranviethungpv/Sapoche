import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/widgets/chat_song_card.dart';
import 'package:sapoche/ui/widgets/linked_text.dart';

import 'fake_backend.dart';
import 'pump_app.dart';

List<String> linksIn(String text) => [for (final (:start, :end) in findLinks(text)) text.substring(start, end)];

void main() {
  group('finding the links in a message', () {
    test('picks out addresses, and leaves the words around them', () {
      expect(linksIn('see https://example.com/a?b=1 now'), ['https://example.com/a?b=1']);
      expect(linksIn('no links here'), isEmpty);
      expect(linksIn('two http://a.io/x and www.b.org'), ['http://a.io/x', 'www.b.org']);
      expect(linksIn('HTTPS://EXAMPLE.COM'), ['HTTPS://EXAMPLE.COM']);
    });

    test('the full stop, comma or bracket after a link is not part of it', () {
      expect(linksIn('look: https://example.com.'), ['https://example.com']);
      expect(linksIn('(https://example.com/a)'), ['https://example.com/a']);
      expect(linksIn('https://example.com, and'), ['https://example.com']);
      expect(linksIn('really? https://example.com/x!'), ['https://example.com/x']);
    });

    test('a bracket that has its pair inside the link stays', () {
      expect(linksIn('https://en.wikipedia.org/wiki/Dart_(language)'), [
        'https://en.wikipedia.org/wiki/Dart_(language)',
      ]);
      expect(linksIn('(https://en.wikipedia.org/wiki/Dart_(language))'), [
        'https://en.wikipedia.org/wiki/Dart_(language)',
      ]);
    });

    test('a scheme with nothing after it is no link', () {
      expect(linksIn('https:// and http://'), isEmpty);
    });
  });

  group('a link to a song of YouTube in the chat', () {
    const link = 'https://youtu.be/dQw4w9WgXcQ';
    const track = Track(videoId: 'dQw4w9WgXcQ', title: 'Never Gonna', artist: 'Rick', durMs: 200000);

    Future<FakeBackend> chatWith(WidgetTester tester, String text, {LinkResult? found}) async {
      final (backend, _) = await pumpApp(tester, prepare: (backend) => backend.lookupResult = found);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(
        ChatEvent(
          room: 'ABC234',
          messages: [ChatMessage(id: 1, by: 'b', name: 'Binh', text: text, at: 1790660600000)],
          replace: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chat));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('alone, it is the song\'s card and the words are gone', (tester) async {
      final backend = await chatWith(tester, link, found: const LinkResult(tracks: [track]));
      expect(find.byKey(const ValueKey('song-link-card')), findsOneWidget);
      expect(find.text('Never Gonna'), findsOneWidget);
      expect(find.text(link), findsNothing);
      expect(backend.calls, contains('lookup $link'));
      // And it plays from the card
      await tester.tap(find.byKey(const ValueKey('song-card-play')));
      await tester.pump();
      expect(backend.calls, contains('add dQw4w9WgXcQ next=true'));
      // The room has four seconds to bring it in before the app gives up waiting
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('once found, the song is known at once, for a message built again to start as the card', (tester) async {
      await chatWith(tester, link, found: const LinkResult(tracks: [track]));
      final controller = tester.widget<ChatSongCard>(find.byKey(const ValueKey('song-link-card'))).controller;
      expect(controller.knownSongOfLink(link)?.videoId, track.videoId);
      expect(controller.knownSongOfLink('https://youtu.be/other'), isNull);
    });

    testWidgets('with words around it, the words stay and the card is under them', (tester) async {
      await chatWith(tester, 'listen to $link now', found: const LinkResult(tracks: [track]));
      expect(find.byKey(const ValueKey('song-link-card')), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'listen to $link now'),
        findsOneWidget,
      );
    });

    testWidgets('a link that cannot be looked up stays as the words', (tester) async {
      await chatWith(tester, link);
      expect(find.byKey(const ValueKey('song-link-card')), findsNothing);
      expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == link), findsOneWidget);
    });

    testWidgets('a playlist is not a song: its link stays as the words', (tester) async {
      await chatWith(
        tester,
        link,
        found: const LinkResult(tracks: [track], playlistTitle: 'Mix'),
      );
      expect(find.byKey(const ValueKey('song-link-card')), findsNothing);
    });

    testWidgets('a link to anything else is not looked up', (tester) async {
      final backend = await chatWith(tester, 'https://example.com/a', found: const LinkResult(tracks: [track]));
      expect(backend.calls.where((c) => c.startsWith('lookup')), isEmpty);
      expect(find.byKey(const ValueKey('song-link-card')), findsNothing);
    });

    testWidgets('one link is looked up once, however often it is drawn', (tester) async {
      final backend = await chatWith(tester, link, found: const LinkResult(tracks: [track]));
      await tester.drag(find.byKey(const ValueKey('song-link-card')), const Offset(0, 0));
      await tester.pump();
      expect(backend.calls.where((c) => c.startsWith('lookup')), hasLength(1));
    });
  });

  group('a link in the chat', () {
    Future<(FakeBackend, List<Uri>)> chatWith(WidgetTester tester, String text, {bool opens = true}) async {
      final opened = <Uri>[];
      LinkedText.launcher = (uri) async {
        opened.add(uri);
        return opens;
      };
      addTearDown(() => LinkedText.launcher = (uri) async => false);
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      backend.emit(
        ChatEvent(
          room: 'ABC234',
          messages: [ChatMessage(id: 1, by: 'b', name: 'Binh', text: text, at: 1790660600000)],
          replace: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(S.chat));
      await tester.pumpAndSettle();
      return (backend, opened);
    }

    /// A touch on the first letters of the link in the message.
    Future<void> touchLink(WidgetTester tester, String whole) async {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == whole),
      );
      final at = whole.indexOf(RegExp('https?://|www'));
      final box = paragraph.getBoxesForSelection(TextSelection(baseOffset: at, extentOffset: at + 6)).first;
      await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
      await tester.pump();
    }

    testWidgets('opens in the browser when touched, and the words around it do nothing', (tester) async {
      const text = 'look https://example.com/page. ok';
      final (_, opened) = await chatWith(tester, text);
      await touchLink(tester, text);
      expect(opened, [Uri.parse('https://example.com/page')]);
    });

    testWidgets('a link that cannot be opened says so', (tester) async {
      const text = 'https://example.com/x';
      await chatWith(tester, text, opens: false);
      await touchLink(tester, text);
      await tester.pump();
      expect(find.text(S.linkCannotOpen), findsOneWidget);
    });

    testWidgets('a link to a song of YouTube opens what the app knows of the song, not the browser', (tester) async {
      const text = 'https://youtu.be/dQw4w9WgXcQ';
      final (backend, opened) = await chatWith(tester, text);
      backend.lookupResult = const LinkResult(
        tracks: [Track(videoId: 'dQw4w9WgXcQ', title: 'Never Gonna', artist: 'Rick', durMs: 200000)],
      );
      await touchLink(tester, text);
      await tester.pumpAndSettle();
      expect(backend.calls, contains('lookup $text'));
      expect(opened, isEmpty);
      expect(find.text(S.infoLength), findsOneWidget);
    });

    testWidgets('a YouTube link that cannot be looked up goes to the browser', (tester) async {
      const text = 'https://youtu.be/dQw4w9WgXcQ';
      final (_, opened) = await chatWith(tester, text);
      await touchLink(tester, text);
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse(text)]);
    });
  });
}
