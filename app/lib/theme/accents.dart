import 'package:flutter/material.dart';

import 'palette.dart';

/// The colours on offer for the app, by the id that [S.accentName] gives a name to. The first is the pink it was
/// designed in; a colour the person mixes themselves comes besides these.
const accentPresets = <(String, Color)>[
  ('pink', Palette.pinkAccent),
  ('red', Color(0xFFC8372D)),
  ('orange', Color(0xFFC25E00)),
  ('green', Color(0xFF2E7D4F)),
  ('teal', Color(0xFF00796B)),
  ('blue', Color(0xFF2F6FDE)),
  ('purple', Color(0xFF7B4FD1)),
  ('graphite', Color(0xFF5B5560)),
];

/// The id of the preset that [accent] is, or null when it is a colour of the person's own. Null [accent] is pink.
String? accentPresetId(Color? accent) {
  final value = (accent ?? Palette.pinkAccent).toARGB32();
  for (final (id, color) in accentPresets) {
    if (color.toARGB32() == value) return id;
  }
  return null;
}
