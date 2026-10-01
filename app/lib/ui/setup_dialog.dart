import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/room_controller.dart';
import '../data/setup_link.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'widgets/qr_code_view.dart';

/// Shows this phone's server and key as a code another phone can scan, so that a phone without them (an iPhone) is set
/// up without typing the key.
Future<void> showSetupLinkDialog(BuildContext context, RoomController room) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(S.setupAnother),
      content: FutureBuilder<String?>(
        future: room.setupLink(),
        builder: (context, snapshot) {
          final link = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (link == null) return Text(S.setupNone);
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                QrCodeView(data: link, size: 220),
                const SizedBox(height: 14),
                Text(
                  S.setupAnotherHelp,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: context.palette.textSecondary),
                ),
                const SizedBox(height: 6),
                TextButton.icon(
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(S.setupCopy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: link));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(content: Text(S.setupCopied)));
                    }
                  },
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(S.close),
        ),
      ],
    ),
  );
}

/// Asks whether to use the server a link names, and uses it if so. The link could have come from anyone, and the key
/// is sent to the server it names, so nothing is set without a yes.
Future<void> askToUseSetup(
  BuildContext context,
  RoomController room,
  SetupLink link,
) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(S.setupUseTitle),
      content: Text(S.setupUseBody(link.host)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(S.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(S.setupUse),
        ),
      ],
    ),
  );
  if (agreed != true) return;
  await room.configure(
    server: link.server,
    key: link.key.isEmpty ? null : link.key,
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.setupDone)));
  }
}
