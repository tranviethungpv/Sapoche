import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// The notes of a release: a line that starts with "- " is a bullet, any other line is a heading.
class ReleaseNotesText extends StatelessWidget {
  const ReleaseNotesText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final lines = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    return Column(
      key: const ValueKey('release-notes'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          if (line.startsWith('- '))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 10, left: 2),
                    child: Text(
                      '•',
                      style: theme.bodyMedium?.copyWith(color: p.primary),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line.substring(2).trim(),
                      style: theme.bodyMedium,
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Text(line, style: theme.titleSmall),
            ),
      ],
    );
  }
}
