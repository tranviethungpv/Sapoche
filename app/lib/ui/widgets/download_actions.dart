import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../strings.dart';
import '../scope.dart';

/// Asks for [tracks] to be downloaded. On mobile data the person is asked first, since a playlist can be
/// a lot of it. Says what happened in a snackbar.
Future<void> startDownload(BuildContext context, List<Track> tracks) async {
  if (tracks.isEmpty) return;
  final library = AppScope.of(context).library;
  final messenger = ScaffoldMessenger.of(context);
  var started = await library.download(tracks);
  if (!started) {
    if (!context.mounted) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.useMobileData),
        content: Text(S.useMobileDataBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.download),
          ),
        ],
      ),
    );
    if (agreed != true) return;
    started = await library.download(tracks, allowMetered: true);
  }
  if (!started) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(S.downloadStarted(tracks.length))));
}
