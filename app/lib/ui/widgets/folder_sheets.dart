import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import 'playlist_cover.dart';
import 'text_dialog.dart';

/// What a person can do to a folder that is not a tap on it, as a list in a sheet; [ListView] keeps a long one reachable.
Future<T?> _sheet<T>(
  BuildContext context,
  Widget Function(BuildContext) builder,
) => showModalBottomSheet<T>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  builder: builder,
);

Widget _title(BuildContext context, String text, {String? hint}) {
  final theme = Theme.of(context).textTheme;
  final p = context.palette;
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: theme.titleLarge),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              hint,
              style: theme.bodyMedium?.copyWith(color: p.textSecondary),
            ),
          ),
      ],
    ),
  );
}

/// Asks which folder [playlist] goes in (or out of), makes the folder when the person asks for a new one, and says what
/// happened.
Future<void> showMoveToFolder(
  BuildContext context,
  SavedPlaylist playlist,
) async {
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  // A folder is chosen by its id, or [none] takes the playlist out, or [fresh] asks for a folder to be made
  const none = -1;
  const fresh = -2;
  final choice = await _sheet<int>(context, (context) {
    final p = context.palette;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            _title(context, S.moveToFolder),
            ListTile(
              leading: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: p.primaryContainer,
                  borderRadius: BorderRadius.circular(
                    SapocheTheme.artworkRadius,
                  ),
                ),
                child: Icon(Icons.create_new_folder_rounded, color: p.primary),
              ),
              title: Text(S.newFolder),
              onTap: () => Navigator.pop(context, fresh),
            ),
            for (final folder in library.folders)
              ListTile(
                leading: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: p.veilStrong,
                    borderRadius: BorderRadius.circular(
                      SapocheTheme.artworkRadius,
                    ),
                  ),
                  child: Icon(Icons.folder_rounded, color: p.text),
                ),
                title: Text(
                  folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: folder.id == playlist.folderId
                    ? Icon(Icons.check_rounded, color: p.primary)
                    : null,
                onTap: () => Navigator.pop(context, folder.id),
              ),
            if (playlist.folderId != null)
              ListTile(
                leading: SizedBox(
                  width: 46,
                  height: 46,
                  child: Icon(Icons.folder_off_outlined, color: p.text),
                ),
                title: Text(S.removeFromFolder),
                onTap: () => Navigator.pop(context, none),
              ),
          ],
        ),
      ),
    );
  });
  if (choice == null || !context.mounted) return;

  void say(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  if (choice == none) {
    await library.moveToFolder(playlist.id, null);
    return;
  }
  var folderId = choice;
  var name = library.folders.where((f) => f.id == choice).firstOrNull?.name;
  if (choice == fresh) {
    final typed = await showTextDialog(
      context,
      title: S.newFolder,
      hint: S.folderName,
      maxLength: 60,
    );
    if (typed == null || typed.isEmpty) return;
    final made = await library.createFolder(typed);
    if (made == null) return;
    folderId = made;
    name = typed;
  }
  await library.moveToFolder(playlist.id, folderId);
  if (name != null) say(S.movedToFolder(name));
}

/// Asks which playlists go in [folder], with the ones in other folders marked as such, and puts them there. A playlist is
/// in one folder at most, so choosing one that is in another takes it out of that one.
Future<void> showAddPlaylists(
  BuildContext context,
  PlaylistFolder folder,
) async {
  final library = AppScope.of(context).library;
  final candidates = [
    for (final p in library.playlists)
      if (p.folderId != folder.id) p,
  ];
  if (candidates.isEmpty) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.noPlaylistsToAdd)));
    return;
  }
  final chosen = await _sheet<Set<int>>(
    context,
    (_) => _AddPlaylists(candidates: candidates),
  );
  if (chosen == null || chosen.isEmpty) return;
  for (final id in chosen) {
    await library.moveToFolder(id, folder.id);
  }
}

class _AddPlaylists extends StatefulWidget {
  const _AddPlaylists({required this.candidates});

  final List<SavedPlaylist> candidates;

  @override
  State<_AddPlaylists> createState() => _AddPlaylistsState();
}

class _AddPlaylistsState extends State<_AddPlaylists> {
  final _chosen = <int>{};

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final library = AppScope.of(context).library;
    String subtitle(SavedPlaylist playlist) {
      final folder = library.folders
          .where((f) => f.id == playlist.folderId)
          .firstOrNull;
      return folder == null
          ? S.songCount(playlist.count)
          : '${S.songCount(playlist.count)} · ${S.inFolder(folder.name)}';
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _title(context, S.addPlaylists, hint: S.addPlaylistsHint),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final playlist in widget.candidates)
                    CheckboxListTile(
                      value: _chosen.contains(playlist.id),
                      onChanged: (on) => setState(
                        () => on == true
                            ? _chosen.add(playlist.id)
                            : _chosen.remove(playlist.id),
                      ),
                      controlAffinity: ListTileControlAffinity.trailing,
                      secondary: PlaylistCover(
                        thumbs: playlist.thumbs,
                        size: 46,
                      ),
                      title: Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(subtitle(playlist)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _chosen.isEmpty
                      ? null
                      : () => Navigator.pop(context, _chosen),
                  style: FilledButton.styleFrom(
                    backgroundColor: p.text,
                    foregroundColor: p.base,
                    shape: const StadiumBorder(),
                  ),
                  child: Text(S.save),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
