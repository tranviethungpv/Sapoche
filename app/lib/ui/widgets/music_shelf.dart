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
    // A shelf of nothing but videos ("Videos", "Live performances") is a row of wide covers: a square crop of a video
    // cut the lettering off its two edges
    final video =
        shelf.tracks.isNotEmpty &&
        shelf.albums.isEmpty &&
        shelf.playlists.isEmpty &&
        shelf.tracks.every((t) => !t.isSong);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardShelf(
          title: title,
          video: video,
          cards: [
            for (final t in shelf.tracks)
              SongCard.track(
                context,
                t,
                video: video,
                onTap: () => playNow(context, t),
              ),
            for (final r in [...shelf.albums, ...shelf.playlists])
              SongCard.listing(
                title: r.title,
                subtitle: r.subtitle,
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
