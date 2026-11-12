import 'strings.dart';

/// "3:07" or "1:02:03".
String formatDuration(int ms) {
  final total = (ms < 0 ? 0 : ms) ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// "2.4 s" for a lag in ms.
String formatLag(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';

/// "12 ms ahead" style text for the sync indicator.
String formatDrift(int ms) => '${ms >= 0 ? '+' : '−'}${ms.abs()} ms';

/// "340 KB", "12.4 MB" or "1.3 GB".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// A count as short as a row can hold it: "430", "1.8B", "155M" ("1,8 Tỷ", "155 Tr" in Vietnamese).
String formatCount(int n) {
  if (n < 1000) return '$n';
  const units = [1e3, 1e6, 1e9];
  final names = [S.unitThousand, S.unitMillion, S.unitBillion];
  var i = n >= 1e9 ? 2 : (n >= 1e6 ? 1 : 0);
  var value = n / units[i];
  // 999.6K is 1M, not "1000K"
  if (value.round() >= 1000 && i < 2) value = n / units[++i];
  final text = value < 10 ? value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '') : value.round().toString();
  return '${text.replaceFirst('.', S.decimalSeparator)}${names[i]}';
}

/// "1.8B views" or "155M plays" in the language of the app, for a count and whether it counts plays of a song.
String formatViews(int count, {bool plays = false}) =>
    plays ? S.playCount(formatCount(count)) : S.viewCount(formatCount(count));

/// [views] as [formatViews] wrote it, without the word after the number: "5.4M plays" is "5.4M".
String shortViews(String views) {
  for (final label in [S.playCount(''), S.viewCount('')]) {
    if (views.endsWith(label)) {
      return views.substring(0, views.length - label.length);
    }
  }
  return views;
}

final _viewsEnd = RegExp(r'\b(views?|plays?|listens?)\s*$', caseSensitive: false);
final _viewsSegment = RegExp(r'^\s*([\d.,]+)\s*([KMB])?\s*(views?|plays?|listens?)\s*$', caseSensitive: false);

/// YouTube writes "1.8B views · 19M likes", or "Anna · 1.2M views" for a playlist (in English: the app asks for
/// that). Splits it into what is left once the views or plays are taken out, and those, said in the language of the
/// app. Likes are dropped with whatever else comes after the views; a line with no views is left alone, and views
/// that cannot be read are kept as YouTube wrote them.
({String text, String? views}) splitViews(String? line) {
  if (line == null || line.isEmpty) return (text: '', views: null);
  final parts = line.split(RegExp(r'\s[·•]\s'));
  final at = parts.lastIndexWhere(_viewsEnd.hasMatch);
  if (at < 0) return (text: line, views: null);
  final segment = parts[at].trim();
  final rest = parts.take(at).join(' · ');
  final match = _viewsSegment.firstMatch(segment);
  final number = match?.group(1)!;
  final base = number == null ? null : double.tryParse(number.replaceAll(',', ''));
  final unit = match?.group(2)?.toUpperCase();
  // "1.234 views" is a number written another way: leave it as it is
  if (base == null || (unit == null && number!.contains('.'))) return (text: rest, views: segment);
  final times = switch (unit) {
    'K' => 1e3,
    'M' => 1e6,
    'B' => 1e9,
    _ => 1.0,
  };
  final plays = !match!.group(3)!.toLowerCase().startsWith('v');
  return (text: rest, views: formatViews((base * times).round(), plays: plays));
}
