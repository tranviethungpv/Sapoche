import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/connect/connect_client.dart';
import '../data/connect/connect_controller.dart';
import '../data/connect/connect_wire.dart';
import '../data/room_controller.dart';
import '../data/tv_mode.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'scope.dart';
import 'sync_dialogs.dart';
import 'widgets/motion.dart';
import 'widgets/sheet_tile.dart';
import 'widgets/text_dialog.dart';
import 'widgets/volume_bar.dart';

/// The devices of the person, or null where there are none to show (the tests, a build with nothing to sync with).
ConnectController? connectOf(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()?.model.connect;

/// The button of where the sound goes is on every player: the apps always had it, and a browser has it once there are other
/// devices to move the sound to (there is no list of outputs to open in a browser).
bool showsConnectButton(BuildContext context) => !kIsWeb || connectOf(context) != null;

/// Another device plays and this one steers it, as far as the screens are concerned (they are not in a room then).
bool controllingAnother(BuildContext context) => connectOf(context)?.controlling ?? false;

/// Whether the picture of the song is on: the playing device's when another one plays (the switch of Audio and Video is a remote
/// for it, and follows it), else this device's own.
bool videoShown(BuildContext context, RoomController room) => connectOf(context)?.remoteVideo ?? room.snapshot.video;

IconData deviceIcon(DeviceKind kind) => switch (kind) {
  DeviceKind.phone => Icons.smartphone_rounded,
  DeviceKind.tablet => Icons.tablet_android_rounded,
  DeviceKind.tv => Icons.tv_rounded,
  DeviceKind.computer => Icons.laptop_rounded,
  DeviceKind.web => Icons.language_rounded,
  DeviceKind.iphone => Icons.phone_iphone_rounded,
  DeviceKind.ipad => Icons.tablet_mac_rounded,
};

IconData _outputIcon(String kind) => switch (kind) {
  'headphones' => Icons.headphones_rounded,
  'bluetooth' => Icons.bluetooth_audio_rounded,
  'airplay' => Icons.airplay_rounded,
  'car' => Icons.directions_car_rounded,
  'other' => Icons.speaker_group_rounded,
  _ => Icons.speaker_rounded,
};

/// What the button says: the device that plays while another does, else where the sound goes on this one.
({IconData icon, String tooltip, bool lit}) connectLook(BuildContext context, RoomController room) {
  final connect = connectOf(context);
  final output = room.output;
  if (connect != null && connect.controlling) {
    final device = connect.activeDevice!;
    return (
      icon: deviceIcon(device.info?.kind ?? DeviceKind.phone),
      tooltip: S.playOnDevice(device.info?.name ?? ''),
      lit: true,
    );
  }
  return (
    icon: _outputIcon(output.kind),
    tooltip: output.name.isEmpty ? S.playOn : '${S.playOn} · ${output.name}',
    lit: output.kind != 'speaker',
  );
}

/// Opens the list of devices to play on (or, where there is none, the system's list of outputs, as it always did).
void openConnect(BuildContext context, RoomController room) {
  if (connectOf(context) == null) {
    room.pickOutput();
  } else {
    showConnectSheet(context, room);
  }
}

/// The line under the title of a bar while another device plays: where the sound is, in the colour of the app.
class PlayingOnLine extends StatelessWidget {
  const PlayingOnLine({super.key, required this.device, this.style});

  final ConnectDevice device;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Icon(deviceIcon(device.info?.kind ?? DeviceKind.phone), size: 14, color: p.primary),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            S.playingOn(device.info?.name ?? ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (style ?? Theme.of(context).textTheme.bodySmall)?.copyWith(color: p.primary),
          ),
        ),
      ],
    );
  }
}

/// While this device steers another, the buttons of the phone's volume are for that one's volume (as in Spotify), not for the
/// phone's own: a press moves the volume of the playing device by a step, and a small bar says where it is. On Android the
/// activity takes the keys itself, before any view and before the system (`MainActivity.dispatchKeyEvent`, which is told by
/// `steer` when to do it), so that they never depend on which view has the focus. An iPhone has no keys to catch (its buttons
/// move the phone's volume, which the controller takes as a press: `buttonsAreLevels`), and a TV leaves them to the TV, whose
/// volume they are.
class RemoteVolumeKeys extends StatefulWidget {
  const RemoteVolumeKeys({super.key});

  @override
  State<RemoteVolumeKeys> createState() => _RemoteVolumeKeysState();
}

class _RemoteVolumeKeysState extends State<RemoteVolumeKeys> with WidgetsBindingObserver {
  static const _shownFor = Duration(milliseconds: 1500);
  static const _keys = MethodChannel('app.sapoche/volume_keys');
  static const _session = MethodChannel('app.sapoche/remote_session');

  final _level = ValueNotifier<double>(0);
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _bar;
  Timer? _hide;
  ConnectDevice? _device;
  ConnectController? _connect;
  var _steering = false;

  @override
  void initState() {
    super.initState();
    _connect = connectOf(context)?..addListener(_update);
    Tv.on.addListener(_update);
    _keys.setMethodCallHandler(_onCall);
    _session.setMethodCallHandler(_onSessionCommand);
    WidgetsBinding.instance.addObserver(this);
    _update();
  }

  @override
  void dispose() {
    _connect?.removeListener(_update);
    Tv.on.removeListener(_update);
    _keys.setMethodCallHandler(null);
    _session.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    if (_steering) _tell(false);
    if (_sessionOn) unawaited(_session.invokeMethod<void>('hide').catchError((Object _) {}));
    _hide?.cancel();
    _level.dispose();
    super.dispose();
  }

  /// Tells the activity whether the keys are this one's to take: while another device plays, and this one is not a TV.
  void _update() {
    final want = _steerable;
    if (want != _steering) {
      _steering = want;
      _tell(want);
    }
    _syncSession();
  }

  bool get _steerable => !kIsWeb && defaultTargetPlatform == TargetPlatform.android && !Tv.on.value && (_connect?.controlling ?? false);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncSession();

  // ------------------------------------------------------------------ the session of the system

  // The volume keys with the screen off go to a media session that plays; this phone has none while it steers another one, so
  // it keeps one that mirrors the other (`RemoteSessionService`). It is for the phone that really steers: one that was in front
  // when it began to, or is in front now. A tablet in a drawer that another device starts to play on has no notification.
  var _sessionOn = false;
  String? _sessionSignature;
  int _sessionPositionMs = 0;
  int _sessionAt = 0;

  bool get _inFront => (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed;

  void _syncSession() {
    final connect = _connect;
    final state = connect?.remote;
    // Kept while this one steers, also in the moments when the new device has not said its state yet (the music moved from one
    // device to another while the app was in the background: it must not be lost, for nothing would bring it back there)
    final want = _steerable && (_sessionOn || (state != null && _inFront));
    if (!want) {
      if (_sessionOn) {
        _sessionOn = false;
        _sessionSignature = null;
        unawaited(_session.invokeMethod<void>('hide').catchError((Object _) {}));
      }
      return;
    }
    if (state == null) return;
    final device = connect!.activeDevice?.info?.name ?? '';
    final volume = state.volume ?? 0.5;
    final signature = [
      device,
      state.itemId,
      state.current?.title,
      state.playing,
      state.durationMs,
      state.speed,
      (volume * 16).round(),
    ].join('|');
    final now = DateTime.now().millisecondsSinceEpoch;
    final expected = _sessionPositionMs + (state.playing ? ((now - _sessionAt) * state.speed).round() : 0);
    final jumped = (state.positionMs - expected).abs() > 2500;
    if (_sessionOn && signature == _sessionSignature && !jumped) return;
    _sessionOn = true;
    _sessionSignature = signature;
    _sessionPositionMs = state.positionMs;
    _sessionAt = now;
    final artist = state.current?.artist ?? '';
    final where = S.playingOn(device);
    unawaited(
      _session
          .invokeMethod<void>('show', {
            'device': device,
            'title': state.current?.title ?? '',
            'artist': artist.isEmpty ? where : '$artist · $where',
            'cover': state.current?.thumb,
            'durationMs': state.durationMs,
            'positionMs': state.positionMs,
            'speed': state.speed,
            'playing': state.playing,
            'volume': volume,
          })
          .catchError((Object _) {}),
    );
  }

  /// What the system asks of the session (a key, the bar of the volume, a button of the notification or of the lock screen).
  Future<void> _onSessionCommand(MethodCall call) async {
    if (call.method != 'command') return;
    final connect = _connect;
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    switch (args['name']) {
      case 'play' || 'pause' || 'next' || 'prev':
        connect?.send(RemoteCommand(args['name']! as String));
      case 'seek':
        connect?.send(RemoteCommand('seek', {'ms': (args['ms'] as num).toInt()}));
      case 'volume':
        connect?.sendVolume((args['level'] as num).toDouble());
      case 'nudge':
        connect?.nudgeVolume((args['way'] as num).toInt());
    }
  }

  void _tell(bool on) => unawaited(_keys.invokeMethod<void>('steer', on).catchError((Object _) {}));

  /// A press of a volume key, taken by the activity: [call] says which way (1 up, -1 down); held, it comes again and again.
  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'press') return;
    final connect = _connect;
    final level = connect?.nudgeVolume((call.arguments as num).toInt());
    if (level != null) _show(connect!.activeDevice, level);
  }

  void _show(ConnectDevice? device, double level) {
    _device = device;
    _level.value = level;
    _hide?.cancel();
    _hide = Timer(_shownFor, () => _bar?.close());
    if (_bar != null) return;
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    // One bar for as long as the buttons are pressed: it is moved, not shown again each time
    // The ground of the theme (the other toasts are its opposite): a bar of the volume reads as part of the screen
    final p = context.palette;
    final shown = messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 1),
        backgroundColor: p.menu,
        content: ValueListenableBuilder<double>(
          valueListenable: _level,
          builder: (context, level, _) {
            return Semantics(
              liveRegion: true,
              label: S.volumeOf(_device?.info?.name ?? ''),
              value: '${(level * 100).round()}%',
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Icon(
                      deviceIcon(_device?.info?.kind ?? DeviceKind.phone),
                      size: 20,
                      color: p.text,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        _device?.info?.name ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.text),
                      ),
                    ),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 112,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: level,
                          minHeight: 6,
                          color: p.primary,
                          backgroundColor: p.track,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    _bar = shown;
    unawaited(
      shown.closed.then((_) {
        if (identical(_bar, shown)) _bar = null;
      }),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The sheet of devices to play on (docs/plans/2026-11-27-listen-on-another-device.md G5).
Future<void> showConnectSheet(BuildContext context, RoomController room) => showModalBottomSheet<void>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  sheetAnimationStyle: Motion.sheet(context),
  builder: (_) => ConnectSheet(room: room),
);

class ConnectSheet extends StatelessWidget {
  const ConnectSheet({super.key, required this.room});

  final RoomController room;

  @override
  Widget build(BuildContext context) {
    final connect = connectOf(context)!;
    final model = AppScope.of(context);
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: ListenableBuilder(
          listenable: Listenable.merge([connect, room]),
          builder: (context, _) {
            final others = [for (final d in connect.devices) if (!d.you) d];
            final you = connect.devices.where((d) => d.you).firstOrNull;
            final here = connect.link == ConnectLink.online;
            final output = room.output;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(S.playOn, style: theme.headlineSmall),
                const SizedBox(height: 8),
                // The sound is another device's: its volume is set from here too
                if (connect.controlling)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: VolumeBar(controller: room),
                  ),
                // This device: it plays here unless another one does
                SheetTile(
                  key: const ValueKey('connect-here'),
                  icon: deviceIcon(connect.kind()),
                  title: connect.name,
                  help: S.thisDevice,
                  detail: connect.playingHere ? S.devicePlaying : null,
                  onTap: () {
                    // Also when nobody plays: the last queue the cluster kept is taken up from where it stopped
                    if (!connect.playingHere) {
                      connect.playHere();
                      _tellMoving(context, S.movingHere);
                    }
                    Navigator.pop(context);
                  },
                ),
                if (!kIsWeb)
                  SheetTile(
                    key: const ValueKey('connect-output'),
                    icon: _outputIcon(output.kind),
                    title: S.connectOutput,
                    help: output.name.isEmpty ? null : output.name,
                    chevron: true,
                    onTap: room.pickOutput,
                  ),
                if (!connect.enabled)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(S.connectNeedSync, style: theme.bodyMedium?.copyWith(color: p.textSecondary)),
                        if (model.sync != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              key: const ValueKey('connect-sync'),
                              onPressed: () {
                                Navigator.pop(context);
                                startSync(context, model.sync!);
                              },
                              child: Text(S.connectTurnOnSync),
                            ),
                          ),
                      ],
                    ),
                  )
                else ...[
                  if (connect.link == ConnectLink.refused)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(S.connectRefused, style: theme.bodySmall?.copyWith(color: p.error)),
                    )
                  else if (!here)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(S.connectLooking, style: theme.bodySmall?.copyWith(color: p.textSecondary)),
                    ),
                  if (others.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 14, 0, 4),
                      child: Text(S.yourDevices, style: theme.titleSmall?.copyWith(color: p.textSecondary)),
                    ),
                    for (final d in others)
                      SheetTile(
                        key: ValueKey('connect-device-${d.id}'),
                        icon: deviceIcon(d.info?.kind ?? DeviceKind.phone),
                        title: d.info?.name ?? '…',
                        help: d.info?.app.isEmpty ?? true ? null : 'Sapoche ${d.info!.app}',
                        detail: d.info?.inRoom == true
                            ? S.deviceInRoom
                            : d.id == connect.activeId
                            ? S.devicePlaying
                            : null,
                        enabled: d.info?.inRoom != true,
                        onTap: () {
                          connect.transferTo(d.id);
                          if (d.id != connect.activeId) _tellMoving(context, S.movingTo(d.info?.name ?? ''));
                          Navigator.pop(context);
                        },
                      ),
                  ],
                  // The devices of the person that are not here now: dimmed, and a way to drop one that is gone for good
                  if (here && connect.recent.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 14, 0, 4),
                      child: Text(S.devicesRecent, style: theme.titleSmall?.copyWith(color: p.textSecondary)),
                    ),
                    for (final d in connect.recent)
                      SheetTile(
                        key: ValueKey('connect-recent-${d.id}'),
                        icon: deviceIcon(d.info?.kind ?? DeviceKind.phone),
                        title: d.info?.name ?? '…',
                        help: '${S.deviceOffline} · ${S.ago(connect.seenAgo(d))}',
                        enabled: false,
                        trailing: IconButton(
                          key: ValueKey('connect-forget-${d.id}'),
                          tooltip: S.forgetDevice,
                          icon: const Icon(Icons.close_rounded),
                          color: p.textSecondary,
                          onPressed: () => connect.forget(d.id),
                        ),
                      ),
                  ],
                  // What this device is called in the lists of the others (its model, until it is given a name)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('connect-rename'),
                      onPressed: () async {
                        final name = await showTextDialog(
                          context,
                          title: S.connectName,
                          hint: connect.defaultName(),
                          initial: connect.name,
                          maxLength: 24,
                        );
                        if (name != null) await connect.rename(name);
                      },
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: Text(S.connectRename),
                    ),
                  ),
                  if (you != null && others.isEmpty && here)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(S.connectHint, style: theme.bodySmall?.copyWith(color: p.textSecondary)),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The hand-over takes a moment (the queue goes through the server): the person is told it has begun.
void _tellMoving(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
}
