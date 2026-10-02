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

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  int _tab = 0;
  late final _sheet = PlayerSheetController(this);

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
        if (mounted) _stack.value++;
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
    if (tab == _tab) {
      // The tab that is open is touched again: back to its first page
      _current?.popUntil((route) => route.isFirst);
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _tab = tab);
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
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SafeArea(
            top: false,
            bottom: false,
            child: MiniPlayer(controller: controller),
          ),
          SizedBox(height: HomeShell.isWide(context) ? 4 : 8),
          _TabBar(index: _tab, onSelect: _select),
        ],
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
            PlayerSheetLayer(controller: _sheet),
          ],
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  /// A getter, not a constant: the names follow the language.
  static List<(IconData, String)> get _items => [
    (Icons.home_rounded, S.tabHome),
    (Icons.search_rounded, S.tabSearch),
    (Icons.library_music_rounded, S.tabLibrary),
    (Icons.graphic_eq_rounded, S.tabListen),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = HomeShell.isWide(context);
    return Glass(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.outlineSoft)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: wide ? 40 : 58,
            child: Row(
              children: [
                for (var i = 0; i < _items.length; i++)
                  Expanded(
                    child: InkResponse(
                      onTap: () => onSelect(i),
                      radius: 40,
                      child: TweenAnimationBuilder<Color?>(
                        tween: ColorTween(
                          end: i == index ? p.primary : p.textTertiary,
                        ),
                        duration: const Duration(milliseconds: 200),
                        builder: (context, color, _) {
                          final icon = AnimatedScale(
                            scale: i == index ? 1.12 : 1,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutBack,
                            child: Icon(
                              _items[i].$1,
                              color: color,
                              size: wide ? 22 : 26,
                            ),
                          );
                          final label = Text(
                            _items[i].$2,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: color, fontSize: 10.5),
                          );
                          // On its side the label goes beside the icon: there is no height to stack them
                          return wide
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    icon,
                                    const SizedBox(width: 6),
                                    label,
                                  ],
                                )
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    icon,
                                    const SizedBox(height: 2),
                                    label,
                                  ],
                                );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
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
