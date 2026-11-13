import 'package:flutter/material.dart';

import '../../data/library_controller.dart';
import '../../data/models.dart';
import '../../format.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import 'download_actions.dart';

/// What the page of the downloaded songs says above the songs: what they take, the run in hand with a way to stop it,
/// the songs that did not get downloaded with a way to try them again or let them go.
class DownloadsHeader extends StatefulWidget {
  const DownloadsHeader({super.key, required this.library});

  final LibraryController library;

  @override
  State<DownloadsHeader> createState() => _DownloadsHeaderState();
}

class _DownloadsHeaderState extends State<DownloadsHeader> {
  bool _open = false;

  Future<bool> _ask(String question, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(question),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(S.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _stop() async {
    final left = widget.library.downloads
        .where((d) => d.state == DownloadState.queued)
        .length;
    if (await _ask(S.stopDownloadingQuestion(left), S.stopDownloading)) {
      await widget.library.cancelDownloads();
    }
  }

  Future<void> _dropAll(List<DownloadEntry> stuck) async {
    if (!await _ask(S.dropAllQuestion(stuck.length), S.dropAll)) return;
    for (final d in stuck) {
      await widget.library.removeDownload(d.track.videoId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final batch = library.downloadBatch.value;
    final stuck = library.notDownloaded;
    final bytes = library.downloadedBytes;
    final quiet = text.bodyMedium?.copyWith(color: p.textSecondary);
    String? activeTitle;
    for (final d in library.downloads) {
      if (d.track.videoId == batch.active) activeTitle = d.track.title;
    }
    // Two things take room only when there is something to say: the run in hand and what did not get downloaded. Each is
    // one card, and the songs that did not get downloaded stay folded until the person asks for them
    Widget card(Widget child) => Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      decoration: BoxDecoration(
        color: p.surfaceRaised,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bytes > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(S.downloadsTake(formatBytes(bytes)), style: quiet),
          ),
        if (batch.running)
          card(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          S.downloadingOf(batch.position, batch.total),
                          style: text.titleSmall,
                        ),
                      ),
                      if (library.canCancelDownloads)
                        TextButton(
                          key: const ValueKey('stop-downloads'),
                          onPressed: _stop,
                          child: Text(S.stopDownloading),
                        ),
                    ],
                  ),
                  if (activeTitle != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 8),
                      child: Text(
                        activeTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: quiet,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: LinearProgressIndicator(
                      value: batch.total == 0
                          ? null
                          : (batch.done + batch.failed) / batch.total,
                      color: p.primary,
                      backgroundColor: p.outline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (stuck.isNotEmpty)
          card(
            Column(
              children: [
                InkWell(
                  key: const ValueKey('stuck-header'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _open = !_open),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            S.notDownloadedCount(stuck.length),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleSmall,
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('retry-all'),
                          onPressed: () => startDownload(context, [
                            for (final d in stuck) d.track,
                          ]),
                          child: Text(S.tryAgain),
                        ),
                        Icon(
                          _open
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          color: p.textSecondary,
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
                if (_open) ...[
                  for (final d in stuck)
                    Padding(
                      key: ValueKey('stuck ${d.track.videoId}'),
                      padding: const EdgeInsets.only(left: 16, right: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodyLarge,
                                ),
                                // What happened comes first: it is what the row is for, and a long artist is cut at the end
                                Text(
                                  '${switch (d.state) {
                                    DownloadState.failed => S.downloadFailed,
                                    DownloadState.waiting => S.waitingToDownload,
                                    _ => S.willTryAgain,
                                  }} · ${d.track.artist}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall?.copyWith(
                                    color: p.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: S.tryAgain,
                            onPressed: () => startDownload(context, [d.track]),
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                          IconButton(
                            tooltip: S.dropFromList,
                            onPressed: () =>
                                library.removeDownload(d.track.videoId),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 4),
                      child: TextButton(
                        key: const ValueKey('drop-all'),
                        onPressed: () => _dropAll(stuck),
                        child: Text(S.dropAll),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
