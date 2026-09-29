import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../strings.dart';
import '../theme/theme.dart';
import 'room_page.dart';
import 'scope.dart';
import 'search_page.dart';
import 'settings_page.dart';
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

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  StreamSubscription<String>? _messages;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messages ??= AppScope.roomOf(context).messages.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    });
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  void _select(int tab) {
    if (tab == _tab) return;
    HapticFeedback.selectionClick();
    setState(() => _tab = tab);
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _tab,
        children: [
          RoomPage(onAddSongs: () => _select(1)),
          const SearchPage(),
          const SettingsPage(),
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
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  static const _items = [
    (Icons.graphic_eq_rounded, S.tabRoom),
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
