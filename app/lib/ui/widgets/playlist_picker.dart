import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import 'artwork.dart';
import 'text_dialog.dart';

/// Asks which playlist [tracks] go into, or offers to make one, and says what happened.
Future<void> showAddToPlaylist(BuildContext context, List<Track> tracks) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _Picker(playlists: library.playlists),
  );
  if (choice == null) return;

  void say(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  if (choice is SavedPlaylist) {
    final added = await library.addToPlaylist(choice.id, tracks);
    say(
      added > 0
          ? S.addedToPlaylist(choice.name)
          : S.alreadyInPlaylist(choice.name),
    );
    return;
  }
  if (!context.mounted) return;
  final name = await showTextDialog(
    context,
    title: S.newPlaylist,
    hint: S.playlistName,
    maxLength: 60,
  );
  if (name == null || name.isEmpty) return;
  if (await library.createPlaylist(name, tracks) != null) {
    say(S.addedToPlaylist(name));
  }
}

class _Picker extends StatelessWidget {
  const _Picker({required this.playlists});

  final List<SavedPlaylist> playlists;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(S.addToPlaylist, style: theme.titleLarge),
            ),
            ListTile(
              leading: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: p.primaryContainer,
                  borderRadius: BorderRadius.circular(
                    UnisonTheme.artworkRadius,
                  ),
                ),
                child: Icon(Icons.add_rounded, color: p.primary),
              ),
              title: Text(S.newPlaylist),
              onTap: () => Navigator.pop(context, 'new'),
            ),
            for (final playlist in playlists)
              ListTile(
                leading: Artwork(url: playlist.thumb, size: 46),
                title: Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(S.songCount(playlist.count)),
                onTap: () => Navigator.pop(context, playlist),
              ),
          ],
        ),
      ),
    );
  }
}
