import 'package:flutter/material.dart';

/// The line under a title: who or what it is by ([text]), and, apart from that, what kind of thing it is ([lead], "Song")
/// and a count ([meta], "205M plays"). A field is shown whole or not at all: when the row is narrow the kind goes first,
/// then the count, and only the name is cut, with "…", once it is alone. A count cut in half, or kept beside a name cut
/// short, reads as a mistake. With neither it is the text alone.
class MetaLine extends StatelessWidget {
  const MetaLine({super.key, required this.text, this.meta, this.lead, this.style});

  final String text;
  final String? meta;
  final String? lead;
  final TextStyle? style;

  static const _join = ' · ';

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(this.style);
    List<String> fields({required bool kind, required bool count}) => [
      if (kind && lead != null && lead!.isNotEmpty) lead!,
      if (text.isNotEmpty) text,
      if (count && meta != null && meta!.isNotEmpty) meta!,
    ];
    return LayoutBuilder(
      builder: (context, box) {
        double width(String line) => (TextPainter(
          text: TextSpan(text: line, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout()).width;
        Widget line(String text) =>
            // softWrap off: with it on, the line breaks at a word and cuts there, leaving room unused
            Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: this.style);
        // The most that fits, from all of it down to the name alone
        for (final (kind, count) in [(true, true), (false, true)]) {
          final joined = fields(kind: kind, count: count).join(_join);
          if (width(joined) <= box.maxWidth) return line(joined);
        }
        return line(fields(kind: false, count: false).join(_join));
      },
    );
  }
}
