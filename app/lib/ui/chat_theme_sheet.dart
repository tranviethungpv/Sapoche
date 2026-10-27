import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/chat_theme.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../data/photo_picker.dart';
import 'chat_look.dart';
import 'chat_wallpaper_editor.dart';
import 'scope.dart';

/// The looks the chat of the room can have. One touch on a look is the choice: the room has it at once, for everyone.
Future<void> showChatThemeSheet(BuildContext context, RoomController room) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (_) => AppScope(
        model: AppScope.of(context),
        child: _ChatThemeSheet(room: room),
      ),
    );

class _ChatThemeSheet extends StatelessWidget {
  const _ChatThemeSheet({required this.room});

  final RoomController room;

  Future<void> _fromPhoto(BuildContext context) async {
    final model = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final photo = await model.wallpaperPicker();
    if (photo == null || !context.mounted) return;
    final choice = await showWallpaperEditor(context, photo);
    if (choice == null) return;
    if (base64Encode(choice.picture).length > maxWallpaperChars) {
      messenger.showSnackBar(SnackBar(content: Text(S.chatThemeUnreadable)));
      return;
    }
    room.setTheme(choice.theme.id, background: choice.picture);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final snapshot = room.snapshot;
        final current = snapshot.theme ?? ChatTheme.none;
        final may = snapshot.canControl;
        final custom = current.startsWith('c-')
            ? ChatTheme.parse(current)
            : null;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.chatTheme, style: text.headlineSmall),
                const SizedBox(height: 2),
                Text(
                  may ? S.chatThemeShared : S.chatThemeLocked,
                  style: text.bodyMedium?.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: 16),
                Opacity(
                  opacity: may ? 1 : 0.5,
                  child: IgnorePointer(
                    ignoring: !may,
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 14,
                      children: [
                        _Tile(
                          id: ChatTheme.none,
                          label: S.chatThemeName(ChatTheme.none),
                          selected: current == ChatTheme.none,
                          onTap: () => room.setTheme(ChatTheme.none),
                        ),
                        for (final preset in ChatTheme.presets)
                          _Tile(
                            id: preset.id,
                            label: S.chatThemeName(preset.id),
                            selected: current == preset.id,
                            onTap: () => room.setTheme(preset.id),
                          ),
                        if (custom != null)
                          _Tile(
                            id: custom.id,
                            label: S.chatThemeName(custom.id),
                            selected: true,
                            picture: room.background,
                            onTap: () {},
                          ),
                        _Tile(
                          key: const ValueKey('chat-theme-photo'),
                          label: S.chatThemeFromPhoto,
                          icon: Icons.add_photo_alternate_outlined,
                          onTap: () => _fromPhoto(context),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  S.chatThemeFromPhotoHint,
                  style: text.bodySmall?.copyWith(color: p.textTertiary),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A look as the chat would show it, small: the background, a message of someone else and one of this device.
class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    this.id,
    required this.label,
    this.icon,
    this.selected = false,
    this.picture,
    required this.onTap,
  });

  /// The photo behind the chat of this look, if it has one.
  final Uint8List? picture;

  /// The theme it shows; null for the tile that makes a new one.
  final String? id;
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  /// Four of them fit across a phone.
  static const _width = 76.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final look = ChatLook.of(id, p, picture: picture);
    final accent = look?.accent ?? p.primary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        key: id == null ? null : ValueKey('chat-theme-$id'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: _width,
          child: Column(
            children: [
              Container(
                width: _width,
                height: 112,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected ? accent : p.outlineSoft,
                    width: selected ? 2.5 : 1,
                  ),
                  gradient: id == null || look != null
                      ? null
                      : LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [p.base, p.primaryContainer],
                        ),
                  color: id == null ? p.veil : null,
                ),
                child: id == null
                    ? Icon(icon, color: p.primary, size: 30)
                    : ChatBackdrop(
                        look: look,
                        sheet: p.base,
                        child: _Preview(
                          look: look,
                          palette: p,
                          selected: selected,
                        ),
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: selected ? p.text : p.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.look,
    required this.palette,
    required this.selected,
  });

  final ChatLook? look;
  final Palette palette;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    Widget bubble(double width, {required bool mine}) => Container(
      width: width,
      height: 16,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: look != null
            ? (mine ? null : look!.theirs)
            : mine
            ? palette.primary
            : palette.primary.withValues(alpha: 0.1),
        gradient: look != null && mine ? look!.mine : null,
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Stack(
        children: [
          Positioned(left: 0, top: 6, child: bubble(44, mine: false)),
          Positioned(left: 0, top: 28, child: bubble(30, mine: false)),
          Positioned(right: 0, top: 52, child: bubble(48, mine: true)),
          Positioned(right: 0, top: 74, child: bubble(32, mine: true)),
          if (selected)
            Positioned(
              right: -2,
              top: -2,
              child: Icon(
                Icons.check_circle_rounded,
                size: 18,
                color: look?.accent ?? palette.primary,
              ),
            ),
        ],
      ),
    );
  }
}
