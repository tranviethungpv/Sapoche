import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/chat_extra.dart';
import '../data/sticker_store.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';
import 'widgets/sticker_image.dart';

/// The stickers, in the place of the keyboard: a search field, the stickers of the pack chosen below (or the ones used
/// lately), and a row of tabs ending in the way to the store. A touch on a sticker sends it and the tray stays open;
/// holding one shows it big.
class StickerTray extends StatefulWidget {
  const StickerTray({super.key, required this.accent, required this.onSend, required this.onOpenStore});

  final Color accent;

  /// A sticker was touched: send it.
  final ValueChanged<StickerExtra> onSend;
  final VoidCallback onOpenStore;

  @override
  State<StickerTray> createState() => _StickerTrayState();
}

class _StickerTrayState extends State<StickerTray> {
  /// The tab of the stickers used lately.
  static const _recentTab = '*';

  late final StickerStore _store = AppScope.of(context).stickers;
  final _search = TextEditingController();
  String? _tab;

  /// The recent ones as they were when the tab was opened: what is sent from the tray does not move the others about.
  late List<StickerExtra> _recent = _store.recent;
  OverlayEntry? _preview;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _hidePreview();
    _search.dispose();
    super.dispose();
  }

  /// Packs asked for, and the ones still being waited for.
  final _tried = <String>{};
  final _waiting = <String>{};

  /// The list of packs has been asked for.
  bool _ready = false;

  Future<void> _prepare() async {
    await _store.ensureReady();
    if (!mounted) return;
    setState(() {
      _ready = true;
      for (final id in _store.added) {
        _load(id);
      }
    });
  }

  /// Asks for the stickers of pack [id], once.
  void _load(String id) {
    if (_store.loadedPack(id) != null || !_tried.add(id)) return;
    _waiting.add(id);
    _store.pack(id).whenComplete(() {
      _waiting.remove(id);
      if (mounted) setState(() {});
    });
  }

  /// The tab shown: the one touched, else the recent ones if there are any, else the first pack.
  String get _current {
    final chosen = _tab;
    if (chosen != null && (chosen == _recentTab || _store.isAdded(chosen))) return chosen;
    return _recent.isNotEmpty || _store.addedPacks.isEmpty ? _recentTab : _store.addedPacks.first.id;
  }

  void _choose(String tab) {
    setState(() {
      _tab = tab;
      if (tab == _recentTab) {
        _recent = _store.recent;
      } else {
        _load(tab);
      }
    });
  }

  /// What the grid shows: the matches of the search in every added pack, or else the tab's own stickers.
  List<StickerExtra> _stickers(String query) {
    if (query.isNotEmpty) {
      return [
        for (final info in _store.addedPacks)
          for (final s in _store.loadedPack(info.id)?.stickers ?? const <Sticker>[])
            if (s.matches(query)) StickerExtra(pack: info.id, sticker: s.id, emoji: s.emoji),
      ];
    }
    final tab = _current;
    if (tab == _recentTab) return _recent;
    return [
      for (final s in _store.loadedPack(tab)?.stickers ?? const <Sticker>[])
        StickerExtra(pack: tab, sticker: s.id, emoji: s.emoji),
    ];
  }

  void _showPreview(StickerExtra sticker) {
    _hidePreview();
    HapticFeedback.selectionClick();
    _preview = OverlayEntry(
      builder: (context) => IgnorePointer(
        child: ColoredBox(
          color: Colors.black54,
          child: Center(
            child: StickerImage(
              key: const ValueKey('sticker-preview'),
              pack: sticker.pack,
              id: sticker.sticker,
              emoji: sticker.emoji,
              size: min(MediaQuery.sizeOf(context).width * 0.7, 280),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_preview!);
  }

  void _hidePreview() {
    _preview?.remove();
    _preview?.dispose();
    _preview = null;
  }

  @override
  Widget build(BuildContext context) {
    // Part of the field as far as a touch outside it goes: choosing a sticker must not put the keyboard away
    return TextFieldTapRegion(
      child: ListenableBuilder(
        listenable: _store,
        builder: (context, _) => Column(
          children: [
            _searchField(context),
            Expanded(child: _grid(context)),
            _tabs(context),
          ],
        ),
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
        height: 40,
        child: TextField(
          key: const ValueKey('sticker-search'),
          controller: _search,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: S.stickerSearchHint,
            isDense: true,
            filled: true,
            fillColor: widget.accent.withValues(alpha: 0.10),
            prefixIcon: Icon(Icons.search_rounded, size: 20, color: p.textSecondary),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('sticker-search-clear'),
                    tooltip: S.stickerSearchClear,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close_rounded, size: 18, color: p.textSecondary),
                    onPressed: () => setState(_search.clear),
                  ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
          ),
        ),
      ),
    );
  }

  Widget _grid(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final stickers = _stickers(query);
    if (stickers.isEmpty) {
      final tab = _current;
      return _Note(
        loading: query.isEmpty && (!_ready || _waiting.contains(tab)),
        text: query.isNotEmpty
            ? S.stickerNoMatch
            : tab == _recentTab
            ? (_store.addedPacks.isEmpty ? S.stickerNone : S.stickerRecentEmpty)
            : S.stickerStoreEmpty,
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 320 ? 4 : 3;
        final cell = (box.maxWidth - 16) / columns;
        return GridView.builder(
          key: ValueKey('sticker-grid-${query.isEmpty ? _current : 'search'}'),
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns),
          itemCount: stickers.length,
          itemBuilder: (context, i) {
            final sticker = stickers[i];
            return GestureDetector(
              key: ValueKey('sticker-${sticker.pack}-${sticker.sticker}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onSend(sticker),
              onLongPressStart: (_) => _showPreview(sticker),
              onLongPressEnd: (_) => _hidePreview(),
              onLongPressCancel: _hidePreview,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: StickerImage(
                  pack: sticker.pack,
                  id: sticker.sticker,
                  emoji: sticker.emoji,
                  size: max(cell - 8, 40),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _tabs(BuildContext context) {
    final p = context.palette;
    final current = _search.text.trim().isEmpty ? _current : null;
    Widget tab(String key, String label, Widget icon, String id) => Tooltip(
      message: label,
      child: InkResponse(
        key: ValueKey(key),
        onTap: () => _choose(id),
        radius: 24,
        child: Container(
          width: 44,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: current == id ? widget.accent.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: icon,
        ),
      ),
    );
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.textTertiary.withValues(alpha: 0.2))),
      ),
      child: Row(
        children: [
          tab(
            'sticker-tab-recent',
            S.stickerRecent,
            Icon(Icons.schedule_rounded, size: 22, color: p.textSecondary),
            _recentTab,
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final info in _store.addedPacks)
                  tab(
                    'sticker-tab-${info.id}',
                    info.name(S.current),
                    info.icon.isEmpty
                        ? Icon(Icons.emoji_emotions_outlined, size: 22, color: p.textSecondary)
                        : StickerImage(pack: info.id, id: info.icon, emoji: '', size: 28, animate: false),
                    info.id,
                  ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('sticker-store-button'),
            onPressed: widget.onOpenStore,
            tooltip: S.stickerStore,
            icon: Icon(Icons.add_circle_outline_rounded, color: widget.accent),
          ),
        ],
      ),
    );
  }
}

/// What the grid says when it has no stickers to show.
class _Note extends StatelessWidget {
  const _Note({required this.text, this.loading = false});

  final String text;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: loading
          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                text,
                key: const ValueKey('sticker-note'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.textSecondary),
              ),
            ),
    );
  }
}
