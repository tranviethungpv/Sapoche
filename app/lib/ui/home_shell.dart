import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'player_sheet.dart';
import 'room_page.dart';
import 'rooms_sheet.dart';
import 'scope.dart';
import 'setup_dialog.dart';
import 'search_page.dart';
import 'widgets/artwork.dart';
import 'widgets/glass.dart';
import 'widgets/mini_player.dart';

/// Tabs plus the floating mini player. Lists scroll behind both bars, which blur them.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Whether the screen is wider than it is tall, where the bars are lower to leave room for the page.
  static bool isWide(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  /// Bottom padding lists need so their last row can scroll clear of the bars.
  static double bottomInsetOf(BuildContext context) =>
      isWide(context) ? 128 : 176;

  /// Height of the capsule of tabs and of the Search button.
  static double tabHeightOf(BuildContext context) => isWide(context) ? 40 : 60;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with TickerProviderStateMixin {
  int _tab = 0;

  /// The last tab of the capsule that was open, where its lens waits while Search is.
  int _browsing = 0;
  late final _sheet = PlayerSheetController(this);

  /// 0 with the bars open, 1 with them folded away while a page is scrolled down, as Apple Music does: the tabs shrink
  /// to the one that is open and the mini player moves down between it and Search.
  late final _folded = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
  );
  bool _isFolded = false;

  /// The two parts of folding: the capsule of tabs shrinks first and the mini player comes down after, so that the
  /// two hardly cross; unfolding plays it backwards, the mini player going up first.
  late final _shrink = CurvedAnimation(
    parent: _folded,
    curve: const Interval(0, 0.6, curve: Curves.easeInOutCubic),
  );
  late final _drop = CurvedAnimation(
    parent: _folded,
    curve: const Interval(0.4, 1, curve: Curves.easeInOutCubic),
  );

  /// Whether the scroll under way is the person's, and how far it has gone one way since it last turned.
  bool _touched = false;
  double _travel = 0;

  /// What the glass of every bar reads from, once for them all.
  final _backdrop = BackdropKey();

  /// Every tab has a navigator of its own, so that a page opened from it (a playlist, an artist) opens inside the
  /// tab, between the top of the screen and the bars, instead of on top of everything.
  final _navigators = List.generate(4, (_) => GlobalKey<NavigatorState>());

  /// Pings when a page is opened or closed in a tab, which the Back button has to know about.
  final _stack = ValueNotifier<int>(0);

  /// One for each navigator: an observer can watch only one.
  late final _watchers = List.generate(
    4,
    (_) => _StackWatcher(() {
      // Opening a page happens in the middle of building; the news waits for the frame to be done
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _stack.value++;
        // A page that opens or closes shows the bars, as a tab does
        _fold(false);
      });
    }),
  );

  NavigatorState? get _current => _navigators[_tab].currentState;
  StreamSubscription<String>? _messages;
  StreamSubscription<String>? _libraryMessages;
  StreamSubscription<Notice>? _notices;
  RoomController? _watched;
  String? _precachedCover;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_messages != null) return;
    final room = _watched = AppScope.roomOf(context);
    _messages = room.messages.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    });
    _libraryMessages = AppScope.of(context).library.messages.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    });
    _notices = room.notices.listen((notice) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(notice.text),
            duration: const Duration(seconds: 6),
            action: notice.canKeepPlaying
                ? SnackBarAction(
                    label: S.keepPlaying,
                    onPressed: room.keepPlaying,
                  )
                : null,
          ),
        );
    });
    TabNavigation._active = () => _current;
    TabNavigation._closePlayer = () {
      if (_sheet.isOpen) _sheet.close();
    };
    room.invite.addListener(_onInvite);
    room.setup.addListener(_onSetup);
    room.addListener(_precacheCover);
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheCover());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onInvite());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSetup());
  }

  @override
  void dispose() {
    TabNavigation._active = null;
    TabNavigation._closePlayer = null;
    _stack.dispose();
    _watched?.invite.removeListener(_onInvite);
    _watched?.setup.removeListener(_onSetup);
    _watched?.removeListener(_precacheCover);
    _messages?.cancel();
    _libraryMessages?.cancel();
    _notices?.cancel();
    _sheet.dispose();
    _shrink.dispose();
    _drop.dispose();
    _folded.dispose();
    super.dispose();
  }

  /// Fetches the current song's cover in the size the full player shows it, ahead of time, so
  /// opening the player shows the picture at once instead of a placeholder.
  void _precacheCover() {
    final url = _watched?.snapshot.current?.thumb;
    if (url == null || url == _precachedCover || !mounted) return;
    _precachedCover = url;
    precacheImage(
      NetworkImage(sharpThumbnail(url)),
      context,
      // No enlarged picture for this one: the player will fall back to the original
      onError: (_, _) =>
          precacheImage(NetworkImage(url), context, onError: (_, _) {}),
    );
  }

  /// A setup link arrived, from the camera of this phone or from a message: the server and key of another phone.
  Future<void> _onSetup() async {
    final room = AppScope.roomOf(context);
    final link = room.setup.value;
    if (link == null || !mounted) return;
    room.setup.value = null;
    await askToUseSetup(context, room, link);
  }

  /// An invitation link arrived. Outside a room it opens the sheet with the code filled in; in a room
  /// it switches only if it is another room and the user agrees.
  Future<void> _onInvite() async {
    final room = AppScope.roomOf(context);
    final code = room.invite.value;
    if (code == null || !mounted) return;
    room.invite.value = null;
    if (code == room.snapshot.room) return;
    if (!room.snapshot.inRoom) return showRoomSheet(context, invitedCode: code);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.switchRoom),
        content: Text(S.inviteSwitch(code)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.join),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      room.join(code, room.snapshot.me?.name ?? room.profile.name ?? '');
    }
  }

  void _select(int tab) {
    _fold(false);
    if (tab == _tab) {
      // The tab that is open is touched again: back to its first page
      _current?.popUntil((route) => route.isFirst);
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _tab = tab;
      if (tab != 1) _browsing = tab;
    });
  }

  void _fold(bool fold) {
    if (fold == _isFolded) return;
    _isFolded = fold;
    _folded.animateTo(fold ? 1 : 0);
  }

  /// Scrolling a page down folds the bars away; scrolling back up, however little, brings them back.
  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    switch (notification) {
      case ScrollStartNotification(:final dragDetails):
        // Only a finger's scroll counts, with the glide after it, not a page moving by itself
        _touched = dragDetails != null;
        _travel = 0;
      case ScrollEndNotification():
        _touched = false;
      case ScrollUpdateNotification(:final scrollDelta?, :final metrics)
          when _touched && !metrics.outOfRange:
        // Past either end the page only bounces back, which says nothing of where the person is going
        if (scrollDelta.sign != _travel.sign) _travel = 0;
        _travel += scrollDelta;
        if (_travel > 24) _fold(true);
        if (_travel < -8) _fold(false);
      default:
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    final home = Scaffold(
      extendBody: true,
      // Beside a notch, when the phone is on its side
      body: SafeArea(
        top: false,
        bottom: false,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: IndexedStack(
            index: _tab,
            // A tab that is not showing keeps its state but not its animations
            children: [
              for (final (i, page) in [
                const HomePage(),
                const SearchPage(),
                const LibraryPage(),
                RoomPage(onAddSongs: () => _select(1)),
              ].indexed)
                TickerMode(
                  enabled: i == _tab,
                  child: Navigator(
                    key: _navigators[i],
                    observers: [_watchers[i]],
                    onGenerateRoute: (_) =>
                        MaterialPageRoute<void>(builder: (_) => page),
                  ),
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _Bars(
        controller: controller,
        shrink: _shrink,
        drop: _drop,
        index: _tab,
        browsing: _browsing,
        onSelect: _select,
        onUnfold: () => _fold(false),
      ),
    );
    return PlayerSheetScope(
      controller: _sheet,
      // Back closes an open player first, then goes back a page of the tab; only then does it leave the screen
      child: ListenableBuilder(
        listenable: Listenable.merge([_sheet, _stack]),
        builder: (context, stack) => PopScope(
          canPop: !_sheet.isOpen && !(_current?.canPop() ?? false),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_sheet.isOpen) {
              _sheet.close();
            } else {
              _current?.maybePop();
            }
          },
          child: stack!,
        ),
        // Around the sheet as well, for the picture of the mini player it draws while it opens
        child: BackdropGroup(
          backdropKey: _backdrop,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Nothing to draw behind a fully open player
              AnimatedBuilder(
                animation: _sheet.position,
                child: home,
                // Hidden behind the full player: not drawn, and its small animations stand still too
                builder: (context, home) => TickerMode(
                  enabled: _sheet.position.value != 1,
                  child: Offstage(
                    offstage: _sheet.position.value == 1,
                    child: home,
                  ),
                ),
              ),
              PlayerSheetLayer(controller: _sheet, folded: _drop),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mini player, the tabs and Search, in the manner of Apple Music, open or folded away. Open,
/// the mini player floats above a capsule of tabs, with Search apart as a round button. Folded, the capsule shrinks to
/// the tab that is open and the mini player moves down between it and Search.
///
/// The bars take the same height either way, so that folding them moves nothing on the page; only they themselves
/// take touches, not the room around them.
class _Bars extends StatelessWidget {
  const _Bars({
    required this.controller,
    required this.shrink,
    required this.drop,
    required this.index,
    required this.browsing,
    required this.onSelect,
    required this.onUnfold,
  });

  final RoomController controller;

  /// How far the capsule of tabs has shrunk, and the mini player come down, 0 to 1.
  final Animation<double> shrink;
  final Animation<double> drop;

  /// The tab that is open, and the last of the capsule's that was.
  final int index;
  final int browsing;
  final ValueChanged<int> onSelect;
  final VoidCallback onUnfold;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = HomeShell.isWide(context);
    final tabs = HomeShell.tabHeightOf(context);
    final mini = MiniPlayer.heightOf(context);
    // Between the mini player and the tabs, between the tabs and Search, and to the sides of the screen
    final gap = wide ? 4.0 : 10.0;
    final apart = wide ? 8.0 : 10.0;
    const side = 12.0;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, shrink, drop]),
      builder: (context, _) {
        final shrink = this.shrink.value;
        final drop = this.drop.value;
        // Where the row of tabs starts: below the mini player, when there is a song
        final row = controller.snapshot.current == null ? 0.0 : mini + gap;
        return Stack(
          children: [
            // What scrolls under the bars fades out towards the bottom edge, so it does not run into the system's
            // own bar below them
            Positioned.fill(
              top: row * drop,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        p.base.withValues(alpha: 0),
                        p.base.withValues(alpha: 0.8),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Clear of the system's own bar
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 10),
              child: SizedBox(
                height: row + tabs,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final open = box.maxWidth - 2 * side - apart - tabs;
                    // The mini player's sides, folded: beside the tab on the left and Search on the right
                    final inset = side + tabs + apart;
                    return Stack(
                      // A song that ends draws its capsule above the bars as it goes
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: side + (inset - side) * drop,
                          right: side + (inset - side) * drop,
                          top: (row - gap - mini) * (1 - drop) + row * drop,
                          child: MiniPlayer(
                            controller: controller,
                            folded: drop,
                          ),
                        ),
                        Positioned(
                          left: side,
                          top: row,
                          width: open + (tabs - open) * shrink,
                          height: tabs,
                          child: _Tabs(
                            index: index,
                            browsing: browsing,
                            folded: shrink,
                            openWidth: open,
                            onSelect: onSelect,
                            onUnfold: onUnfold,
                          ),
                        ),
                        Positioned(
                          right: side,
                          top: row,
                          width: tabs,
                          height: tabs,
                          child: Glass(
                            borderRadius: BorderRadius.circular(tabs / 2),
                            child: IconButton(
                              onPressed: () => onSelect(1),
                              tooltip: S.tabSearch,
                              icon: Icon(
                                Icons.search_rounded,
                                size: wide ? 22 : 26,
                                color: index == 1 ? p.primary : p.text,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The capsule of tabs, with a soft lens under the tab that is open. Folded, it is a round button with only the tab
/// that is open (or was, while Search is), which opens the bars again.
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.index,
    required this.browsing,
    required this.folded,
    required this.openWidth,
    required this.onSelect,
    required this.onUnfold,
  });

  final int index;
  final int browsing;
  final double folded;

  /// The capsule's width when open, which the tabs keep while it shrinks over them.
  final double openWidth;
  final ValueChanged<int> onSelect;
  final VoidCallback onUnfold;

  /// The tabs of the capsule, each with its place among the tabs; Search, the second, is the round button. A getter,
  /// not a constant: the names follow the language.
  static List<(int, IconData, String)> get _items => [
    (0, Icons.home_rounded, S.tabHome),
    (2, Icons.library_music_rounded, S.tabLibrary),
    (3, Icons.graphic_eq_rounded, S.tabListen),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = HomeShell.isWide(context);
    final round = BorderRadius.circular(HomeShell.tabHeightOf(context) / 2);
    final items = _items;
    final slot = items.indexWhere((item) => item.$1 == browsing);
    return Glass(
      borderRadius: round,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The tabs are gone half way, and the one that stays comes in once the capsule is nearly round: never both
          if (folded < 0.5)
            Opacity(
              opacity: 1 - 2 * folded,
              child: IgnorePointer(
                ignoring: folded > 0,
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: openWidth,
                  maxWidth: openWidth,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Slides to the tab that is opened; gone while Search is open
                      AnimatedOpacity(
                        opacity: index == 1 ? 0 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: AnimatedAlign(
                          alignment: Alignment(
                            2 * slot / (items.length - 1) - 1,
                            0,
                          ),
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutCubic,
                          child: FractionallySizedBox(
                            widthFactor: 1 / items.length,
                            heightFactor: 1,
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: p.text.withValues(alpha: 0.09),
                                  borderRadius: round,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          for (final (tab, icon, label) in items)
                            Expanded(
                              child: InkResponse(
                                onTap: () => onSelect(tab),
                                radius: 40,
                                child: TweenAnimationBuilder<Color?>(
                                  tween: ColorTween(
                                    end: tab == index
                                        ? p.primary
                                        : p.textSecondary,
                                  ),
                                  duration: const Duration(milliseconds: 200),
                                  builder: (context, color, _) {
                                    final glyph = Icon(
                                      icon,
                                      color: color,
                                      size: wide ? 22 : 26,
                                    );
                                    final name = Text(
                                      label,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: color,
                                            fontSize: 10.5,
                                          ),
                                    );
                                    // On its side the label goes beside the icon: there is no height to stack them
                                    return wide
                                        ? Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              glyph,
                                              const SizedBox(width: 6),
                                              name,
                                            ],
                                          )
                                        : Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              glyph,
                                              const SizedBox(height: 2),
                                              name,
                                            ],
                                          );
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (folded > 0.6)
            Opacity(
              opacity: (folded - 0.6) / 0.4,
              child: IgnorePointer(
                ignoring: folded < 1,
                child: IconButton(
                  onPressed: onUnfold,
                  tooltip: items[slot].$3,
                  icon: Icon(
                    items[slot].$2,
                    size: wide ? 22 : 26,
                    color: index == 1 ? p.text : p.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tells when a page is opened or closed in a tab.
class _StackWatcher extends NavigatorObserver {
  _StackWatcher(this.changed);

  final VoidCallback changed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => changed();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      changed();
}

/// Where a page opened from anywhere goes: into the tab that is showing, with the full player put away if it is open.
/// Sheets and the full player sit above the tabs, so their own navigator is the one for the whole screen, which is not
/// where such a page belongs.
abstract final class TabNavigation {
  static NavigatorState? Function()? _active;
  static VoidCallback? _closePlayer;

  static Future<T?> push<T>(BuildContext context, Route<T> route) {
    _closePlayer?.call();
    return (_active?.call() ?? Navigator.of(context)).push(route);
  }
}
