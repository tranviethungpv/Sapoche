/// "3:07" or "1:02:03".
String formatDuration(int ms) {
  final total = (ms < 0 ? 0 : ms) ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// "12 ms ahead" style text for the sync indicator.
String formatDrift(int ms) => '${ms >= 0 ? '+' : '−'}${ms.abs()} ms';
