import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/release_history.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'widgets/release_notes_text.dart';

/// Every version of the app, newest first, with what changed in it. The one on this device and the newest are open.
class ReleaseHistoryList extends StatefulWidget {
  const ReleaseHistoryList({super.key, this.bundle});

  /// Where the notes are read from; the app's own assets unless a test says otherwise.
  final AssetBundle? bundle;

  @override
  State<ReleaseHistoryList> createState() => _ReleaseHistoryListState();
}

class _ReleaseHistoryListState extends State<ReleaseHistoryList> {
  Future<List<ReleaseEntry>>? _entries;
  String? _language;

  /// The version of this device, without the build number; null where the platform cannot say.
  late final Future<String?> _installed = PackageInfo.fromPlatform()
      .then<String?>((info) => info.version, onError: (_) => null);

  @override
  Widget build(BuildContext context) {
    // Read again when the language changes: the notes come in both
    if (_language != S.current || _entries == null) {
      _language = S.current;
      _entries = ReleaseHistory.load(
        widget.bundle ?? rootBundle,
        language: S.current,
      );
    }
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return FutureBuilder<List<ReleaseEntry>>(
      future: _entries,
      builder: (context, entries) => FutureBuilder<String?>(
        future: _installed,
        builder: (context, installed) {
          final list = entries.data;
          if (list == null) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: entries.hasError
                    ? Text(S.releaseNotesNone, style: theme.bodyMedium)
                    : const CircularProgressIndicator(),
              ),
            );
          }
          return Column(
            key: const ValueKey('release-history'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, entry) in list.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: p.veil,
                      borderRadius: BorderRadius.circular(
                        SapocheTheme.cardRadius,
                      ),
                    ),
                    child: Theme(
                      // The lines the tile draws above and below itself when open
                      data: Theme.of(context)
                          .copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        key: PageStorageKey('release-${entry.version}'),
                        initiallyExpanded:
                            i == 0 || entry.version == installed.data,
                        shape: const Border(),
                        collapsedShape: const Border(),
                        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          12,
                        ),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        title: Row(
                          children: [
                            Text(entry.version, style: theme.titleMedium),
                            if (entry.version == installed.data) ...[
                              const SizedBox(width: 10),
                              _Badge(S.releaseNotesInstalled),
                            ],
                          ],
                        ),
                        children: [ReleaseNotesText(entry.notes)],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
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
