import 'package:flutter/material.dart';

import '../data/models.dart';
import '../strings.dart';
import 'player/player_message.dart';
import 'scope.dart';
import 'widgets/queue_actions.dart';
import 'widgets/play_actions.dart';
import 'widgets/track_menu.dart';
import 'widgets/track_tile.dart';
import 'widgets/wash.dart';

/// Opens a YouTube playlist on top of everything, with a way back.
Future<void> openPlaylist(BuildContext context, String id, String title) {
  ScaffoldMessenger.of(context).removeCurrentSnackBar();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PlaylistScreen(id: id, title: title),
    ),
  );
}

/// The songs of a playlist that somebody else made, to play or to put on the queue.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key, required this.id, required this.title});

  final String id;
  final String title;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  Future<LinkResult?>? _songs;

  void _load() =>
      _songs = AppScope.roomOf(context)
          .lookup('https://www.youtube.com/playlist?list=${widget.id}');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_songs == null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final room = AppScope.roomOf(context);
    // A page on its own has no backdrop: the pink veil is part of the home screen
    return PinkWash(
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: FutureBuilder<LinkResult?>(
          future: _songs,
          builder: (context, async) {
            if (async.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            }
            final tracks = async.data?.tracks;
            if (async.hasError || tracks == null || tracks.isEmpty) {
              return PlayerMessage(
                icon: Icons.cloud_off_rounded,
                text: S.playlistFailed,
                action: S.tryAgain,
                onAction: () => setState(_load),
              );
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            room.playTracks(tracks);
                            Navigator.of(context)
                                .popUntil((route) => route.isFirst);
                          },
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text(S.play),
                        ),
                      ),
                    ],
                  ),
                ),
                for (final (i, track) in tracks.indexed)
                  TrackTile(
                    track: track,
                    // The playlist plays on from the song touched, as in the library
                    onTap: () => playFrom(context, tracks, i),
                    trailing: TrackMenu(
                      track: track,
                      onAdd: () => queueTrack(context, track),
                      onPlayNext: () =>
                          queueTrack(context, track, playNext: true),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
