import 'package:flutter/material.dart';

import '../../data/chat_extra.dart';
import '../../data/models.dart';
import '../../data/room_controller.dart';
import 'chat_song_card.dart';

/// A link to a song of YouTube, in the chat, as the song's card: asked once for what the link points to, and until the
/// answer is here (or when there is none) [fallback] stands in, which is the words with the link in them.
class SongLinkCard extends StatefulWidget {
  const SongLinkCard({super.key, required this.controller, required this.link, required this.fallback});

  final RoomController controller;
  final String link;
  final Widget fallback;

  @override
  State<SongLinkCard> createState() => _SongLinkCardState();
}

class _SongLinkCardState extends State<SongLinkCard> {
  late Future<Track?> _song = widget.controller.songOfLink(widget.link);

  @override
  void didUpdateWidget(SongLinkCard old) {
    super.didUpdateWidget(old);
    if (old.link != widget.link) _song = widget.controller.songOfLink(widget.link);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Track?>(
      future: _song,
      builder: (context, snapshot) {
        final track = snapshot.data;
        if (track == null) return widget.fallback;
        return ChatSongCard(
          key: const ValueKey('song-link-card'),
          controller: widget.controller,
          song: SongExtra.fromTrack(track),
        );
      },
    );
  }
}
