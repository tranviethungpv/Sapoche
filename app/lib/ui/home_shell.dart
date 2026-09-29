import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'player_sheet.dart';
import 'room_page.dart';
import 'rooms_sheet.dart';
import 'scope.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'widgets/artwork.dart';
import 'widgets/glass.dart';
import 'widgets/mini_player.dart';

/// Tabs plus the floating mini player. Lists scroll behind both bars, which blur them.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Bottom padding lists need so their last row can scroll clear of the bars.
  static const bottomInset = 176.0;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  int _tab = 0;
  late final _sheet = PlayerSheetController(this);
  StreamSubscription<String>? _messages;
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
    room.invite.addListener(_onInvite);
    room.addListener(_precacheCover);
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheCover());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onInvite());
  }

  @override
  void dispose() {
    _watched?.invite.removeListener(_onInvite);
    _watched?.removeListener(_precacheCover);
    _messages?.cancel();
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
        title: const Text(S.switchRoom),
        content: Text(S.inviteSwitch(code)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(S.join),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      room.join(code, room.snapshot.me?.name ?? room.profile.name ?? '');
    }
  }

  void _select(int tab) {
    if (tab == _tab) return;
    HapticFeedback.selectionClick();
    setState(() => _tab = tab);
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    final home = Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _tab,
        // A tab that is not showing keeps its state but not its animations
        children: [
          for (final (i, page) in [
            RoomPage(onAddSongs: () => _select(1)),
            const SearchPage(),
            const SettingsPage(),
          ].indexed)
            TickerMode(enabled: i == _tab, child: page),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniPlayer(controller: controller),
          const SizedBox(height: 8),
          _TabBar(index: _tab, onSelect: _select),
        ],
      ),
    );
    return PlayerSheetScope(
      controller: _sheet,
      // Back closes an open player first; only then does it leave the screen
      child: ListenableBuilder(
        listenable: _sheet,
        builder: (context, stack) => PopScope(
          canPop: !_sheet.isOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _sheet.close();
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

  static const _items = [
    (Icons.graphic_eq_rounded, S.tabListen),
    (Icons.search_rounded, S.tabSearch),
    (Icons.tune_rounded, S.tabSettings),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Glass(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.outlineSoft)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 58,
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
                        builder: (context, color, _) => Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedScale(
                              scale: i == index ? 1.12 : 1,
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutBack,
                              child: Icon(_items[i].$1, color: color, size: 26),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _items[i].$2,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: color, fontSize: 10.5),
                            ),
                          ],
                        ),
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
