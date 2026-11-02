import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/ios_update.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'widgets/release_notes_text.dart';

/// Tells an iPhone a newer version is out and takes the person to its page; SideStore, not the app, installs it. It never
/// blocks: it closes with a swipe, a tap outside or "Later".
Future<void> showIosUpdateSheet(BuildContext context, ReleaseOffer offer) =>
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      builder: (_) => _IosUpdateSheet(offer: offer),
    );

class _IosUpdateSheet extends StatelessWidget {
  const _IosUpdateSheet({required this.offer});

  final ReleaseOffer offer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.updateSheetAvailable(offer.version), style: theme.titleLarge),
            if (offer.notes.isNotEmpty) ...[
              const SizedBox(height: 14),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.32,
                  ),
                  child: SingleChildScrollView(
                    child: ReleaseNotesText(offer.notes),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              S.updateViaSideStore,
              style: theme.bodySmall?.copyWith(color: p.textSecondary),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('ios-update-open'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      launchUrl(
                        Uri.parse(offer.url),
                        mode: LaunchMode.externalApplication,
                      );
                    },
                    child: Text(S.updateOpenRelease),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  key: const ValueKey('ios-update-later'),
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
