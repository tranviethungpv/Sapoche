import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'scope.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final theme = Theme.of(context).textTheme;
    return SafeArea(
      bottom: false,
      child: ListView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, HomeShell.bottomInset),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Text(S.settingsTitle, style: theme.headlineLarge),
          ),
          _Group(
            title: S.appearance,
            children: [
              ListenableBuilder(
                listenable: model.settings,
                builder: (context, _) => SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    selectedBackgroundColor: context.palette.primaryContainer,
                    selectedForegroundColor: context.palette.onPrimaryContainer,
                    foregroundColor: context.palette.textSecondary,
                    side: BorderSide(color: context.palette.outline),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(S.themeSystem),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text(S.themeLight),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text(S.themeDark),
                    ),
                  ],
                  selected: {model.settings.themeMode},
                  onSelectionChanged: (s) => model.settings.themeMode = s.first,
                ),
              ),
            ],
          ),
          _Group(
            title: S.sync,
            footer: S.latencyTrimHelp,
            children: [_TrimRow(controller: model.room)],
          ),
          ListenableBuilder(
            listenable: model.room,
            builder: (context, _) {
              final snapshot = model.room.snapshot;
              return _Group(
                title: S.room,
                children: [
                  _Row(
                    label: S.roomCode,
                    value: snapshot.room ?? '',
                    trailing: Icon(
                      Icons.copy_rounded,
                      size: 18,
                      color: context.palette.textSecondary,
                    ),
                    onTap: () {
                      Clipboard.setData(
                        ClipboardData(text: snapshot.room ?? ''),
                      );
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          const SnackBar(content: Text(S.codeCopied)),
                        );
                    },
                  ),
                  _Row(
                    label: S.tabRoom,
                    value: S.listening(snapshot.members.length),
                  ),
                  _Row(
                    label: S.yourName,
                    value: snapshot.me?.name ?? '',
                    trailing: Icon(
                      Icons.edit_outlined,
                      size: 18,
                      color: context.palette.textSecondary,
                    ),
                    onTap: () => _rename(context, model.room),
                  ),
                  _Row(label: S.invite, onTap: model.room.shareInvite),
                  _Row(
                    label: S.leaveRoom,
                    destructive: true,
                    onTap: () => _confirmLeave(context, model.room),
                  ),
                ],
              );
            },
          ),
          _Group(
            title: S.diagnostics,
            footer: S.diagnosticsHelp,
            children: [
              _Row(
                label: S.copyLog,
                onTap: () async {
                  final lines = await model.room.log();
                  await Clipboard.setData(
                    ClipboardData(text: lines.join('\n')),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text(S.logCopied)));
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, RoomController room) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: room.snapshot.me?.name ?? ''),
    );
    if (name != null && name.isNotEmpty) room.rename(name);
  }

  Future<void> _confirmLeave(BuildContext context, RoomController room) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(S.leaveRoom),
        content: const Text(S.leaveQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              S.leave,
              style: TextStyle(color: context.palette.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) room.leave();
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _name.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(S.rename),
      content: TextField(
        controller: _name,
        autofocus: true,
        maxLength: 24,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          hintText: S.yourName,
          counterText: '',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(S.cancel),
        ),
        TextButton(onPressed: _submit, child: const Text(S.save)),
      ],
    );
  }
}

/// Rounded block of related rows with a small heading, like a settings group on iOS.
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children, this.footer});

  final String title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(
              title.toUpperCase(),
              style: theme.labelSmall?.copyWith(letterSpacing: 0.8),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: p.surfaceRaised.withValues(
                alpha: p.brightness == Brightness.dark ? 0.9 : 0.75,
              ),
              borderRadius: BorderRadius.circular(UnisonTheme.cardRadius),
              border: Border.all(color: p.outlineSoft),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, indent: 16, color: p.outlineSoft),
                  children[i],
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Text(footer!, style: theme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    this.value,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final String label;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.bodyLarge?.copyWith(
                  color: destructive ? p.error : p.text,
                ),
              ),
            ),
            if (value != null)
              Text(
                value!,
                style: theme.bodyLarge?.copyWith(color: p.textSecondary),
              ),
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          ],
        ),
      ),
    );
  }
}

class _TrimRow extends StatefulWidget {
  const _TrimRow({required this.controller});

  final RoomController controller;

  @override
  State<_TrimRow> createState() => _TrimRowState();
}

class _TrimRowState extends State<_TrimRow> {
  static const _limit = 300.0;
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final saved = widget.controller.snapshot.trimMs.toDouble();
        final value = (_dragging ?? saved).clamp(-_limit, _limit);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: Text(S.latencyTrim, style: theme.bodyLarge)),
                  Text(
                    '${value >= 0 ? '+' : '−'}${value.abs().round()} ms',
                    style: theme.bodyLarge?.copyWith(color: p.textSecondary),
                  ),
                  TextButton(
                    onPressed: saved == 0
                        ? null
                        : () => widget.controller.setTrim(0),
                    child: const Text(S.reset),
                  ),
                ],
              ),
              Slider(
                value: value,
                min: -_limit,
                max: _limit,
                divisions: (_limit * 2 / 10).round(),
                onChanged: (v) => setState(() => _dragging = v),
                onChangeEnd: (v) {
                  widget.controller.setTrim(v.round());
                  setState(() => _dragging = null);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
