import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_settings.dart';
import '../data/calm.dart';
import '../data/models.dart';
import '../data/room_controller.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'player/apple_music_player.dart';
import 'player/classic_player.dart';
import 'player/look.dart';
import 'player/parts.dart';
import 'player/spotify_player.dart';
import 'player_sheet.dart';
import 'scope.dart';
import 'tv/tv.dart';
import 'tv/tv_player.dart';
import 'widgets/flat_backdrop.dart';
import 'widgets/player_backdrop.dart';
import 'widgets/reactions.dart';

/// The full player. [docked] is the one that stands beside the pages of a window wider than it is tall, a card of its
/// own: it is always there, so it has no handle to pull it down and no way out, and it is laid out for its own size.
class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key, this.docked = false, this.bottomInset = 0});

  final bool docked;

  /// For the docked card: how far up the system's bar comes into it, when the card stands lower than the bar's top (it
  /// is to be as far from the edge of the window as it is at the top). What is in the card keeps above it.
  final double bottomInset;

  /// Dark theme kept for the full-cover player while the app is in the light theme, built again only when the accent
  /// or effects level changes so `_BodyState._onCoverTheme` keeps its cached copy.
  static Color? _darkAccent;
  static EffectsLevel? _darkEffects;
  static ThemeData? _darkTheme;

  static ThemeData _darkFor(Color? accent, EffectsLevel effects) {
    if (_darkTheme != null &&
        _darkAccent == accent &&
        _darkEffects == effects) {
      return _darkTheme!;
    }
    _darkAccent = accent;
    _darkEffects = effects;
    return _darkTheme = buildTheme(
      Palette.forAccent(accent, Brightness.dark),
      effects: effects,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return ListenableBuilder(
      // The style has a notifier of its own (the accent, which the dark theme of the full cover is made in, is in the settings)
      listenable: Listenable.merge([
        settings,
        settings.playerStyleListenable,
        Calm.level,
      ]),
      builder: (context, _) {
        final style = settings.playerStyle;
        final appTheme = Theme.of(context);
        // Full cover always uses white text and controls on the deep colours of the cover, as Apple Music does: dark
        // covers stay deep and the title over the cover's foot always reads clearly even in the light theme
        final forceDark = style == PlayerStyle.appleMusic;
        final appDark = appTheme.brightness == Brightness.dark;
        final dark = appDark || forceDark;
        // Icons in the status bar and the navigation bar: light on a dark player, dark on a light one
        final icons = dark ? Brightness.light : Brightness.dark;
        Widget page = _PlayerPage(
          style: style,
          appTheme: appTheme,
          docked: docked,
          bottomInset: docked ? bottomInset : 0,
        );
        if (forceDark && !appDark) {
          page = Theme(
            data: _darkFor(settings.accent, Calm.level.value),
            child: page,
          );
        }
        // Beside the pages the status bar is theirs
        if (docked) return page;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarBrightness: dark ? Brightness.dark : Brightness.light,
            statusBarIconBrightness: icons,
            systemNavigationBarIconBrightness: icons,
          ),
          child: page,
        );
      },
    );
  }
}

class _PlayerPage extends StatelessWidget {
  const _PlayerPage({
    required this.style,
    required this.appTheme,
    required this.docked,
    this.bottomInset = 0,
  });

  final PlayerStyle style;
  final ThemeData appTheme;
  final bool docked;
  final double bottomInset;

  /// The corners of the card the docked player is.
  static const cardRadius = 26.0;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    final sheet = PlayerSheetScope.of(context);
    final body = ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final current = controller.snapshot.current;
        if (current == null) {
          // The queue emptied while the sheet was open
          if (!docked) {
            WidgetsBinding.instance.addPostFrameCallback((_) => sheet.close());
          }
          return const SizedBox.shrink();
        }
        return _Body(
          controller: controller,
          current: current,
          style: style,
          appTheme: appTheme,
          docked: docked,
        );
      },
    );
    if (docked) {
      // A card of its own size: what is inside it reads that size, with no notch or bar of the window's, but the one
      // that is under the foot of it
      return LayoutBuilder(
        builder: (context, box) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: box.biggest,
            padding: EdgeInsets.only(bottom: bottomInset),
            viewPadding: EdgeInsets.only(bottom: bottomInset),
            viewInsets: EdgeInsets.zero,
          ),
          child: Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius),
            ),
            child: body,
          ),
        ),
      );
    }
    return PlayerPull(
      child: KeyedSubtree(
        key: sheet.pageRoot,
        child: Scaffold(body: body),
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body({
    required this.controller,
    required this.current,
    required this.style,
    required this.appTheme,
    required this.docked,
  });

  final RoomController controller;
  final QueueEntry current;
  final PlayerStyle style;

  /// The theme of the app outside the player, for the sheets and dialogs opened from it ([_PopupTheme]).
  final ThemeData appTheme;
  final bool docked;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  RoomController get _c => widget.controller;

  ThemeData? _baseTheme;
  ThemeData? _coverTheme;

  /// The theme of the app with the quiet colours made for what is on a cover. Made again only when the app's own
  /// theme changes: a new one at every build would make everything under it build again.
  ThemeData _onCoverTheme(BuildContext context) {
    final base = Theme.of(context);
    if (!identical(base, _baseTheme)) {
      _baseTheme = base;
      _coverTheme = base.copyWith(
        extensions: [SapocheTheme(context.palette.onCover, flat: context.flat)],
      );
    }
    return _coverTheme!;
  }

  /// A second touch on the button of the panel that is open goes back to the cover. The panel is the sheet's, so that it
  /// stays through the turning of the phone, when the player is a sheet and then a card beside the pages.
  void _show(NowPlayingPanel panel) {
    final shown = PlayerSheetScope.of(context).panel;
    shown.value = shown.value == panel ? NowPlayingPanel.cover : panel;
  }

  void _choose(NowPlayingPanel panel) =>
      PlayerSheetScope.of(context).panel.value = panel;

  @override
  Widget build(BuildContext context) {
    final look = PlayerLook.of(widget.style);
    final docked = widget.docked;
    final shown = PlayerSheetScope.of(context).panel;
    // The full cover runs up under the status bar, whose icons are then on the picture: light ones
    final bleed =
        widget.style == PlayerStyle.appleMusic &&
        !docked &&
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final tv = TvScope.of(context);
    Widget player(NowPlayingPanel panel) => tv
        ? TvPlayer(
            controller: _c,
            current: widget.current,
            panel: panel,
            onPanel: _show,
            onChoose: _choose,
          )
        : switch (widget.style) {
      PlayerStyle.classic => ClassicPlayer(
        controller: _c,
        current: widget.current,
        panel: panel,
        onPanel: _show,
        onChoose: _choose,
      ),
      PlayerStyle.spotify => SpotifyPlayer(
        controller: _c,
        current: widget.current,
        panel: panel,
        onPanel: _show,
        onChoose: _choose,
      ),
      PlayerStyle.appleMusic => AppleMusicPlayer(
        controller: _c,
        current: widget.current,
        panel: panel,
        onPanel: _show,
        onChoose: _choose,
      ),
    };
    return ValueListenableBuilder<NowPlayingPanel>(
      valueListenable: shown,
      builder: (context, panel, _) => PlayerLookScope(
        look: look,
        onPanel: _choose,
        docked: docked,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The colours drift while the song plays, as Apple Music's do
            if (look.flatBackdrop)
              FlatBackdrop(coverUrl: widget.current.thumb)
            else
              ListenableBuilder(
                listenable: _c.playState,
                builder: (context, _) => PlayerBackdrop(
                  coverUrl: widget.current.thumb,
                  moving: _c.isPlaying,
                  vivid: widget.style == PlayerStyle.appleMusic,
                ),
              ),
            // The safe area keeps the player clear of a notch at the side. Reactions in the room fly up over all of
            // it. What is on the colours of the cover is in the colours made for it (`Palette.onCover`), not in the
            // greys of a plain page
            Theme(
              data: _onCoverTheme(context),
              child: _PopupTheme(
                theme: widget.appTheme,
                child: ReactionShower(
                  controller: _c,
                  child: SafeArea(top: !bleed, child: player(panel)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Gives the sheets and dialogs opened from the player (sleep timer, song menu, members...) the theme of the app, light
/// or dark as it is set: a popup takes the themes around the button that opened it (`InheritedTheme.capture`), and the
/// dark theme of the full cover and the colours made for a cover are the player's, not theirs. Themes the player sets
/// further in, as the video's controls do, still come after this one.
class _PopupTheme extends InheritedTheme {
  const _PopupTheme({required this.theme, required super.child});

  final ThemeData theme;

  @override
  Widget wrap(BuildContext context, Widget child) =>
      Theme(data: theme, child: child);

  @override
  bool updateShouldNotify(_PopupTheme oldWidget) => theme != oldWidget.theme;
}
