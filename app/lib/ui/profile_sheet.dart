import 'package:flutter/material.dart';

import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';
import 'widgets/avatars.dart';

/// Lets the person change the name others see and the picture of themselves, in a room or not.
Future<void> showProfileSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (_) =>
          AppScope(model: AppScope.of(context), child: const _ProfileSheet()),
    );

class _ProfileSheet extends StatefulWidget {
  const _ProfileSheet();

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  TextEditingController? _name;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final room = AppScope.roomOf(context);
    _name ??= TextEditingController(
      text: room.snapshot.me?.name ?? room.profile.name ?? '',
    );
  }

  @override
  void dispose() {
    _name?.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final model = AppScope.of(context);
    final bytes = await model.photoPicker();
    if (bytes == null) return;
    model.settings.avatar = bytes;
    model.room.shareAvatar(bytes);
  }

  void _save() {
    final name = _name!.text.trim();
    final room = AppScope.roomOf(context);
    if (name.isNotEmpty &&
        name != (room.snapshot.me?.name ?? room.profile.name)) {
      room.rename(name);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final model = AppScope.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(S.yourProfile, style: theme.titleLarge),
              ),
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: model.settings,
                builder: (context, _) => Column(
                  children: [
                    GestureDetector(
                      key: const ValueKey('profile-photo'),
                      onTap: _choose,
                      child: Avatar(
                        name: _name!.text,
                        size: 96,
                        image: model.settings.avatar,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          key: const ValueKey('profile-choose'),
                          onPressed: _choose,
                          child: Text(S.choosePhoto),
                        ),
                        if (model.settings.avatar != null)
                          TextButton(
                            key: const ValueKey('profile-remove'),
                            onPressed: () {
                              model.settings.avatar = null;
                              model.room.shareAvatar(null);
                            },
                            child: Text(S.removePhoto),
                          ),
                      ],
                    ),
                    Text(
                      S.photoOnlyHere,
                      textAlign: TextAlign.center,
                      style: theme.bodySmall?.copyWith(color: p.textTertiary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('profile-name'),
                controller: _name,
                maxLength: 24,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: S.yourName,
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('profile-save'),
                  onPressed: _save,
                  child: Text(S.save),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
