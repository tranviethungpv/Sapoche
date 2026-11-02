import 'package:flutter/material.dart';

import '../data/update_controller.dart';
import '../data/update_info.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'update_actions.dart';
import 'widgets/release_notes_text.dart';

/// Tells the person a newer version is there and lets them take it now or later. It never blocks: it closes with a
/// swipe, a tap outside or "Later".
Future<void> showUpdateSheet(BuildContext context, UpdateController update) =>
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (_) => _UpdateSheet(update: update),
    );

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({required this.update});

  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final info = update.info;
    final version = info.version ?? '';
    final ready = info.phase == UpdatePhase.ready;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ready
                  ? S.updateSheetReady(version)
                  : S.updateSheetAvailable(version),
              style: theme.titleLarge,
            ),
            if (info.size > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  formatBytes(info.size),
                  style: theme.bodySmall?.copyWith(color: p.textSecondary),
                ),
              ),
            if (info.notes != null) ...[
              const SizedBox(height: 14),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.32,
                  ),
                  child: SingleChildScrollView(
                    child: ReleaseNotesText(info.notes!),
                  ),
                ),
              ),
            ],
            if (ready) ...[
              const SizedBox(height: 8),
              Text(
                S.updateSheetStops,
                style: theme.bodySmall?.copyWith(color: p.textSecondary),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('update-sheet-now'),
                    onPressed: () {
                      final navigator = Navigator.of(context);
                      final parent = navigator.context;
                      navigator.pop();
                      if (ready) {
                        installUpdate(parent, update);
                      } else {
                        downloadUpdate(parent, update);
                      }
                    },
                    child: Text(S.updateNow),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  key: const ValueKey('update-sheet-later'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(S.updateLater),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
