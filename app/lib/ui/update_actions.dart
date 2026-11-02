import 'package:flutter/material.dart';

import '../data/update_controller.dart';
import '../strings.dart';

/// Fetches the version on offer, asking first when it would use mobile data.
Future<void> downloadUpdate(
  BuildContext context,
  UpdateController update,
) async {
  if (await update.download()) return;
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
          child: Text(S.updateDownload),
        ),
      ],
    ),
  );
  if (agreed == true) await update.download(allowMetered: true);
}

/// Installing closes the app, so the person is told before it happens.
Future<void> installUpdate(
  BuildContext context,
  UpdateController update,
) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(S.updateRestartTitle),
      content: Text(S.updateRestartBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(S.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(S.updateInstall),
        ),
      ],
    ),
  );
  if (agreed != true) return;
  if (await update.install() || !context.mounted) return;
  // Android has not yet allowed this app to install: say so, and take the person to the page for it
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(S.updatePermissionTitle),
      content: Text(S.updatePermissionBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(S.cancel),
        ),
        TextButton(
          key: const ValueKey('update-open-settings'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(S.updateOpenSettings),
        ),
      ],
    ),
  );
  if (open == true) await update.allowInstalls();
}
