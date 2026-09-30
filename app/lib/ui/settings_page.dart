import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library_controller.dart';
import '../data/models.dart';
import '../data/room_controller.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'scope.dart';
import 'widgets/avatars.dart';
import 'widgets/text_dialog.dart';

/// A short list of topics; each opens a page of its own, so no page grows long.
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
          _ProfileCard(room: model.room),
          _Group(
            children: [
              ListenableBuilder(
                listenable: model.settings,
                builder: (context, _) => _NavRow(
                  key: const ValueKey('settings-appearance'),
                  icon: Icons.palette_outlined,
                  label: S.appearance,
                  value: switch (model.settings.themeMode) {
                    ThemeMode.system => S.themeSystem,
                    ThemeMode.light => S.themeLight,
                    ThemeMode.dark => S.themeDark,
                  },
                  onTap: () => _open(context, S.appearance, _appearance),
                ),
              ),
              _NavRow(
                key: const ValueKey('settings-playback'),
                icon: Icons.play_circle_outline_rounded,
                label: S.playback,
                onTap: () => _open(context, S.playback, _playback),
              ),
              ListenableBuilder(
                listenable: model.room,
                builder: (context, _) {
                  final snapshot = model.room.snapshot;
                  if (!snapshot.inRoom) return const SizedBox.shrink();
                  return _NavRow(
                    key: const ValueKey('settings-room'),
                    icon: Icons.groups_outlined,
                    label: S.room,
                    value: snapshot.room,
                    onTap: () => _open(context, S.room, _room),
                  );
                },
              ),
              _NavRow(
                key: const ValueKey('settings-storage'),
                icon: Icons.download_for_offline_outlined,
                label: S.storage,
                onTap: () => _open(context, S.storage, _storage),
              ),
              _NavRow(
                key: const ValueKey('settings-backup'),
                icon: Icons.backup_outlined,
                label: S.backup,
                onTap: () => _open(context, S.backup, _backup),
              ),
            ],
          ),
          _Group(
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

  void _open(
    BuildContext context,
    String title,
    List<Widget> Function(BuildContext context, AppModel model) children,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _SubPage(
          title: title,
          children: children(context, AppScope.of(context)),
        ),
      ),
    );
  }

  static List<Widget> _appearance(BuildContext context, AppModel model) => [
    _Group(
      children: [
        ListenableBuilder(
          listenable: model.settings,
          builder: (context, _) => SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
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
              ButtonSegment(value: ThemeMode.light, label: Text(S.themeLight)),
              ButtonSegment(value: ThemeMode.dark, label: Text(S.themeDark)),
            ],
            selected: {model.settings.themeMode},
            onSelectionChanged: (s) => model.settings.themeMode = s.first,
          ),
        ),
      ],
    ),
  ];

  static List<Widget> _playback(BuildContext context, AppModel model) => [
    _Group(
      title: S.autoplay,
      footer: S.autoplayHelp,
      children: [
        ListenableBuilder(
          listenable: model.room,
          builder: (context, _) => Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              title: const Text(S.autoplay),
              value: model.room.autoplay,
              onChanged: model.room.setAutoplay,
            ),
          ),
        ),
      ],
    ),
    _Group(
      title: S.videoSection,
      footer: S.videoQualityHelp,
      children: [
        ListenableBuilder(
          listenable: model.room,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              style: SegmentedButton.styleFrom(
                backgroundColor: Colors.transparent,
                selectedBackgroundColor: context.palette.primaryContainer,
                selectedForegroundColor: context.palette.onPrimaryContainer,
                foregroundColor: context.palette.textSecondary,
                side: BorderSide(color: context.palette.outline),
              ),
              segments: [
                for (final h in const [360, 480, 720, 1080])
                  ButtonSegment(value: h, label: Text('${h}p')),
              ],
              selected: {model.room.snapshot.videoHeight},
              onSelectionChanged: (s) => model.room.setVideoQuality(s.first),
            ),
          ),
        ),
      ],
    ),
    _Group(
      title: S.sync,
      footer: S.latencyTrimHelp,
      children: [_TrimRow(controller: model.room)],
    ),
  ];

  static List<Widget> _storage(BuildContext context, AppModel model) => [
    _StorageGroup(library: model.library),
  ];

  static List<Widget> _backup(BuildContext context, AppModel model) => [
    _BackupGroup(library: model.library),
  ];

  static List<Widget> _room(BuildContext context, AppModel model) => [
    _RoomGroup(room: model.room),
  ];
}

/// The room this device is in: its code, who is there, the name shown, inviting and leaving.
class _RoomGroup extends StatelessWidget {
  const _RoomGroup({required this.room});

  final RoomController room;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final snapshot = room.snapshot;
        if (!snapshot.inRoom) {
          // The room was left from this page: nothing left to show
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).maybePop();
          });
          return const SizedBox.shrink();
        }
        return _Group(
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
                Clipboard.setData(ClipboardData(text: snapshot.room ?? ''));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(content: Text(S.codeCopied)));
              },
            ),
            _Row(label: S.tabRoom, value: S.listening(snapshot.members.length)),
            _Row(
              label: S.yourName,
              value: snapshot.me?.name ?? '',
              trailing: Icon(
                Icons.edit_outlined,
                size: 18,
                color: context.palette.textSecondary,
              ),
              onTap: () => _rename(context),
            ),
            _Row(label: S.invite, onTap: room.shareInvite),
            _Row(
              label: S.leaveRoom,
              destructive: true,
              onTap: () => _confirmLeave(context),
            ),
          ],
        );
      },
    );
  }

  Future<void> _rename(BuildContext context) async {
    final name = await showTextDialog(
      context,
      title: S.rename,
      hint: S.yourName,
      initial: room.snapshot.me?.name ?? '',
    );
    if (name != null && name.isNotEmpty) room.rename(name);
  }

  Future<void> _confirmLeave(BuildContext context) async {
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

/// What the songs kept on the phone take, and the settings that go with them.
class _StorageGroup extends StatefulWidget {
  const _StorageGroup({required this.library});

  final LibraryController library;

  @override
  State<_StorageGroup> createState() => _StorageGroupState();
}

class _StorageGroupState extends State<_StorageGroup> {
  StorageInfo _info = const StorageInfo();

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.library.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final info = await widget.library.storage();
    if (info != null && mounted) setState(() => _info = info);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final library = widget.library;
    return _Group(
      footer: S.cacheLimitHelp,
      children: [
        _Row(
          label: S.storageDownloads,
          value:
              '${S.songCount(_info.downloadCount)} · ${formatBytes(_info.downloadBytes)}',
        ),
        _Row(
          label: S.storagePlayed,
          value: '${formatBytes(_info.playBytes)} / ${_info.playLimitMb} MB',
          trailing: TextButton(
            onPressed: _info.playBytes == 0
                ? null
                : () async {
                    await library.clearPlayCache();
                    _load();
                  },
            child: const Text(S.clearCache),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(S.cacheLimit, style: theme.bodyMedium),
              ),
              SegmentedButton<int>(
                showSelectedIcon: false,
                expandedInsets: EdgeInsets.zero,
                style: SegmentedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  selectedBackgroundColor: p.primaryContainer,
                  selectedForegroundColor: p.onPrimaryContainer,
                  foregroundColor: p.textSecondary,
                  side: BorderSide(color: p.outline),
                ),
                segments: [
                  for (final mb in const [128, 256, 512, 1024])
                    ButtonSegment(
                      value: mb,
                      label: Text(mb == 1024 ? '1 GB' : '$mb MB'),
                    ),
                ],
                selected: {_info.playLimitMb},
                onSelectionChanged: (s) async {
                  await library.setCacheLimit(s.first);
                  _load();
                },
              ),
            ],
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile(
            title: const Text(S.autoDownload),
            subtitle: const Text(S.autoDownloadHelp),
            value: _info.autoDownload,
            onChanged: (on) async {
              await library.setAutoDownload(on);
              _load();
            },
          ),
        ),
      ],
    );
  }
}

/// Rounded block of related rows with a small heading, like a settings group on iOS.
/// Saves the library to a file and adds one back, for a new phone or after a reinstall.
class _BackupGroup extends StatelessWidget {
  const _BackupGroup({required this.library});

  final LibraryController library;

  void _say(BuildContext context, String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save(BuildContext context) async {
    final saved = await library.exportBackup();
    if (saved == null || !context.mounted) return;
    _say(
      context,
      saved.isEmpty
          ? S.backupEmpty
          : S.backupSaved(saved.liked, saved.playlists, saved.listens),
    );
  }

  Future<void> _add(BuildContext context) async {
    final added = await library.importBackup();
    if (added == null || !context.mounted) return;
    _say(
      context,
      added.isEmpty
          ? S.backupNothingNew
          : S.backupAdded(added.liked, added.playlists, added.listens),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return _Group(
      footer: S.backupHelp,
      children: [
        _Row(
          label: S.backupSave,
          trailing: Icon(Icons.save_alt_rounded, color: p.textTertiary),
          onTap: () => _save(context),
        ),
        _Row(
          label: S.backupAdd,
          trailing: Icon(Icons.file_open_outlined, color: p.textTertiary),
          onTap: () => _add(context),
        ),
      ],
    );
  }
}

/// A page of one topic, opened from the settings list.
class _SubPage extends StatelessWidget {
  const _SubPage({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: children,
      ),
    );
  }
}

/// Who this is and where: the name shown to others and the room, if any.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.room});

  final RoomController room;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final snapshot = room.snapshot;
        final name = snapshot.me?.name ?? room.profile.name ?? '';
        return _Group(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Avatar(name: name, size: 52),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name.isEmpty ? S.appName : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.titleLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          snapshot.inRoom
                              ? '${S.room} ${snapshot.room} · ${S.listening(snapshot.members.length)}'
                              : S.noRoom,
                          style: theme.bodyMedium?.copyWith(
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A row of the settings list that opens a page.
class _NavRow extends StatelessWidget {
  const _NavRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return _Row(
      label: label,
      value: value,
      leading: Icon(icon, color: p.primary),
      trailing: Icon(Icons.chevron_right_rounded, color: p.textTertiary),
      onTap: onTap,
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({this.title, required this.children, this.footer});

  final String? title;
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
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                title!.toUpperCase(),
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
    this.leading,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final String label;
  final String? value;
  final Widget? leading;
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
            if (leading != null) ...[leading!, const SizedBox(width: 14)],
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
