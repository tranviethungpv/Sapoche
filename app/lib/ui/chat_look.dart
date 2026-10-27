import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/chat_theme.dart';
import '../theme/palette.dart';

/// The colours of the chat for a room's theme, worked out for the light or the dark side of the app.
class ChatLook {
  const ChatLook._({
    required this.mine,
    required this.mineInk,
    required this.theirs,
    required this.backdropEnd,
    required this.accent,
    required this.from,
    required this.to,
    required this.picture,
    required this.light,
  });

  /// The messages of this device.
  final Gradient mine;
  final Color mineInk;

  /// The messages of the others.
  final Color theirs;

  /// The colour the background of the chat fades into at its foot; it starts as the sheet itself.
  final Color backdropEnd;

  /// What is pressed or typed: the send button, the field.
  final Color accent;

  /// The two colours of the theme.
  final Color from;
  final Color to;

  /// The photo behind the chat, which the colours are blended over; null for a chat with colours only.
  final Uint8List? picture;
  final bool light;

  /// The look for the theme named [id] under [palette], or null where the chat keeps the colours of the app.
  static ChatLook? of(String? id, Palette palette, {Uint8List? picture}) {
    final theme = ChatTheme.parse(id);
    if (theme == null) return null;
    final light = palette.brightness == Brightness.light;
    final mixed = Color.lerp(
      Color.lerp(palette.base, theme.from, light ? 0.18 : 0.30),
      theme.to,
      0.3,
    )!;
    return ChatLook._(
      mine: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_carriesWhite(theme.from), _carriesWhite(theme.to)],
      ),
      mineInk: Colors.white,
      // Over a photo they are more solid, or the words would be read against whatever the photo has behind them
      theirs: Color.lerp(
        palette.base,
        theme.from,
        light ? 0.14 : 0.26,
      )!.withValues(alpha: picture == null ? 1 : 0.92),
      backdropEnd: mixed,
      accent: light
          ? _carriesWhite(theme.from)
          : Color.lerp(theme.from, Colors.white, 0.35)!,
      from: theme.from,
      to: theme.to,
      picture: picture,
      light: light,
    );
  }

  /// What is laid over the photo so that it and the colours of the theme become one: the sheet's own colour at the
  /// top, where the header is, thinning out to show the photo, and at the foot the colours of the theme at a strength
  /// that keeps the words readable.
  List<Gradient> veils(Color sheet) => [
    LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        sheet.withValues(alpha: 0.94),
        sheet.withValues(alpha: light ? 0.60 : 0.50),
        Color.lerp(
          sheet,
          from,
          light ? 0.30 : 0.45,
        )!.withValues(alpha: light ? 0.62 : 0.66),
      ],
      stops: const [0, 0.32, 1],
    ),
    // The two colours of the theme across the photo, from corner to corner, softly
    LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        from.withValues(alpha: light ? 0.20 : 0.26),
        to.withValues(alpha: light ? 0.20 : 0.26),
      ],
    ),
  ];

  /// [color], darkened until white words on it can be read (a contrast of 4.5 to 1).
  static Color _carriesWhite(Color color) {
    var c = color;
    for (var i = 0; i < 24 && 1.05 / (c.computeLuminance() + 0.05) < 4.5; i++) {
      c = Color.lerp(c, Colors.black, 0.08)!;
    }
    return c;
  }
}

/// Hands the look of the room's chat to the messages and the field below it.
class ChatLookScope extends InheritedWidget {
  const ChatLookScope({super.key, required this.look, required super.child});

  /// Null where the chat keeps the colours of the app.
  final ChatLook? look;

  static ChatLook? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatLookScope>()?.look;

  @override
  bool updateShouldNotify(ChatLookScope old) => look != old.look;
}

/// The background of the chat: the sheet's colour fading into the theme's, and with a photo the photo under the
/// veils of [ChatLook.veils]. [child] sits on it.
class ChatBackdrop extends StatelessWidget {
  const ChatBackdrop({
    super.key,
    required this.look,
    required this.sheet,
    required this.child,
  });

  /// Null where the chat keeps the colours of the app: then there is no backdrop.
  final ChatLook? look;

  /// The colour of the sheet the chat is in.
  final Color sheet;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final look = this.look;
    if (look == null) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [sheet, look.backdropEnd],
            ),
          ),
        ),
        if (look.picture case final picture?) ...[
          Image.memory(
            picture,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
          for (final veil in look.veils(sheet))
            DecoratedBox(decoration: BoxDecoration(gradient: veil)),
        ],
        child,
      ],
    );
  }
}
