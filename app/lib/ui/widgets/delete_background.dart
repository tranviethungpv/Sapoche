import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// What shows behind a row that is swiped away to delete it.
class DeleteBackground extends StatelessWidget {
  const DeleteBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 28),
      color: p.error.withValues(alpha: 0.16),
      child: Icon(Icons.delete_outline_rounded, color: p.error),
    );
  }
}
