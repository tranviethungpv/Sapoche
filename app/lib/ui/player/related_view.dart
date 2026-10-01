import 'package:flutter/material.dart';

import '../../data/music_models.dart';
import '../../data/models.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../artist_page.dart';
import '../scope.dart';
import 'player_message.dart';
import 'track_section.dart';

/// Songs and artists around the one playing, as on the "Related" tab of YouTube Music.
class RelatedView extends StatefulWidget {
  const RelatedView({super.key, required this.track});

  final Track track;

  @override
  State<RelatedView> createState() => _RelatedViewState();
}

class _RelatedViewState extends State<RelatedView> {
  Future<RelatedPage>? _related;
  String? _for;

  void _load() {
    _for = widget.track.videoId;
    _related = AppScope.of(context).music.related(widget.track.videoId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_related == null) _load();
  }

  @override
  void didUpdateWidget(RelatedView old) {
    super.didUpdateWidget(old);
    if (widget.track.videoId != _for) _load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RelatedPage>(
      key: ValueKey(_for),
      future: _related,
      builder: (context, async) {
        if (async.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (async.hasError) {
          return PlayerMessage(
            icon: Icons.cloud_off_rounded,
            text: S.musicFailed,
            action: S.tryAgain,
            onAction: () => setState(_load),
          );
        }
        final page = async.data!;
        if (page.isEmpty) {
          return PlayerMessage(
            icon: Icons.explore_outlined,
            text: S.nothingRelated,
          );
        }
        return ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            TrackSection(title: S.youMightAlsoLike, tracks: page.more),
            TrackSection(
              title: S.otherPerformances,
              tracks: page.otherPerformances,
            ),
            if (page.artists.isNotEmpty) ...[
              SectionHeading(S.similarArtists),
              ArtistRow(
                artists: page.artists,
                onOpen: (id) => openArtist(context, id),
              ),
            ],
            if (page.about != null) _About(text: page.about!),
          ],
        );
      },
    );
  }
}

/// A paragraph that shows its first lines and opens out on a touch.
class _About extends StatefulWidget {
  const _About({required this.text});

  final String text;

  @override
  State<_About> createState() => _AboutState();
}

class _AboutState extends State<_About> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(S.aboutArtist),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GestureDetector(
            onTap: () => setState(() => _open = !_open),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              alignment: Alignment.topCenter,
              child: Text(
                widget.text,
                maxLines: _open ? null : 5,
                overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: p.textSecondary),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _open = !_open),
            child: Text(_open ? S.showLess : S.showMore),
          ),
        ),
      ],
    );
  }
}
