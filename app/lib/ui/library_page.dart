import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library_controller.dart';
import '../data/models.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'scope.dart';
import 'widgets/track_menu.dart';
import 'widgets/track_tile.dart';

/// What a person keeps: liked songs and what they heard lately. Opening one shows its songs in place, so
/// the mini player and the tabs stay where they are.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

enum _Section { liked, recent }

class _LibraryPageState extends State<LibraryPage> {
  _Section? _open;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: library,
        builder: (context, _) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (_open) {
            null => _Overview(
              key: const ValueKey('overview'),
              library: library,
              onOpen: (section) => setState(() => _open = section),
            ),
            final section => _SongList(
              key: ValueKey(section),
              section: section,
              library: library,
              onBack: () => setState(() => _open = null),
            ),
          },
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({super.key, required this.library, required this.onOpen});

  final LibraryController library;
  final ValueChanged<_Section> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: HomeShell.bottomInset),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Text(S.tabLibrary, style: theme.headlineLarge),
        ),
        _CollectionRow(
          icon: Icons.favorite_rounded,
          title: S.likedSongs,
          subtitle: S.songCount(library.liked.length),
          onTap: () => onOpen(_Section.liked),
        ),
        _CollectionRow(
          icon: Icons.history_rounded,
          title: S.recentlyPlayed,
          subtitle: S.songCount(library.recent.length),
          onTap: () => onOpen(_Section.recent),
        ),
      ],
    );
  }
}

class _CollectionRow extends StatelessWidget {
  const _CollectionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: p.primaryContainer,
                borderRadius: BorderRadius.circular(UnisonTheme.artworkRadius),
              ),
              child: Icon(icon, color: p.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: p.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// The songs of one section, with the ways to play them.
class _SongList extends StatelessWidget {
  const _SongList({
    super.key,
    required this.section,
    required this.library,
    required this.onBack,
  });

  final _Section section;
  final LibraryController library;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final room = AppScope.roomOf(context);
    final liked = section == _Section.liked;
    final entries = liked
        ? [for (final t in library.liked) (track: t, subtitle: t.artist)]
        : [
            for (final e in library.recent)
              (
                track: e.track,
                subtitle:
                    '${e.track.artist} · ${S.ago(DateTime.now().difference(e.at))}',
              ),
          ];
    final tracks = [for (final e in entries) e.track];

    Future<void> confirm(String text) async {
      HapticFeedback.selectionClick();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }

    Future<void> add(Track track, {bool playNext = false}) async {
      await room.add(track, playNext: playNext);
      await confirm(playNext ? S.willPlayNext : S.addedToQueue);
    }

    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final inRoom = room.snapshot.inRoom;
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: HomeShell.bottomInset),
          itemCount: entries.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextButton.icon(
                      onPressed: onBack,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 14,
                      ),
                      label: const Text(S.backToLibrary),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            liked ? S.likedSongs : S.recentlyPlayed,
                            style: theme.headlineMedium,
                          ),
                        ),
                        if (!liked && entries.isNotEmpty)
                          TextButton(
                            onPressed: () => _confirmClear(context),
                            child: const Text(S.clearHistory),
                          ),
                      ],
                    ),
                    Text(
                      S.songCount(entries.length),
                      style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                    ),
                    if (entries.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () {
                                room.playTracks(tracks);
                                confirm(
                                  inRoom ? S.playlistAdded : S.addedToQueue,
                                );
                              },
                              icon: Icon(
                                inRoom
                                    ? Icons.playlist_add_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                              label: Text(inRoom ? S.addAll : S.play),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                final mixed = [...tracks]..shuffle();
                                room.playTracks(mixed);
                                confirm(
                                  inRoom ? S.playlistAdded : S.addedToQueue,
                                );
                              },
                              child: const Text(S.shuffle),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            }
            final entry = entries[i - 1];
            return TrackTile(
              track: entry.track,
              subtitle: entry.subtitle,
              // Outside a room the song plays with the rest of the list behind it; in a room it is queued
              onTap: inRoom
                  ? () => add(entry.track)
                  : () => room.playTracks(tracks.sublist(i - 1)),
              trailing: TrackMenu(
                track: entry.track,
                onAdd: () => add(entry.track),
                onPlayNext: () => add(entry.track, playNext: true),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text(S.clearHistoryQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(S.clear),
          ),
        ],
      ),
    );
    if (ok == true) library.clearHistory();
  }
}
