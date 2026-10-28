import 'package:flutter/material.dart';

import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';

/// Says so when the library file could not be opened and an empty one stands in (iPhone): nothing changed meanwhile is
/// kept, and a backup restored into it would go with it. Nothing at all while the library is there.
class LibraryLostNotice extends StatelessWidget {
  const LibraryLostNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final room = AppScope.roomOf(context);
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        if (!room.profile.libraryLost) return const SizedBox.shrink();
        final p = context.palette;
        return Container(
          margin: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: p.primaryContainer,
            borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: p.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.libraryLostTitle,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: p.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      S.libraryLostBody,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: p.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
