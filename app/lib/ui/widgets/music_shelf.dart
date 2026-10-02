import 'package:flutter/material.dart';

import '../../data/music_models.dart';
import '../../strings.dart';
import '../artist_page.dart';
import '../collection_screen.dart';
import '../player/track_section.dart';
import 'play_actions.dart';
import 'song_card.dart';

/// A row of a page of YouTube Music, in the form that suits what is in it: covers that scroll sideways for videos,
/// albums and playlists, round pictures for artists.
class MusicShelfView extends StatelessWidget {
  const MusicShelfView({super.key, required this.shelf});

  final MusicShelf shelf;

  @override
  Widget build(BuildContext context) {
    final title = S.shelfTitle(shelf.title);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardShelf(
          title: title,
          cards: [
            for (final t in shelf.tracks)
              SongCard.track(context, t, onTap: () => playNow(context, t)),
            for (final r in [...shelf.albums, ...shelf.playlists])
              SongCard(
                title: r.title,
                subtitle: r.subtitle ?? '',
                thumb: r.thumb,
                onTap: () => openCollection(
                  context,
                  id: r.id,
                  title: r.title,
                  thumb: r.thumb,
                ),
              ),
          ],
        ),
        if (shelf.artists.isNotEmpty) ...[
          SectionHeading(title),
          ArtistRow(
            artists: shelf.artists,
            onOpen: (id) => openArtist(context, id),
          ),
        ],
      ],
    );
  }
}
