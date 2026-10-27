import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/release_history.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'widgets/release_notes_text.dart';

/// The versions of the app, newest first, with what changed in each, a few at a time: the newest [_first], then
/// [_more] older ones whenever the person asks. The one on this device and the newest are open. Above them, the
/// versions the device has not got yet, when the server has told it of any.
class ReleaseHistoryList extends StatefulWidget {
  const ReleaseHistoryList({super.key, this.bundle, this.upcoming = const []});

  /// Where the notes are read from; the app's own assets unless a test says otherwise.
  final AssetBundle? bundle;

  /// The versions newer than the app's own, whose notes cannot be in it, as the server told them (newest first); they
  /// go above the rest, open, and are marked as new.
  final List<ReleaseEntry> upcoming;

  @override
  State<ReleaseHistoryList> createState() => _ReleaseHistoryListState();
}

class _ReleaseHistoryListState extends State<ReleaseHistoryList> {
  static const _first = 5;
  static const _more = 10;

  /// Every version there is; [_entries] are the newest of them, whose notes have been read.
  List<String> _versions = const [];
  List<ReleaseEntry>? _entries;
  bool _failed = false;
  bool _loadingMore = false;
  String? _language;

  AssetBundle get _bundle => widget.bundle ?? rootBundle;

  /// The version of this device, without the build number; null where the platform cannot say.
  late final Future<String?> _installed = PackageInfo.fromPlatform()
      .then<String?>((info) => info.version, onError: (_) => null);

  /// Reads the notes again in the language now in use, as many of them as are on show.
  Future<void> _load() async {
    final language = _language;
    final count = math.max(_entries?.length ?? 0, _first);
    try {
      final versions = await ReleaseHistory.versions(_bundle);
      final entries = await ReleaseHistory.read(
        _bundle,
        versions.take(count),
        language: language!,
      );
      if (!mounted || language != _language) return;
      setState(() {
        _versions = versions;
        _entries = entries;
        _failed = false;
      });
    } on Object {
      if (mounted && language == _language) setState(() => _failed = true);
    }
  }

  Future<void> _showMore() async {
    final shown = _entries!;
    setState(() => _loadingMore = true);
    try {
      final older = await ReleaseHistory.read(
        _bundle,
        _versions.skip(shown.length).take(_more),
        language: S.current,
      );
      // A language change in the meantime has read the notes again; these would be in the other one
      if (mounted && identical(_entries, shown)) {
        setState(() => _entries = [...shown, ...older]);
      }
    } on Object {
      // The button is still there for another try
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// One version: its number, a [badge] if it has one, and its notes, which are shown when it is [open].
  Widget _tile(
    BuildContext context,
    ReleaseEntry entry, {
    required bool open,
    String? badge,
  }) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.veil,
          borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
        ),
        child: Theme(
          // The lines the tile draws above and below itself when open
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey('release-${entry.version}'),
            initiallyExpanded: open,
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            title: Row(
              children: [
                Text(entry.version, style: theme.titleMedium),
                if (badge != null) ...[
                  const SizedBox(width: 10),
                  _Badge(badge),
                ],
              ],
            ),
            children: [ReleaseNotesText(entry.notes)],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Read again when the language changes: the notes come in both
    if (_language != S.current) {
      _language = S.current;
      _load();
    }
    final theme = Theme.of(context).textTheme;
    return FutureBuilder<String?>(
      future: _installed,
      builder: (context, installed) {
        final list = _entries;
        if (list == null) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: _failed
                  ? Text(S.releaseNotesNone, style: theme.bodyMedium)
                  : const CircularProgressIndicator(),
            ),
          );
        }
        // A version the app has in it is read from there: this one is for what it has not got yet
        final upcoming = [
          for (final entry in widget.upcoming)
            if (!_versions.contains(entry.version)) entry,
        ];
        return Column(
          key: const ValueKey('release-history'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (upcoming.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  S.releaseNotesUpdateHint,
                  key: const ValueKey('release-history-hint'),
                  style: theme.bodyMedium,
                ),
              ),
            for (final entry in upcoming)
              _tile(context, entry, open: true, badge: S.releaseNotesNew),
            for (final (i, entry) in list.indexed)
              _tile(
                context,
                entry,
                open: i == 0 || entry.version == installed.data,
                badge: entry.version == installed.data
                    ? S.releaseNotesInstalled
                    : null,
              ),
            if (list.length < _versions.length)
              Center(
                child: _loadingMore
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : TextButton(
                        key: const ValueKey('release-history-older'),
                        onPressed: _showMore,
                        child: Text(S.releaseNotesOlder),
                      ),
              ),
          ],
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: p.onPrimaryContainer),
        ),
      ),
    );
  }
}
