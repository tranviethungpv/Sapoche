import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'cached_cover.dart';

/// The largest picture YouTube keeps for a thumbnail address, or the address itself when it is not
/// one we know how to enlarge. Search results carry a picture only about 400 pixels tall, and a
/// square crop of that is far too little for the full player.
String sharpThumbnail(String url) {
  final uri = Uri.tryParse(url);
  final host = uri?.host ?? '';
  if (_videoId(uri) case final id?) {
    return 'https://i.ytimg.com/vi/$id/maxresdefault.jpg';
  }
  if (host.endsWith('googleusercontent.com') || host.endsWith('ggpht.com')) {
    return url.replaceFirst(RegExp(r'=w\d+-h\d+'), '=w1200-h1200');
  }
  return url;
}

/// The id of the video a YouTube thumbnail address is of, or null for any other address.
String? _videoId(Uri? uri) {
  if (uri == null || !uri.host.endsWith('ytimg.com')) return null;
  return RegExp(r'^/vi(?:_webp)?/([\w-]{11})/').firstMatch(uri.path)?[1];
}

/// A video's thumbnail in the one size that has no black bars above and below the picture (the larger ones do), so
/// that cropping it square leaves only picture. Any other address is left as it is.
String barlessThumbnail(String url) => switch (_videoId(Uri.tryParse(url))) {
  final id? => 'https://i.ytimg.com/vi/$id/mqdefault.jpg',
  _ => url,
};

/// Cover image with rounded corners; shows a soft pink tile while loading or when there is none.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.url,
    required this.size,
    this.radius = SapocheTheme.artworkRadius,
    this.sharp = false,
    this.wide = false,
  });

  final String? url;
  final double size;
  final double radius;

  /// Fetch the largest picture available and decode it whole, for covers shown big. Small covers
  /// are decoded at their own size to save memory.
  final bool sharp;

  /// The picture is wide and is cropped square: it is decoded by its height, as a decode by width would leave it
  /// too few pixels tall. For small covers; [sharp] ones are decoded whole.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final placeholder = ColoredBox(
      color: p.primaryContainer,
      child: Icon(
        Icons.music_note_rounded,
        color: p.primary.withValues(alpha: 0.6),
        size: size * 0.42,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: url == null
            ? placeholder
            : _network(
                context,
                sharp ? sharpThumbnail(url!) : url!,
                placeholder,
                // Not every video has the enlarged picture: then the original will do
                onError: sharp && sharpThumbnail(url!) != url
                    ? (_, _, _) => _network(context, url!, placeholder)
                    : null,
              ),
      ),
    );
  }

  Widget _network(
    BuildContext context,
    String address,
    Widget placeholder, {
    ImageErrorWidgetBuilder? onError,
  }) => Image(
    image: ResizeImage.resizeIfNeeded(
      // A wide picture cropped square would come out short of pixels if it were decoded by width
      sharp || wide
          ? null
          : (size * MediaQuery.devicePixelRatioOf(context)).round(),
      wide ? (size * MediaQuery.devicePixelRatioOf(context)).round() : null,
      CachedCover(address),
    ),
    fit: BoxFit.cover,
    errorBuilder: onError ?? (_, _, _) => placeholder,
    frameBuilder: (context, child, frame, sync) => sync
        ? child
        : Stack(
            fit: StackFit.expand,
            children: [
              placeholder,
              AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 300),
                child: child,
              ),
            ],
          ),
  );
}
