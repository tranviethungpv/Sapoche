import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/tv_mode.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/chat_sheet.dart';
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/members_sheet.dart';
import 'package:sapoche/ui/starter_artists_sheet.dart';
import 'package:sapoche/ui/chat_theme_sheet.dart';
import 'package:sapoche/ui/sleep_sheet.dart';
import 'package:sapoche/ui/profile_sheet.dart';
import 'package:sapoche/ui/scope.dart';
import 'package:sapoche/data/room_controller.dart';
import 'package:sapoche/ui/rooms_sheet.dart';
import 'package:sapoche/ui/player/parts.dart';
import 'package:sapoche/ui/player_sheet.dart';
import 'package:sapoche/ui/tv/tv_player.dart';

import 'fake_backend.dart';
import 'landscape_test.dart' show resize;
import 'pump_app.dart';

/// Opens the app on a TV of [width] x [height] dp (a screen of 1080p is 1920x1080 at the density of 1) with a song playing.
Future<FakeBackend> pumpTv(
  WidgetTester tester, {
  double width = 1920,
  double height = 1080,
  PlayerStyle style = PlayerStyle.classic,
  bool video = false,
}) async {
  final (backend, _) = await pumpApp(
    tester,
    listen: false,
    prefs: {'tv_mode': 'on', 'player_style': style.name},
  );
  addTearDown(() {
    Tv.mode = TvMode.auto;
    Tv.device = false;
  });
  backend.emit(StateEvent(sampleRoom(video: video)));
  backend.emit(
    const PositionEvent(
      PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000),
    ),
  );
  await resize(tester, width, height);
  await tester.pump(const Duration(milliseconds: 600));
  return backend;
}

Rect? focused() => FocusManager.instance.primaryFocus?.rect;

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  focusReach();
  group('the app on a TV', () {
    for (final (width, height) in [
      (1920.0, 1080.0),
      (1280.0, 720.0),
      (960.0, 540.0),
    ]) {
      testWidgets('${width}x$height is drawn on a canvas of 540 dp', (
        tester,
      ) async {
        await pumpTv(tester, width: width, height: height);
        final context = tester.element(find.byType(HomeShell));
        expect(MediaQuery.sizeOf(context).height, 540);
        expect(HomeShell.layoutOf(context), ShellLayout.rail);
        expect(HomeShell.isDocked(context), isFalse);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a phone is not drawn as a TV', (tester) async {
      final (backend, _) = await pumpApp(tester, listen: false);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pump(const Duration(milliseconds: 400));
      final context = tester.element(find.byType(HomeShell));
      expect(MediaQuery.sizeOf(context).height, greaterThan(540));
      expect(HomeShell.isTv(context), isFalse);
    });

    testWidgets('the device says it is a TV and the app follows', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester, listen: false);
      addTearDown(() => Tv.device = false);
      backend.emit(StateEvent(sampleRoom(television: true)));
      await resize(tester, 1920, 1080);
      await tester.pump(const Duration(milliseconds: 400));
      final context = tester.element(find.byType(HomeShell));
      expect(HomeShell.isTv(context), isTrue);
      expect(MediaQuery.sizeOf(context).height, 540);
    });

    testWidgets('the tabs open to their names while the focus is in them', (
      tester,
    ) async {
      await pumpTv(tester);
      expect(find.text(S.tabLibrary), findsNothing, reason: 'closed: icons');
      await press(tester, LogicalKeyboardKey.arrowDown);
      var tries = 0;
      while (focused()!.left > 100 && tries++ < 30) {
        await press(tester, LogicalKeyboardKey.arrowLeft);
      }
      expect(focused()!.left, lessThan(100), reason: 'in the rail');
      expect(find.text(S.tabLibrary), findsOneWidget, reason: 'open: names');
      // Back to the page: it closes again
      await press(tester, LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(S.tabLibrary), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the player on a TV', () {
    for (final style in PlayerStyle.values) {
      for (final video in [false, true]) {
        testWidgets('$style${video ? ' as video' : ''} fills the screen', (
          tester,
        ) async {
          await pumpTv(tester, style: style, video: video);
          PlayerSheetScope.of(tester.element(find.byType(PlayerSheetScope)))
              .open();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byType(TvPlayer), findsOneWidget);
          expect(tester.takeException(), isNull);
          // The cover is large: not the few dp the card beside the pages left it
          if (!video && style != PlayerStyle.appleMusic) {
            final cover = tester.getSize(find.byType(PlayerCoverArt).last);
            expect(cover.shortestSide, greaterThanOrEqualTo(300));
          }
        });
      }

      testWidgets(
        '$style: OK on the last icon opens a panel and keeps the focus on the icons',
        (tester) async {
          await pumpTv(tester, style: style);
          PlayerSheetScope.of(tester.element(find.byType(PlayerSheetScope)))
              .open();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 600));
          // The queue is the last icon of the row
          final icons = [
            for (final node in FocusManager.instance.rootScope.descendants)
              if (node is! FocusScopeNode &&
                  node.canRequestFocus &&
                  node.context
                          ?.findAncestorWidgetOfExactType<PlayerToolbar>() !=
                      null)
                node,
          ]..sort((a, b) => a.rect.left.compareTo(b.rect.left));
          icons.last.requestFocus();
          await tester.pump();
          await press(tester, LogicalKeyboardKey.select);
          await tester.pump(const Duration(milliseconds: 600));
          final node = FocusManager.instance.primaryFocus;
          expect(node, isNotNull);
          expect(
            node!.context!.findAncestorWidgetOfExactType<PlayerToolbar>(),
            isNotNull,
            reason: 'the focus did not go with the icons to the new place',
          );
          final sheet = PlayerSheetScope.of(
            tester.element(find.byType(PlayerSheetScope)),
          );
          // Only the icons of this style open a panel from the last place
          if (style == PlayerStyle.appleMusic) {
            expect(sheet.panel.value, isNot(NowPlayingPanel.cover));
          }
        },
      );

      testWidgets(
        '$style: a video leaves its picture alone, and a key brings the buttons back',
        (tester) async {
          await pumpTv(tester, style: style, video: true);
          PlayerSheetScope.of(tester.element(find.byType(PlayerSheetScope)))
              .open();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 600));
          double shown() => tester
              .widget<AnimatedOpacity>(
                find
                    .ancestor(
                      of: find.byType(TransportRow),
                      matching: find.byType(AnimatedOpacity),
                    )
                    .last,
              )
              .opacity;
          expect(shown(), 1);
          await tester.pump(const Duration(seconds: 6));
          await tester.pump(const Duration(milliseconds: 400));
          expect(shown(), 0, reason: 'five seconds with no key');
          await press(tester, LogicalKeyboardKey.arrowRight);
          await tester.pump(const Duration(milliseconds: 400));
          expect(shown(), 1, reason: 'a key');
          expect(
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<TransportRow>(),
            isNotNull,
            reason: 'the focus is on the buttons again',
          );
        },
      );

      for (final panel in [
        NowPlayingPanel.lyrics,
        NowPlayingPanel.upNext,
        NowPlayingPanel.comments,
      ]) {
        testWidgets('$style with ${panel.name} open', (tester) async {
          await pumpTv(tester, style: style);
          final sheet = PlayerSheetScope.of(
            tester.element(find.byType(PlayerSheetScope)),
          );
          sheet.open();
          sheet.panel.value = panel;
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(TvPlayer), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}

/// Every control that can have the focus and is on the screen, and which of them the four arrows reach in a long walk
/// (the same one every time): what is not reached is a control a remote cannot use. The walk is by keys only: a control
/// the focus is put on from outside would not tell what the arrows do from where they are.
Future<List<String>> unreachable(
  WidgetTester tester, {
  bool Function(FocusNode node)? only,
}) async {
  final window =
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  final everything = [
    for (final node in FocusManager.instance.rootScope.descendants)
      if (node is! FocusScopeNode &&
          node.canRequestFocus &&
          !node.skipTraversal &&
          (node.context?.mounted ?? false) &&
          // Under a page that another covers, the arrows do not go
          !node.ancestors.any(
            (a) =>
                a is FocusScopeNode &&
                a.skipTraversal &&
                (a.debugLabel?.contains('_ModalScopeState') ?? false),
          ) &&
          node.rect.width > 0 &&
          (only?.call(node) ?? true) &&
          window.overlaps(node.rect))
        node,
  ];
  final seen = <FocusNode>{};
  final random = Random(7);
  const keys = [
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowUp,
  ];
  // Where the focus is as the walk begins (a page that has just opened puts it on its first control) is seen too
  final first = FocusManager.instance.primaryFocus;
  if (first != null) seen.add(first);
  await press(tester, LogicalKeyboardKey.arrowDown);
  for (var i = 0; i < 2000 && !everything.every(seen.contains); i++) {
    final node = FocusManager.instance.primaryFocus;
    if (node != null) seen.add(node);
    await tester.sendKeyEvent(keys[random.nextInt(keys.length)]);
    await tester.pump(const Duration(milliseconds: 30));
  }
  // What the walk did not happen to come to, tried on purpose: the arrow that points at it from where the focus is
  for (final target in everything) {
    if (seen.contains(target) || !(target.context?.mounted ?? false)) continue;
    for (var i = 0; i < 160 && !seen.contains(target); i++) {
      final node = FocusManager.instance.primaryFocus;
      if (node == null || node is FocusScopeNode) break;
      seen.add(node);
      final d = target.rect.center - node.rect.center;
      final key = d.dx.abs() >= d.dy.abs()
          ? (d.dx > 0
                ? LogicalKeyboardKey.arrowRight
                : LogicalKeyboardKey.arrowLeft)
          : (d.dy > 0
                ? LogicalKeyboardKey.arrowDown
                : LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(key);
      await tester.pump(const Duration(milliseconds: 30));
      final now = FocusManager.instance.primaryFocus;
      if (now != null) seen.add(now);
    }
  }
  // A long list takes the down arrow row by row, and what is below it (the player at the foot) is reached only at its end
  for (final target in everything) {
    if (seen.contains(target) || !(target.context?.mounted ?? false)) continue;
    for (var i = 0; i < 150 && !seen.contains(target); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 30));
      final now = FocusManager.instance.primaryFocus;
      if (now != null) seen.add(now);
    }
    for (var i = 0; i < 4 && !seen.contains(target); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 30));
      final now = FocusManager.instance.primaryFocus;
      if (now != null) seen.add(now);
    }
  }
  // A seek that the walk made has its timer to run out
  await tester.pump(const Duration(seconds: 2));
  return [
    for (final node in everything)
      // A control that went away during the walk (a page that closed) is not one that could not be reached
      if (!seen.contains(node) && (node.context?.mounted ?? false))
        '${node.debugLabel ?? node.context?.widget.runtimeType} ${node.rect} ${_words(node)} < ${_chain(node)}',
  ];
}

void focusReach() {
  group('a remote reaches every control', () {
    testWidgets('on Home', (tester) async {
      await pumpTv(tester);
      expect(await unreachable(tester), isEmpty);
    });

    for (final (name, icon) in [
      ('Search', Icons.search_rounded),
      ('Library', Icons.library_music_rounded),
      ('Listen', Icons.graphic_eq_rounded),
      ('Settings', Icons.settings_outlined),
    ]) {
      testWidgets('on $name', (tester) async {
        await pumpTv(tester);
        await tester.tap(find.byIcon(icon).first);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        expect(await unreachable(tester), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('in the sheet of the room', (tester) async {
      await pumpTv(tester);
      showRoomSheet(tester.element(find.byType(HomeShell)));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(await unreachable(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    // The other sheets that a person is taken to: each is opened and walked
    final sheets =
        <(String, Future<void> Function(BuildContext, RoomController))>[
          ('the profile', (c, r) => showProfileSheet(c)),
          ('the sleep timer', (c, r) => showSleepSheet(c, r)),
          ('the look of the chat', (c, r) => showChatThemeSheet(c, r)),
          ('the first artists', (c, r) => showStarterArtists(c)),
          ('the members', (c, r) async => showMembersSheet(c)),
        ];
    for (final (name, open) in sheets) {
      testWidgets('in the sheet of $name', (tester) async {
        await pumpTv(tester);
        final context = tester.element(find.byType(HomeShell));
        unawaited(open(context, AppScope.roomOf(context)));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        expect(Navigator.of(context, rootNavigator: true).canPop(), isTrue);
        expect(await unreachable(tester), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('in the chat', (tester) async {
      await pumpTv(tester);
      unawaited(showChatSheet(tester.element(find.byType(HomeShell))));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('chat-field')), findsOneWidget);
      expect(await unreachable(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('on the full player of each style', (tester) async {
      for (final style in PlayerStyle.values) {
        await pumpTv(tester, style: style);
        PlayerSheetScope.of(tester.element(find.byType(PlayerSheetScope)))
            .open();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        expect(await unreachable(tester), isEmpty, reason: '$style');
      }
    });
  });
}

/// The first words in a control, to tell which one it is.
String _words(FocusNode node) {
  String? found;
  void visit(Element element) {
    if (found != null) return;
    final widget = element.widget;
    if (widget is Text && widget.data != null) {
      found = widget.data;
      return;
    }
    if (widget is Icon && widget.icon != null) {
      found = 'icon ${widget.icon!.codePoint.toRadixString(16)}';
      return;
    }
    element.visitChildren(visit);
  }

  (node.context as Element?)?.visitChildren(visit);
  return found ?? '';
}

/// The widgets around a control, nearest first, to tell where it is in the code.
String _chain(FocusNode node) {
  final names = <String>[];
  node.context?.visitAncestorElements((element) {
    final name = element.widget.runtimeType.toString();
    if (!name.startsWith('_') &&
        !const {'Focus', 'Actions', 'Builder'}.contains(name)) {
      names.add(name);
    }
    return names.length < 8;
  });
  return names.join(' < ');
}
