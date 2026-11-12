import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'cached_cover.dart';
import 'motion.dart';

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

/// YouTube's 4:3 thumbnails (`hqdefault`, `sddefault`, `default`, `0`) hold the 16:9 picture between two black bars,
/// a 1/8 of the height each, which a square crop keeps.
bool _hasBars(Uri? uri) {
  if (_videoId(uri) == null) return false;
  final name = uri!.pathSegments.last.split('.').first;
  return const {'hqdefault', 'sddefault', 'default', '0'}.contains(name);
}

/// A cover this small or smaller takes the thumbnail that has no bars; a bigger one keeps its picture and shows only
/// the part between the bars, with no second request.
const double _smallCover = 72;

/// Cover image with rounded corners; shows a soft pink tile while loading or when there is none.
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.url,
    required this.size,
    this.width,
    this.radius = SapocheTheme.artworkRadius,
    this.sharp = false,
    this.wide = false,
    this.crossfade = false,
  });

  final String? url;
  final double size;

  /// For a wide box (a video's 16:9 card) instead of a square one: [size] is then its height. A 4:3 thumbnail fills it
  /// by its width and so loses its two bars on its own.
  final double? width;
  final double radius;

  /// Fetch the largest picture available and decode it whole, for covers shown big. Small covers
  /// are decoded at their own size to save memory.
  final bool sharp;

  /// The picture is wide and is cropped square: it is decoded by its height, as a decode by width would leave it
  /// too few pixels tall. For small covers; [sharp] ones are decoded whole. A video's thumbnail is always wide.
  final bool wide;

  /// When the picture changes, the old one fades into the new one. For the few covers that stay on screen as the song
  /// changes, not for the hundreds in a list.
  final bool crossfade;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Told to fill, not just asked to: in a cross-fade the switcher's stack loosens what its children are given, and a
    // placeholder that is only asked would shrink to the note, with square corners, in the middle of the cover's place
    final placeholder = SizedBox.expand(
      child: ColoredBox(
        color: p.primaryContainer,
        child: Center(
          child: Icon(
            Icons.music_note_rounded,
            color: p.primary.withValues(alpha: 0.6),
            size: size * 0.42,
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width ?? size,
        height: size,
        child: crossfade
            ? AnimatedSwitcher(
                duration: Motion.of(context, Motion.medium),
                // The default layout is a Stack that loosens what its children are given: a picture then takes its own
                // shape (a video's thumbnail, 16:9, in the middle of a square cover) instead of filling the cover. The
                // children are told to fill, as the placeholder is
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                child: KeyedSubtree(
                  key: ValueKey(url),
                  child: _picture(context, placeholder),
                ),
              )
            : _picture(context, placeholder),
      ),
    );
  }

  Widget _picture(BuildContext context, Widget placeholder) => url == null
      ? placeholder
      : _network(
          context,
          sharp ? sharpThumbnail(url!) : url!,
          placeholder,
          // Not every video has the enlarged picture: then the original will do
          onError: sharp && sharpThumbnail(url!) != url
              ? (_, _, _) => _network(context, url!, placeholder)
              : null,
        );

  Widget _network(
    BuildContext context,
    String address,
    Widget placeholder, {
    ImageErrorWidgetBuilder? onError,
  }) {
    var uri = Uri.tryParse(address);
    var bars = !sharp && width == null && _hasBars(uri);
    if (bars && size <= _smallCover) {
      address = barlessThumbnail(address);
      uri = Uri.tryParse(address);
      bars = false;
    }
    // Zoomed in to the picture between the bars, so it is decoded with a third more pixels
    final pixels =
        ((width ?? size) *
                MediaQuery.devicePixelRatioOf(context) *
                (bars ? 4 / 3 : 1))
            .round();
    // A wide picture cropped square would come out short of pixels if it were decoded by width; in a wide box it is
    // decoded by its width
    final byHeight = width == null && (wide || _videoId(uri) != null);
    Widget crop(Widget picture) =>
        bars ? Transform.scale(scale: 4 / 3, child: picture) : picture;
    return Image(
      image: ResizeImage.resizeIfNeeded(
        sharp || byHeight ? null : pixels,
        !sharp && byHeight ? pixels : null,
        CachedCover(address),
      ),
      fit: BoxFit.cover,
      errorBuilder: onError ?? (_, _, _) => placeholder,
      frameBuilder: (context, child, frame, sync) => sync
          ? crop(child)
          : Stack(
              fit: StackFit.expand,
              children: [
                placeholder,
                AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 300),
                  child: crop(child),
                ),
              ],
            ),
    );
  }
}
