import 'package:flutter/widgets.dart';

/// Most emoji a message may hold and still be drawn big, without a bubble.
const maxBigEmoji = 3;

/// An emoji as the keyboards give it: pictographs, flags, skin tones, joined and keycap forms.
final _emoji = RegExp(
  // ignore: valid_regexps
  r'^(?:\p{Extended_Pictographic}|\p{Emoji_Component}|\u200D|\uFE0F)+$',
  unicode: true,
);

/// Digits, `#` and `*` are emoji components too (the base of a keycap), but alone they are just text.
final _plain = RegExp(r'^[0-9#*]+$');

/// How many emoji [text] is made of when it is nothing but one to [maxBigEmoji] of them, else null.
int? emojiOnly(String text) {
  final clusters = text.trim().characters;
  if (clusters.isEmpty || clusters.length > maxBigEmoji) return null;
  for (final c in clusters) {
    if (!_emoji.hasMatch(c) || _plain.hasMatch(c)) return null;
  }
  return clusters.length;
}

/// The size a message of [count] emoji is drawn at: the fewer, the bigger.
double bigEmojiSize(int count) => switch (count) {
  1 => 48,
  2 => 40,
  _ => 32,
};
