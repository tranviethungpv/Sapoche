import 'package:flutter/material.dart';

import '../data/sticker_store.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';
import 'widgets/sticker_image.dart';

/// The sticker store: the packs on the server, with the way to add one to this device or take it off.
Future<void> showStickerStore(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => const StickerStorePage()));

class StickerStorePage extends StatefulWidget {
  const StickerStorePage({super.key});

  @override
  State<StickerStorePage> createState() => _StickerStorePageState();
}

class _StickerStorePageState extends State<StickerStorePage> {
  late final StickerStore _store = AppScope.of(context).stickers;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(force: false);
  }

  Future<void> _load({required bool force}) async {
    setState(() => _loading = true);
    await _store.loadIndex(force: force);
    await _store.ensureReady();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.stickerStore)),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_store.packs.isEmpty) return _Closed(onRetry: () => _load(force: true));
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  for (final info in _store.packs) _PackCard(store: _store, info: info),
                  Center(
                    child: TextButton(
                      key: const ValueKey('sticker-licenses'),
                      onPressed: () => showLicensePage(context: context, applicationName: S.appName),
                      child: Text(S.stickerLicenses),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// What the page says when the server lists no packs (it has none, or cannot be reached).
class _Closed extends StatelessWidget {
  const _Closed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Center(
      key: const ValueKey('sticker-store-closed'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_emotions_outlined, size: 40, color: p.textTertiary),
            const SizedBox(height: 12),
            Text(S.stickerStoreEmpty, textAlign: TextAlign.center, style: theme.titleMedium),
            const SizedBox(height: 4),
            Text(
              S.stickerStoreEmptyBody,
              textAlign: TextAlign.center,
              style: theme.bodyMedium?.copyWith(color: p.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(key: const ValueKey('sticker-store-retry'), onPressed: onRetry, child: Text(S.tryAgain)),
          ],
        ),
      ),
    );
  }
}

class _PackCard extends StatefulWidget {
  const _PackCard({required this.store, required this.info});

  final StickerStore store;
  final StickerPackInfo info;

  @override
  State<_PackCard> createState() => _PackCardState();
}

class _PackCardState extends State<_PackCard> {
  /// How many stickers the strip shows.
  static const _preview = 4;

  @override
  void initState() {
    super.initState();
    widget.store.pack(widget.info.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final store = widget.store;
    final info = widget.info;
    final state = store.state(info.id);
    final progress = store.progressOf(info.id);
    final credit = info.credit;
    final stickers = store.loadedPack(info.id)?.stickers.take(_preview).toList() ?? const <Sticker>[];
    return Card(
      key: ValueKey('sticker-pack-${info.id}'),
      margin: const EdgeInsets.only(top: 12),
      elevation: 0,
      color: p.primary.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 56,
              child: Wrap(
                spacing: 8,
                children: [for (final s in stickers) StickerImage(pack: info.id, id: s.id, emoji: s.emoji, size: 56)],
              ),
            ),
            const SizedBox(height: 10),
            Text(info.name(S.current), style: theme.titleMedium),
            Text(
              '${S.stickerCount(info.count)} · ${formatBytes(info.bytes)}',
              style: theme.bodySmall?.copyWith(color: p.textSecondary),
            ),
            if (credit != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  S.stickerCredit(credit.name, credit.by, credit.license),
                  key: ValueKey('sticker-credit-${info.id}'),
                  style: theme.bodySmall?.copyWith(color: p.textTertiary),
                ),
              ),
            if (progress != null) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(key: ValueKey('sticker-progress-${info.id}'), value: progress),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(switch (state) {
                    StickerPackState.downloading => S.stickerDownloading(((progress ?? 0) * 100).floor()),
                    StickerPackState.notDownloaded => S.stickerNotDownloaded,
                    _ => '',
                  }, style: theme.labelMedium?.copyWith(color: p.textSecondary)),
                ),
                if (state == StickerPackState.notDownloaded)
                  TextButton(
                    key: ValueKey('sticker-download-${info.id}'),
                    onPressed: () => store.download(info.id),
                    child: Text(S.stickerDownload),
                  ),
                if (state == StickerPackState.notAdded)
                  FilledButton(
                    key: ValueKey('sticker-add-${info.id}'),
                    onPressed: () => store.add(info.id),
                    child: Text(S.stickerAddPack),
                  )
                else
                  OutlinedButton(
                    key: ValueKey('sticker-remove-${info.id}'),
                    onPressed: () => store.remove(info.id),
                    child: Text(S.stickerRemovePack),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
