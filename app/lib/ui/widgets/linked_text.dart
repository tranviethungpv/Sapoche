import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../data/web/youtube_links.dart';
import '../../strings.dart';
import '../scope.dart';
import '../song_info_sheet.dart';

/// The web addresses in [text]: where each starts and ends, trailing punctuation left out (a link at the end of a
/// sentence does not own its full stop, nor does one in brackets own the bracket).
List<({int start, int end})> findLinks(String text) {
  final found = <({int start, int end})>[];
  for (final match in _link.allMatches(text)) {
    var end = match.end;
    while (end > match.start && '.,;:!?\'"”’'.contains(text[end - 1])) {
      end--;
    }
    // A closing bracket belongs to the link only where it has an opening one of its own (Wikipedia pages)
    while (end > match.start && ')]}'.contains(text[end - 1])) {
      final link = text.substring(match.start, end);
      final close = text[end - 1];
      final open = close == ')' ? '(' : (close == ']' ? '[' : '{');
      if (open.allMatches(link).length >= close.allMatches(link).length) break;
      end--;
    }
    if (end - match.start > 6) found.add((start: match.start, end: end));
  }
  return found;
}

/// The address as it is opened: a bare `www.` one has no scheme.
Uri? linkUri(String link) => Uri.tryParse(link.toLowerCase().startsWith('www.') ? 'https://$link' : link);

/// The first link in [text] that is to one song of YouTube or YouTube Music (not a playlist, not a channel); null where there
/// is none.
String? songLinkIn(String text) {
  for (final (:start, :end) in findLinks(text)) {
    final link = text.substring(start, end);
    final host = linkUri(link)?.host.toLowerCase() ?? '';
    final isYoutube = host == 'youtu.be' || host == 'youtube.com' || host.endsWith('.youtube.com');
    if (isYoutube && YoutubeLinks.videoId(link) != null) return link;
  }
  return null;
}

final _link = RegExp(r'(?:https?://|www\.)[^\s<>]+', caseSensitive: false);

/// [text] with its web addresses underlined and touchable: a link to a song of YouTube opens what the app knows of the
/// song, any other opens in the browser.
class LinkedText extends StatefulWidget {
  const LinkedText({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  /// Opens an address outside the app; the tests put their own.
  @visibleForTesting
  static Future<bool> Function(Uri uri) launcher = (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _open(String link) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = linkUri(link);
    if (uri == null || !uri.hasAuthority) return;
    if (await _openSong(link)) return;
    var opened = false;
    try {
      opened = await LinkedText.launcher(uri);
    } on Object {
      opened = false;
    }
    if (!opened) messenger?.showSnackBar(SnackBar(content: Text(S.linkCannotOpen)));
  }

  /// A link to one song of YouTube or YouTube Music shows what the app knows of the song; false for any other link, or
  /// when the song cannot be looked up (then the browser has it).
  Future<bool> _openSong(String link) async {
    if (songLinkIn(link) == null) return false;
    final room = AppScope.of(context).room;
    final result = await room.lookup(link).then<LinkResult?>((r) => r, onError: (Object _) => null);
    final track = result == null || result.isPlaylist || result.tracks.isEmpty ? null : result.tracks.first;
    if (track == null || !mounted) return false;
    showSongInfo(
      context,
      QueueEntry(
        id: '',
        videoId: track.videoId,
        title: track.title,
        artist: track.artist,
        durMs: track.durMs,
        addedBy: '',
        thumb: track.thumb,
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final text = widget.text;
    final links = findLinks(text);
    if (links.isEmpty) return Text(text, style: widget.style);
    final spans = <InlineSpan>[];
    var at = 0;
    for (final (:start, :end) in links) {
      if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
      final link = text.substring(start, end);
      final recognizer = TapGestureRecognizer()..onTap = () => _open(link);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: link,
          recognizer: recognizer,
          style: const TextStyle(decoration: TextDecoration.underline, fontWeight: FontWeight.w600),
        ),
      );
      at = end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(children: spans), style: widget.style);
  }
}
