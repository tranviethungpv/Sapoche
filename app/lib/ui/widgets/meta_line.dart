import 'package:flutter/material.dart';

/// The line under a title: [text] gives way (is cut with "…") when the row is narrow, and [meta], a count, never does.
/// With no [meta] it is the text alone.
class MetaLine extends StatelessWidget {
  const MetaLine({super.key, required this.text, this.meta, this.style});

  final String text;
  final String? meta;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final meta = this.meta;
    if (meta == null) return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    if (text.isEmpty) return Text(meta, maxLines: 1, softWrap: false, style: style);
    return Row(
      children: [
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
        Text(' · $meta', maxLines: 1, softWrap: false, style: style),
      ],
    );
  }
}
