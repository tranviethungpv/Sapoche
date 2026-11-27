import 'dart:async' show Timer;
import 'dart:math' as math;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_settings.dart';
import '../data/browser_storage.dart';
import '../data/calm.dart';
import '../data/library_controller.dart';
import '../data/models.dart';
import '../data/room_controller.dart';
import '../data/setup_link.dart';
import '../data/sync/sync_controller.dart';
import '../data/taste_clusters.dart';
import '../data/update_controller.dart';
import '../data/update_info.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/accents.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'accent_picker_sheet.dart';
import 'home_shell.dart';
import 'log_page.dart';
import 'player/video_controls.dart';
import 'scope.dart';
import 'setup_dialog.dart';
import 'sync_dialogs.dart';
import 'profile_sheet.dart';
import 'release_history_list.dart';
import 'update_actions.dart';
import 'widgets/ambient_backdrop.dart';
import 'widgets/avatars.dart';
import 'widgets/library_lost_notice.dart';
import 'widgets/page_width.dart';
import 'widgets/play_row.dart';
import 'widgets/release_notes_text.dart';
import 'widgets/scroll_edge.dart';
import 'widgets/text_dialog.dart';
import 'widgets/motion.dart';
import 'widgets/focus_nav.dart';

/// Opens the settings in the tab that is showing (beside the sidebar of a wide screen), with a way back.
Future<void> openSettings(BuildContext context) => TabNavigation.push(
  context,
  MaterialPageRoute<void>(
    settings: const RouteSettings(name: Where.settings),
    builder: (_) => const SettingsScreen(),
  ),
);

/// The settings as a page of their own. A page on its own paints its own backdrop, the same as the home screen's,
/// so that the page it covers does not show through.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => AmbientBackdrop(
    child: Padding(
      padding: SideInset.paddingOf(context),
      child: const Scaffold(body: SettingsPage()),
    ),
  );
}

/// A topic of the settings: its title, and what is on its page.
typedef _Topic = (
  String Function() title,
  List<Widget> Function(BuildContext context, AppModel model) children,
);

/// A short list of topics; each opens a page of its own, so no page grows long. On a wide screen the topic is shown
/// beside the list instead, as the settings of a tablet do.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// Whether the topics are shown beside the list, as of the last layout.
  bool _wide = false;

  /// The topic beside the list on a wide screen.
  _Topic _topic = (() => S.appearance, _appearance);

  /// Whether [children] is the topic shown beside the list.
  bool _shows(List<Widget> Function(BuildContext, AppModel) children) =>
      _wide && _topic.$2 == children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _wide = box.maxWidth >= 760;
      final list = _SettingsList(
        title: S.settingsTitle,
        children: _topics(context),
      );
      if (!_wide) return list;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 380, child: list),
          Expanded(
            child: _SettingsList(
              key: ValueKey(_topic.$2),
              title: _topic.$1(),
              back: false,
              children: _topic.$2(context, AppScope.of(context)),
            ),
          ),
        ],
      );
    },
  );

  List<Widget> _topics(BuildContext context) {
    final model = AppScope.of(context);
    return [
      _ProfileCard(room: model.room),
      ListenableBuilder(
        listenable: Listenable.merge([model.settings, model.room]),
        builder: (context, _) => _Group(
          children: [
            _NavRow(
              selected: _shows(_appearance),
              key: const ValueKey('settings-appearance'),
              icon: Icons.palette_outlined,
              label: S.appearance,
              value: switch (model.settings.themeMode) {
                ThemeMode.system => S.themeSystem,
                ThemeMode.light => S.themeLight,
                ThemeMode.dark => S.themeDark,
              },
              onTap: () => _open(context, () => S.appearance, _appearance),
            ),
            _NavRow(
              selected: _shows(_language),
              key: const ValueKey('settings-language'),
              icon: Icons.translate_rounded,
              label: S.languageLabel,
              value: model.settings.language == null
                  ? S.languageSystem
                  : S.languageName(model.settings.language!),
              onTap: () => _open(context, () => S.languageLabel, _language),
            ),
            // Only where the device can tell the person of the chat while the app is away
            if (model.room.notificationInfo.supported)
              _NavRow(
                selected: _shows(_notices),
                key: const ValueKey('settings-notices'),
                icon: Icons.notifications_none_rounded,
                label: S.notices,
                value: model.room.notificationInfo.enabled
                    ? S.noticesOn
                    : S.noticesOff,
                onTap: () => _open(context, () => S.notices, _notices),
              ),
          ],
        ),
      ),
      ListenableBuilder(
        listenable: model.room,
        builder: (context, _) => _Group(
          children: [
            _NavRow(
              selected: _shows(_playback),
              key: const ValueKey('settings-playback'),
              icon: Icons.play_circle_outline_rounded,
              label: S.playback,
              value: kIsWeb
                  ? null
                  : switch (model.room.audioQuality) {
                      AudioQuality.low => S.audioQualityLow,
                      AudioQuality.normal => S.audioQualityNormal,
                      AudioQuality.high => S.audioQualityHigh,
                      AudioQuality.max => S.audioQualityMax,
                    },
              onTap: () => _open(context, () => S.playback, _playback),
            ),
            _NavRow(
              selected: _shows(_suggestions),
              key: const ValueKey('settings-suggestions'),
              icon: Icons.auto_awesome_outlined,
              label: S.suggestionsTitle,
              onTap: () =>
                  _open(context, () => S.suggestionsTitle, _suggestions),
            ),
          ],
        ),
      ),
      _Group(
        children: [
          _StorageRow(
            selected: _shows(_storage),
            library: model.library,
            onTap: () => _open(context, () => S.storage, _storage),
          ),
          // The web build cannot save or read a backup file, only sync
          if (!kIsWeb || _canSync(model))
            ListenableBuilder(
              listenable: model.sync ?? model.room,
              builder: (context, _) => _NavRow(
                selected: _shows(_backup),
                key: const ValueKey('settings-backup'),
                icon: Icons.backup_outlined,
                label: _canSync(model) ? S.syncTitle : S.backup,
                value: _canSync(model)
                    ? (model.sync!.enabled ? S.noticesOn : S.noticesOff)
                    : null,
                onTap: () => _open(context, () => _canSync(model) ? S.syncTitle : S.backup, _backup),
              ),
            ),
        ],
      ),
      ListenableBuilder(
        listenable: model.update,
        builder: (context, _) {
          final info = model.update.info;
          return _Group(
            children: [
              // The phone that has the server built in can set another one up; a browser shares a link to itself
              if (kIsWeb || Platform.isAndroid)
                _NavRow(
                  key: const ValueKey('settings-setup-another'),
                  icon: Icons.qr_code_2_rounded,
                  label: kIsWeb ? S.setupAnotherWeb : S.setupAnother,
                  onTap: () => showSetupLinkDialog(context, model.room),
                ),
              // iOS installs updates by itself: they come from SideStore, not from the app; a web page is always the
              // newest
              if (!kIsWeb && !Platform.isIOS)
                _NavRow(
                  selected: _shows(_updates),
                  key: const ValueKey('settings-updates'),
                  icon: Icons.system_update_outlined,
                  label: S.updates,
                  value: info.hasUpdate ? info.version : info.installed,
                  onTap: () => _open(context, () => S.updates, _updates),
                ),
              // What changed in each version: it is in the app, so it reads the same on every platform
              _NavRow(
                selected: _shows(_releaseNotes),
                key: const ValueKey('settings-release-notes'),
                icon: Icons.history_rounded,
                label: S.releaseNotes,
                onTap: () =>
                    _open(context, () => S.releaseNotes, _releaseNotes),
              ),
            ],
          );
        },
      ),
      // What only someone who knows the app well needs: the server, scrobbling and the log, one page away
      _Group(
        children: [
          _NavRow(
            selected: _shows(_advanced),
            key: const ValueKey('settings-advanced'),
            icon: Icons.tune_rounded,
            label: S.advanced,
            onTap: () => _open(context, () => S.advanced, _advanced),
          ),
        ],
      ),
      const _VersionLabel(),
    ];
  }

  /// [title] is a function so that the page can change its words when the language does.
  void _open(
    BuildContext context,
    String Function() title,
    List<Widget> Function(BuildContext context, AppModel model) children,
  ) {
    if (_wide) {
      setState(() => _topic = (title, children));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _SubPage(
          title: title(),
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
          builder: (context, _) => Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<ThemeMode>(
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
                for (final (mode, label) in [
                  (ThemeMode.system, S.themeSystem),
                  (ThemeMode.light, S.themeLight),
                  (ThemeMode.dark, S.themeDark),
                ])
                  ButtonSegment(
                    value: mode,
                    label: FittedBox(
                      key: ValueKey('theme-${mode.name}'),
                      fit: BoxFit.scaleDown,
                      child: Text(label, maxLines: 1),
                    ),
                  ),
              ],
              selected: {model.settings.themeMode},
              onSelectionChanged: (s) => model.settings.themeMode = s.first,
            ),
          ),
        ),
      ],
    ),
    _Group(
      title: S.playerStyle,
      footer: S.playerStyleHelp,
      children: [
        ValueListenableBuilder<PlayerStyle>(
          valueListenable: model.settings.playerStyleListenable,
          builder: (context, chosen, _) => Column(
            children: [
              for (final (style, label, about) in [
                (
                  PlayerStyle.classic,
                  S.playerStyleClassic,
                  S.playerStyleClassicAbout,
                ),
                (
                  PlayerStyle.spotify,
                  S.playerStyleCards,
                  S.playerStyleCardsAbout,
                ),
                (
                  PlayerStyle.appleMusic,
                  S.playerStyleFullCover,
                  S.playerStyleFullCoverAbout,
                ),
              ])
                _Row(
                  key: ValueKey('player-style-${style.name}'),
                  label: label,
                  subtitle: about,
                  trailing: chosen == style
                      ? Icon(
                          Icons.check_rounded,
                          color: context.palette.primary,
                        )
                      : null,
                  onTap: () => model.settings.playerStyle = style,
                ),
            ],
          ),
        ),
      ],
    ),
    _Group(
      title: S.accentColor,
      footer: S.accentHelp,
      children: [
        ListenableBuilder(
          listenable: model.settings,
          builder: (context, _) => _AccentSwatches(settings: model.settings),
        ),
      ],
    ),
    _Group(
      title: S.effectsTitle,
      footer: S.effectsHelp,
      children: [
        ValueListenableBuilder<EffectsLevel>(
          valueListenable: Calm.level,
          builder: (context, chosen, _) => Column(
            children: [
              for (final (level, label, about) in [
                (EffectsLevel.full, S.effectsFull, S.effectsFullAbout),
                (EffectsLevel.light, S.effectsLight, S.effectsLightAbout),
                (EffectsLevel.minimal, S.effectsMinimal, S.effectsMinimalAbout),
              ])
                _Row(
                  key: ValueKey('effects-${level.name}'),
                  label: label,
                  subtitle: about,
                  trailing: chosen == level
                      ? Icon(
                          Icons.check_rounded,
                          color: context.palette.primary,
                        )
                      : null,
                  onTap: () => model.settings.effects = level,
                ),
            ],
          ),
        ),
      ],
    ),
    // An iPhone is never a TV: there is no Apple TV build, so nothing to choose
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.android)
      _Group(
        title: S.tvLayout,
        footer: S.tvLayoutHelp,
        children: [
          ListenableBuilder(
            listenable: model.settings,
            builder: (context, _) => Column(
              children: [
                for (final (mode, label) in [
                  (TvMode.auto, S.tvAuto),
                  (TvMode.on, S.tvOn),
                  (TvMode.off, S.tvOff),
                ])
                  _Row(
                    key: ValueKey('tv-${mode.name}'),
                    label: label,
                    trailing: model.settings.tvMode == mode
                        ? Icon(
                            Icons.check_rounded,
                            color: context.palette.primary,
                          )
                        : null,
                    onTap: () => model.settings.tvMode = mode,
                  ),
              ],
            ),
          ),
        ],
      ),
  ];

  static List<Widget> _language(BuildContext context, AppModel model) => [
    _Group(
      footer: S.languageHelp,
      children: [
        ListenableBuilder(
          listenable: model.settings,
          builder: (context, _) => Column(
            children: [
              for (final code in [null, ...S.languages])
                _Row(
                  key: ValueKey('language-${code ?? 'system'}'),
                  label: code == null ? S.languageSystem : S.languageName(code),
                  trailing: model.settings.language == code
                      ? Icon(
                          Icons.check_rounded,
                          color: context.palette.primary,
                        )
                      : null,
                  onTap: () => model.settings.language = code,
                ),
            ],
          ),
        ),
      ],
    ),
  ];

  /// What the person told the suggestions, and what was blocked from them, to be let back one by one; what the
  /// listening says about the person is a page away, being something to look at rather than to set.
  static List<Widget> _suggestions(BuildContext context, AppModel model) => [
    _Group(
      children: [
        _NavRow(
          key: const ValueKey('settings-taste'),
          icon: Icons.person_search_outlined,
          label: S.tasteHeading,
          onTap: () => _push(context, S.tasteHeading, _taste(context, model)),
        ),
      ],
    ),
    _Group(
      footer: S.shareTasteHelp,
      children: [
        ListenableBuilder(
          listenable: model.room,
          builder: (context, _) => Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              key: const ValueKey('share-taste-switch'),
              title: Text(S.shareTaste),
              value: model.room.shareTaste,
              onChanged: model.room.setShareTaste,
            ),
          ),
        ),
      ],
    ),
    ListenableBuilder(
      listenable: model.library,
      builder: (context, _) => _marksGroup(context, model.library),
    ),
    _Group(
      title: S.blockedHeading,
      footer: S.blockedHelp,
      children: [
        ListenableBuilder(
          listenable: model.library,
          builder: (context, _) {
            final blocked = model.library.blocked;
            if (blocked.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  S.blockedNone,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: context.palette.textSecondary),
                ),
              );
            }
            return Column(
              children: [
                for (final item in blocked)
                  _Row(
                    key: ValueKey('blocked-${item.kind}-${item.key}'),
                    label: item.label,
                    leading: Icon(
                      item.isArtist
                          ? Icons.person_off_outlined
                          : Icons.music_off_outlined,
                      color: context.palette.primary,
                    ),
                    trailing: Icon(
                      Icons.close_rounded,
                      color: context.palette.textTertiary,
                    ),
                    onTap: () => model.library.unblock(item),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  ];

  /// The artists the person listens to most, the mixes they make, and how often suggestions are skipped.
  static List<Widget> _taste(BuildContext context, AppModel model) => [
    ListenableBuilder(
      listenable: model.library,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _tasteGroups(context, model.library),
      ),
    ),
    ListenableBuilder(
      listenable: model.library,
      builder: (context, _) => _Group(
        title: S.tasteStatsHeading,
        footer: S.tasteStatsHelp,
        children: [_TasteStats(stats: model.library.tasteProfile.stats)],
      ),
    ),
  ];

  static List<Widget> _notices(BuildContext context, AppModel model) => [
    ListenableBuilder(
      listenable: model.room,
      builder: (context, _) {
        final info = model.room.notificationInfo;
        final blocked = info.permission == NoticePermission.denied;
        return Column(
          children: [
            _Group(
              footer: info.needsInstall
                  ? S.noticesNeedInstall
                  : blocked
                  ? S.noticesDenied
                  : S.noticesSwitchHelp,
              more: info.needsInstall || blocked ? null : S.noticesSwitchMore,
              children: [
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    key: const ValueKey('notices-switch'),
                    title: Text(S.noticesSwitch),
                    value: info.enabled,
                    onChanged: info.needsInstall || blocked
                        ? null
                        : model.room.setNotifications,
                  ),
                ),
              ],
            ),
            if (info.enabled)
              _Group(
                footer: S.noticesPreviewHelp,
                children: [
                  Material(
                    type: MaterialType.transparency,
                    child: SwitchListTile(
                      key: const ValueKey('notices-preview'),
                      title: Text(S.noticesPreview),
                      value: info.preview,
                      onChanged: model.room.setNotificationPreview,
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    ),
  ];

  /// The artists the person listens to most, and the groups of them they play together.
  static List<Widget> _tasteGroups(
    BuildContext context,
    LibraryController library,
  ) {
    final profile = library.tasteProfile;
    final artists = profile.artists.where((a) => a.score > 0).toList();
    final quiet = {
      for (final m in profile.marksOf(TasteMarks.quietArtist)) m.key,
    };
    final clusters = clusterTaste(
      listens: library.listens,
      weights: {for (final a in artists) a.key: a.score},
    );
    final labels = {for (final a in artists) a.key: a.label};
    return [
      // The page is called this already, so the group has no title of its own
      _Group(
        footer: artists.isEmpty ? null : S.tasteHelp,
        children: [
          if (artists.isEmpty)
            Padding(
              key: const ValueKey('taste-none'),
              padding: const EdgeInsets.all(16),
              child: Text(
                S.tasteNone,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: context.palette.textSecondary),
              ),
            )
          else ...[
            // What the two buttons at the end of each row are, said once where they are met
            const _TasteLegend(),
            for (final artist in artists.take(8))
              _TasteArtistRow(
                key: ValueKey('taste-artist-${artist.key}'),
                artist: artist,
                share: artist.score / artists.first.score,
                quiet: quiet.contains(artist.key),
                onQuiet: () => library.setTasteMark(
                  TasteMarks.quietArtist,
                  artist.key,
                  artist.label,
                  on: !quiet.contains(artist.key),
                ),
                onBlock: () => library.block(
                  Track(videoId: '', title: '', artist: artist.label, durMs: 0),
                  artistOnly: true,
                ),
              ),
          ],
        ],
      ),
      if (clusters.isNotEmpty)
        _Group(
          title: S.tasteClustersHeading,
          footer: S.tasteClustersHelp,
          children: [
            for (final (i, cluster) in clusters.indexed)
              SizedBox(
                key: ValueKey('taste-cluster-$i'),
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        S.dailyMix(i + 1),
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                              for (final key in cluster.artists.take(3))
                                labels[key] ?? key,
                            ].join(', ') +
                            (cluster.artists.length > 3 ? '…' : ''),
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: context.palette.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
    ];
  }

  /// What the person told the taste (artists to hear less of, songs not to count, starter songs), to be taken off.
  static Widget _marksGroup(BuildContext context, LibraryController library) {
    final marks = [
      for (final kind in [
        TasteMarks.quietArtist,
        TasteMarks.quietSong,
        TasteMarks.starter,
      ])
        ...library.tasteProfile.marksOf(kind),
    ];
    if (marks.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    return _Group(
      title: S.tasteMarksHeading,
      footer: S.tasteMarksHelp,
      children: [
        for (final mark in marks)
          _Row(
            key: ValueKey('mark-${mark.kind}-${mark.key}'),
            label: switch (mark.kind) {
              TasteMarks.starter =>
                TasteMarks.starterTrack(mark.label)?.title ?? mark.key,
              _ => mark.label,
            },
            value: switch (mark.kind) {
              TasteMarks.quietArtist => S.tasteMarkArtist,
              TasteMarks.quietSong => S.tasteMarkSong,
              _ => TasteMarks.starterTrack(mark.label)?.artist,
            },
            leading: Icon(switch (mark.kind) {
              TasteMarks.quietArtist => Icons.person_off_outlined,
              TasteMarks.quietSong => Icons.visibility_off_outlined,
              _ => Icons.star_outline_rounded,
            }, color: p.primary),
            trailing: Icon(Icons.close_rounded, color: p.textTertiary),
            onTap: () => library.setTasteMark(
              mark.kind,
              mark.key,
              mark.label,
              on: false,
            ),
          ),
      ],
    );
  }

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
              title: Text(S.autoplay),
              value: model.room.autoplay,
              onChanged: model.room.setAutoplay,
            ),
          ),
        ),
      ],
    ),
    // The sound of a browser is YouTube's own, which picks it by itself; the picture is asked for by the size it is laid out at
    if (kIsWeb)
      _Group(
        title: S.soundSection,
        footer: S.webQualityHelp,
        more: '${S.crossfadeHelp} ${S.crossfadeMore}',
        children: [_CrossfadeRow(controller: model.room)],
      )
    else ...[
      _Group(
        title: S.soundSection,
        footer: S.audioQualityHelp,
        more: S.audioQualityMore,
        children: [
          ListenableBuilder(
            listenable: model.room,
            builder: (context, _) => Column(
              children: [
                for (final (quality, label, rate) in [
                  (AudioQuality.low, S.audioQualityLow, S.audioQualityLowRate),
                  (
                    AudioQuality.normal,
                    S.audioQualityNormal,
                    S.audioQualityNormalRate,
                  ),
                  (
                    AudioQuality.high,
                    S.audioQualityHigh,
                    S.audioQualityHighRate,
                  ),
                  (
                    AudioQuality.max,
                    S.audioQualityMax,
                    defaultTargetPlatform == TargetPlatform.iOS
                        ? S.audioQualityMaxRateIos
                        : S.audioQualityMaxRate,
                  ),
                ])
                  _Row(
                    key: ValueKey('audio-quality-${quality.name}'),
                    label: label,
                    value: rate,
                    trailing: model.room.audioQuality == quality
                        ? Icon(
                            Icons.check_rounded,
                            color: context.palette.primary,
                          )
                        : null,
                    onTap: () => model.room.setAudioQuality(quality),
                  ),
              ],
            ),
          ),
        ],
      ),
      // How songs sound next to each other, said under them rather than under the qualities
      _Group(
        footer: S.crossfadeHelp,
        more: '${S.crossfadeMore}\n\n${S.normalizeVolumeHelp}',
        children: [
          // A browser plays through YouTube's own player, which evens songs out by itself and cannot be told not to
          ListenableBuilder(
            listenable: model.room,
            builder: (context, _) => Material(
              type: MaterialType.transparency,
              child: SwitchListTile(
                key: const ValueKey('normalize-volume-switch'),
                title: Text(S.normalizeVolume),
                subtitle: Text(S.normalizeVolumeShort),
                value: model.room.normalizeVolume,
                onChanged: model.room.setNormalizeVolume,
              ),
            ),
          ),
          _CrossfadeRow(controller: model.room),
        ],
      ),
    ],
    _Group(
      title: S.videoSection,
      footer: kIsWeb ? S.videoQualityHelpWeb : S.videoQualityHelp,
      more: kIsWeb ? null : S.videoQualityMore,
      children: [
        ListenableBuilder(
          listenable: model.room,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SettingQualityChips(
                  snapshot: model.room.snapshot,
                  onPick: model.room.setVideoQuality,
                ),
                // A phone that plays no more than 1080p, or 1440p: said, rather than leaving the missing heights to be wondered about
                if (!kIsWeb && model.room.snapshot.videoHeightMax < 2160)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      S.videoLimitDevice(model.room.snapshot.videoHeightMax),
                      key: const ValueKey('quality-device-limit'),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: context.palette.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
    // Rarely changed: the equalizer (a browser has none) and the timing of this device in a room
    _Group(
      title: S.advanced,
      footer: kIsWeb ? S.latencyTrimHelpWeb : S.latencyTrimHelp,
      children: [
        if (!kIsWeb)
          ListenableBuilder(
            listenable: model.room,
            builder: (context, _) => _NavRow(
              key: const ValueKey('settings-equalizer'),
              icon: Icons.equalizer_rounded,
              label: S.equalizer,
              value: S.eqPreset(model.room.equalizer.preset),
              onTap: () => _push(
                context,
                S.equalizer,
                [_EqualizerPanel(controller: model.room)],
              ),
            ),
          ),
        _TrimRow(controller: model.room),
      ],
    ),
  ];

  static List<Widget> _storage(BuildContext context, AppModel model) => [
    kIsWeb
        ? const _BrowserStorageGroup()
        : _StorageGroup(library: model.library),
  ];

  /// The server is known, and there is an engine to sync with it.
  static bool _canSync(AppModel model) => model.sync != null && model.room.profile.configured;

  static List<Widget> _backup(BuildContext context, AppModel model) => [
    const LibraryLostNotice(),
    if (_canSync(model)) _SyncGroup(sync: model.sync!),
    if (!kIsWeb) _BackupGroup(library: model.library),
  ];

  static List<Widget> _scrobble(BuildContext context, AppModel model) => [
    _ScrobbleGroup(room: model.room, service: ScrobbleServices.listenBrainz),
    // Last.fm is signed by the room server, so it needs one, and its key: a build without them has no row that does nothing
    if (model.room.profile.configured && model.room.profile.hasKey)
      _ScrobbleGroup(room: model.room, service: ScrobbleServices.lastFm),
  ];

  static List<Widget> _server(BuildContext context, AppModel model) => [
    _ServerGroup(room: model.room),
  ];

  static List<Widget> _updates(BuildContext context, AppModel model) => [
    _UpdateGroup(update: model.update),
  ];

  /// Opens a page of its own over the settings, from inside a topic.
  static void _push(BuildContext context, String title, List<Widget> children) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => _SubPage(title: title, children: children),
        ),
      );

  static List<Widget> _advanced(BuildContext context, AppModel model) => [
    _Group(
      children: [
        _NavRow(
          key: const ValueKey('settings-scrobble'),
          icon: Icons.podcasts_rounded,
          label: S.scrobbleTitle,
          onTap: () => _push(context, S.scrobbleTitle, _scrobble(context, model)),
        ),
      ],
    ),
    // The server is set by the person on iOS and in a browser; on Android it is built into the app, and only the build
    // for the public (a GitHub release) has no key and asks for one here
    if (kIsWeb || Platform.isIOS || !model.room.profile.configured)
      _Group(
        children: [
          _NavRow(
            key: const ValueKey('settings-server'),
            icon: Icons.dns_outlined,
            label: S.serverSection,
            onTap: () => _push(context, S.serverSection, _server(context, model)),
          ),
        ],
      ),
    _Group(
      footer: S.diagnosticsHelp,
      children: [
        _NavRow(
          key: const ValueKey('settings-log'),
          icon: Icons.fact_check_rounded,
          label: S.logTitle,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const LogPage())),
        ),
        // Android has the server built in, so it has no Server page to check it from
        if (!kIsWeb && Platform.isAndroid)
          _Row(
            key: const ValueKey('server-check'),
            label: S.checkConnectionRow,
            leading: Icon(
              Icons.network_check_rounded,
              color: context.palette.primary,
            ),
            onTap: () => _showServerCheck(context, model.room),
          ),
      ],
    ),
  ];

  static List<Widget> _releaseNotes(BuildContext context, AppModel model) => [
    // The versions this phone has not got are only known from the server, so what the update says of them goes on top
    ListenableBuilder(
      listenable: model.update,
      builder: (context, _) =>
          ReleaseHistoryList(upcoming: model.update.info.upcoming),
    ),
  ];
}

/// The version of the app in small print at the foot of the list, the same on both platforms.
class _VersionLabel extends StatefulWidget {
  const _VersionLabel();

  @override
  State<_VersionLabel> createState() => _VersionLabelState();
}

class _VersionLabelState extends State<_VersionLabel> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) => FutureBuilder<PackageInfo>(
    future: _info,
    builder: (context, async) {
      final info = async.data;
      if (info == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'Sapoche ${info.version} (${info.buildNumber})',
          key: const ValueKey('settings-version'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: context.palette.textTertiary),
        ),
      );
    },
  );
}

/// One service the songs this phone plays are sent to. ListenBrainz: pasting the token of the account connects it. Last.fm:
/// the person allows Sapoche on its page (no password is typed here) and comes back. From then on the songs are sent.
class _ScrobbleGroup extends StatefulWidget {
  const _ScrobbleGroup({required this.room, required this.service});

  final RoomController room;

  /// One of [ScrobbleServices].
  final String service;

  @override
  State<_ScrobbleGroup> createState() => _ScrobbleGroupState();
}

class _ScrobbleGroupState extends State<_ScrobbleGroup>
    with WidgetsBindingObserver {
  ScrobbleState _state = const ScrobbleState();
  Timer? _refresh;

  /// The token has gone to the service and the answer has not come back: on a slow network that takes a while.
  bool _connecting = false;

  /// Last.fm: the token the person is allowing on its page. Kept here only, never stored: it lives for an hour.
  String? _allowing;

  bool get _lastFm => widget.service == ScrobbleServices.lastFm;

  /// What this group's rows are called, so that the two groups of the page do not share keys.
  String get _key => _lastFm ? 'lastfm' : 'scrobble';

  String get _name => _lastFm ? S.lastFmName : S.scrobbleTitleListenBrainz;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // The listens waiting to be sent go down while the page is open
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refresh?.cancel();
    super.dispose();
  }

  /// Back from the page of Last.fm: the person has most likely allowed it, so the session is asked for without another tap.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _allowing != null && !_connecting) {
      _finishLastFm();
    }
  }

  Future<void> _load() async {
    final state = await widget.room.scrobbleState(widget.service);
    if (mounted) setState(() => _state = state);
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _connect() async {
    final token = await showTextDialog(
      context,
      title: S.scrobbleEnterToken,
      hint: S.scrobbleTokenHint,
      maxLength: 80,
      capitalization: TextCapitalization.none,
    );
    if (token == null || token.trim().isEmpty || _connecting) return;
    setState(() => _connecting = true);
    final state = await widget.room.scrobbleConnect(widget.service, token);
    if (!mounted) return;
    setState(() {
      _state = state;
      _connecting = false;
    });
    _say(switch (state.result) {
      'ok' => S.scrobbleConnectedAs(state.user ?? ''),
      'invalid' => S.scrobbleBadToken,
      _ => S.scrobbleOffline,
    });
  }

  /// Last.fm: asks for a token, opens the page where it is allowed, and waits for the person to come back.
  Future<void> _beginLastFm() async {
    if (_connecting) return;
    setState(() => _connecting = true);
    final begin = await widget.room.lastfmBegin();
    if (!mounted) return;
    final token = begin.token;
    final url = begin.url;
    if (token == null || url == null) {
      setState(() => _connecting = false);
      _say(begin.result == 'unavailable' ? S.lastFmUnavailable : S.lastFmOffline);
      return;
    }
    setState(() {
      _allowing = token;
      _connecting = false;
    });
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      // No browser to open it: said below, like a page that did not open
    }
    if (!opened && mounted) {
      setState(() => _allowing = null);
      _say(S.lastFmCannotOpen);
    }
  }

  Future<void> _finishLastFm() async {
    final token = _allowing;
    if (token == null || _connecting) return;
    setState(() => _connecting = true);
    final state = await widget.room.scrobbleConnect(widget.service, token);
    if (!mounted) return;
    setState(() {
      _state = state;
      _connecting = false;
      // Not allowed yet, or no network: the same token still works; any other answer ends it
      if (state.result != 'pending' && state.result != 'offline') {
        _allowing = null;
      }
    });
    _say(switch (state.result) {
      'ok' => S.scrobbleConnectedAs(state.user ?? ''),
      'pending' => S.lastFmNotAllowedYet,
      'invalid' => S.lastFmExpired,
      _ => S.lastFmOffline,
    });
  }

  Future<void> _disconnect() async {
    if (_state.pending > 0) {
      final ok = await showDialog<bool>(
        context: context,
        animationStyle: Motion.dialog(context),
        builder: (context) => AlertDialog(
          content: Text(S.scrobbleDisconnectQuestion(_state.pending)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(S.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(S.scrobbleDisconnect),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final state = await widget.room.scrobbleDisconnect(widget.service);
    if (mounted) setState(() => _state = state);
  }

  Future<void> _setNowPlaying(bool on) async {
    setState(
      () => _state = ScrobbleState(
        connected: _state.connected,
        user: _state.user,
        nowPlaying: on,
        pending: _state.pending,
        reconnect: _state.reconnect,
      ),
    );
    final state = await widget.room.scrobbleNowPlaying(widget.service, on);
    if (mounted) setState(() => _state = state);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final busy = const SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
    final icon = _connecting
        ? busy
        : Icon(Icons.edit_outlined, size: 18, color: p.textSecondary);
    if (!_state.connected) {
      return _Group(
        title: _name,
        footer: _lastFm ? S.lastFmHelp : S.scrobbleHelp,
        more: _lastFm ? S.lastFmMore : S.scrobbleMore,
        children: _lastFm ? _lastFmSteps(p, busy) : _listenBrainzSteps(p, icon),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Group(
          title: _name,
          footer: _state.reconnect
              ? (_lastFm ? S.lastFmReconnect : S.scrobbleReconnect)
              : null,
          children: [
            _Row(
              key: ValueKey('$_key-user'),
              label: _name,
              value: _state.user,
              leading: Icon(
                _state.reconnect
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                color: _state.reconnect ? p.error : p.primary,
              ),
              trailing: _state.reconnect ? icon : null,
              onTap: _state.reconnect && !_connecting
                  ? (_lastFm ? _beginLastFm : _connect)
                  : null,
            ),
            if (_state.pending > 0)
              _Row(
                key: ValueKey('$_key-pending'),
                label: S.scrobblePending(_state.pending),
              ),
            _Row(
              key: ValueKey('$_key-disconnect'),
              label: S.scrobbleDisconnect,
              onTap: _disconnect,
            ),
          ],
        ),
        _Group(
          footer: _lastFm ? S.lastFmNowPlayingHelp : S.scrobbleNowPlayingHelp,
          children: [
            Material(
              type: MaterialType.transparency,
              child: SwitchListTile(
                key: ValueKey('$_key-now-playing'),
                title: Text(S.scrobbleNowPlaying),
                value: _state.nowPlaying,
                onChanged: _setNowPlaying,
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _listenBrainzSteps(Palette p, Widget icon) => [
    _Row(
      key: const ValueKey('scrobble-get-token'),
      label: S.scrobbleGetToken,
      trailing: Icon(
        Icons.open_in_new_rounded,
        size: 18,
        color: p.textSecondary,
      ),
      onTap: () => launchUrl(
        Uri.parse('https://listenbrainz.org/settings/'),
        mode: LaunchMode.externalApplication,
      ),
    ),
    _Row(
      key: const ValueKey('scrobble-paste'),
      label: S.scrobbleEnterToken,
      value: _connecting ? S.scrobbleConnecting : S.scrobbleNotConnected,
      trailing: icon,
      onTap: _connecting ? null : _connect,
    ),
  ];

  /// Before the page is opened, one row; after, the person says they allowed it (or gives up).
  List<Widget> _lastFmSteps(Palette p, Widget busy) => _allowing == null
      ? [
          _Row(
            key: const ValueKey('lastfm-connect'),
            label: S.lastFmConnect,
            value: _connecting ? S.scrobbleConnecting : S.scrobbleNotConnected,
            trailing: _connecting
                ? busy
                : Icon(
                    Icons.open_in_new_rounded,
                    size: 18,
                    color: p.textSecondary,
                  ),
            onTap: _connecting ? null : _beginLastFm,
          ),
        ]
      : [
          _Row(
            key: const ValueKey('lastfm-allowed'),
            label: S.lastFmAllowed,
            value: _connecting ? S.scrobbleConnecting : S.lastFmWaiting,
            trailing: _connecting
                ? busy
                : Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: p.textSecondary,
                  ),
            onTap: _connecting ? null : _finishLastFm,
          ),
          _Row(
            key: const ValueKey('lastfm-cancel'),
            label: S.cancel,
            onTap: _connecting ? null : () => setState(() => _allowing = null),
          ),
        ];
}

/// Where the room server is and the key it asks for, for the phones that are not built with them.
class _ServerGroup extends StatelessWidget {
  const _ServerGroup({required this.room});

  final RoomController room;

  Future<void> _edit(BuildContext context, {required bool key}) async {
    final value = await showTextDialog(
      context,
      title: key ? S.serverKey : S.serverAddress,
      hint: key ? S.serverKey : 'https://…',
      initial: key ? '' : room.profile.server,
      maxLength: 200,
      capitalization: TextCapitalization.none,
    );
    if (value == null || (key && value.isEmpty)) return;
    await (key ? room.configure(key: value) : room.configure(server: value));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) => _Group(
        footer: kIsWeb ? S.serverHelpWeb : S.serverHelp,
        children: [
          // An Android build has its server built in: only its key is asked for
          if (kIsWeb || Platform.isIOS)
            _Row(
              key: const ValueKey('server-address'),
              label: S.serverAddress,
              value: room.profile.server,
              trailing: Icon(
                Icons.edit_outlined,
                size: 18,
                color: context.palette.textSecondary,
              ),
              onTap: () => _edit(context, key: false),
            ),
          _Row(
            key: const ValueKey('server-key'),
            label: S.serverKey,
            value: room.profile.hasKey ? S.serverKeySet : S.serverKeyNotSet,
            trailing: Icon(
              Icons.edit_outlined,
              size: 18,
              color: context.palette.textSecondary,
            ),
            onTap: () => _edit(context, key: true),
          ),
          _Row(
            key: const ValueKey('server-paste'),
            label: S.setupPaste,
            onTap: () => _paste(context),
          ),
          _Row(
            key: const ValueKey('server-check'),
            label: S.checkConnectionRow,
            onTap: () => _showServerCheck(context, room),
          ),
        ],
      ),
    );
  }

  /// Takes the server and key from a setup link that was copied, e.g. one sent from the other phone.
  Future<void> _paste(BuildContext context) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final link = SetupLink.parse(text);
    if (!context.mounted) return;
    if (link == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.setupBad)));
      return;
    }
    await askToUseSetup(context, room, link);
  }
}

/// Asks the server three things and says what it answered: whether it is there, whether it takes the key, and whether
/// it is new enough for this app.
Future<void> _showServerCheck(BuildContext context, RoomController room) async {
  final result = room.checkServer();
  await showDialog<void>(
    context: context,
    animationStyle: Motion.dialog(context),
    builder: (context) => FutureBuilder<ServerCheck>(
      future: result,
      builder: (context, snapshot) {
        final check = snapshot.data;
        final p = context.palette;
        Widget line(bool? ok, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                ok == null
                    ? Icons.help_outline_rounded
                    : ok
                    ? Icons.check_circle_rounded
                    : Icons.cancel_rounded,
                size: 20,
                color: ok == null
                    ? p.textTertiary
                    : ok
                    ? p.success
                    : p.error,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(text)),
            ],
          ),
        );
        final protocol = check?.protocol;
        return AlertDialog(
          title: Text(S.checkConnectionRow),
          content: check == null
              ? Row(
                  children: [
                    const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 14),
                    Text(S.checkingConnection),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    line(
                      check.reachable,
                      check.reachable
                          ? S.checkServerReached
                          : S.checkServerUnreachable,
                    ),
                    if (check.reachable) ...[
                      line(
                        check.keyAccepted,
                        check.keyAccepted == null
                            ? S.checkKeyUnknown
                            : check.keyAccepted!
                            ? S.checkKeyOk
                            : S.checkKeyRefused,
                      ),
                      line(
                        protocol == null
                            ? null
                            : protocol >= serverProtocolNeeded,
                        protocol == null
                            ? S.checkVersionUnknown
                            : protocol >= serverProtocolNeeded
                            ? S.checkVersionOk(protocol)
                            : S.checkVersionOld(protocol, serverProtocolNeeded),
                      ),
                    ],
                  ],
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(S.close),
            ),
          ],
        );
      },
    ),
  );
}

/// The version in use and, when there is a newer one, getting it and installing it.
class _UpdateGroup extends StatelessWidget {
  const _UpdateGroup({required this.update});

  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: update,
      builder: (context, _) {
        final info = update.info;
        final version = info.version ?? '';
        final busy =
            info.phase == UpdatePhase.checking ||
            info.phase == UpdatePhase.installing;
        final (
          String message,
          String? action,
          VoidCallback? onAction,
        ) = switch (info.phase) {
          UpdatePhase.available => (
            S.updateAvailable(version),
            S.updateDownload,
            () => downloadUpdate(context, update),
          ),
          UpdatePhase.downloading => (S.updateDownloading, null, null),
          UpdatePhase.ready => (
            S.updateReady(version),
            S.updateInstall,
            () => installUpdate(context, update),
          ),
          UpdatePhase.needsPermission => (
            S.updatePermission,
            S.updateOpenSettings,
            update.allowInstalls,
          ),
          UpdatePhase.checking => (S.updateChecking, null, null),
          UpdatePhase.installing => (S.updateInstalling, null, null),
          UpdatePhase.failed => (
            S.updateError(info.error),
            info.version == null ? S.updateCheck : S.updateTryAgain,
            info.version == null
                ? update.check
                : () => downloadUpdate(context, update),
          ),
          UpdatePhase.upToDate => (
            S.updateUpToDate,
            S.updateCheck,
            update.check,
          ),
          UpdatePhase.idle => (S.updateCheck, S.updateCheck, update.check),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Group(
              children: [
                _Row(label: S.updateVersion, value: info.installed),
                if (info.phase != UpdatePhase.idle)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (busy) ...[
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Text(message, style: theme.bodyLarge),
                            ),
                          ],
                        ),
                        if (info.phase == UpdatePhase.downloading) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            key: const ValueKey('update-progress'),
                            value: info.progress,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${formatBytes(info.done)} / ${formatBytes(info.size)}',
                            style: theme.bodySmall,
                          ),
                        ] else if (info.size > 0 && info.hasUpdate)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              formatBytes(info.size),
                              style: theme.bodySmall,
                            ),
                          ),
                        if (info.notes != null && info.hasUpdate) ...[
                          const SizedBox(height: 12),
                          Text(
                            S.updateWhatsNew,
                            style: theme.labelLarge?.copyWith(
                              color: p.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          ReleaseNotesText(info.notes!),
                        ],
                      ],
                    ),
                  ),
                if (action != null && !busy)
                  _Row(
                    key: ValueKey('update-action'),
                    label: action,
                    onTap: onAction,
                  ),
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    key: const ValueKey('auto-update-switch'),
                    title: Text(S.autoUpdate),
                    subtitle: Text(S.autoUpdateHelp),
                    value: info.autoUpdate,
                    onChanged: update.setAutoUpdate,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
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
    // A song finished does not tell the library, only the list of downloads
    widget.library.downloadList.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.library.removeListener(_load);
    widget.library.downloadList.removeListener(_load);
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
      more: S.cacheLimitMore,
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
            child: Text(S.clearCache),
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
            title: Text(S.autoDownload),
            subtitle: Text(S.autoDownloadHelp),
            value: _info.autoDownload,
            onChanged: (on) async {
              await library.setAutoDownload(on);
              _load();
            },
          ),
        ),
        // Only for playlists and folders switched on: liked songs keep to Wi-Fi, and a download asked for asks
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile(
            title: Text(S.offlineCellular),
            subtitle: Text(S.offlineCellularHelp),
            value: _info.offlineCellular,
            onChanged: (on) async {
              await library.setOfflineCellular(on);
              _load();
            },
          ),
        ),
        // Whether the list of the music on this phone is offered; on its own it is read only when opened
        ListenableBuilder(
          listenable: library,
          builder: (context, _) => Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              key: const ValueKey('local-music-switch'),
              title: Text(S.localMusicSwitch),
              subtitle: Text(S.localMusicSwitchBody),
              value: library.localStatus.enabled,
              onChanged: library.setLocalEnabled,
            ),
          ),
        ),
      ],
    );
  }
}

/// What a browser keeps for the page, in place of the downloads and the played songs that only an app has.
class _BrowserStorageGroup extends StatefulWidget {
  const _BrowserStorageGroup();

  @override
  State<_BrowserStorageGroup> createState() => _BrowserStorageGroupState();
}

class _BrowserStorageGroupState extends State<_BrowserStorageGroup> {
  BrowserStorage? _info;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await browserStorage();
    if (mounted) setState(() => _info = info);
  }

  Future<void> _keep() async {
    final kept = await keepBrowserStorage();
    if (!mounted) return;
    if (!kept) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(S.browserStorageDenied)));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return _Group(
      footer: S.browserStorageHelp,
      more: S.browserStorageMore,
      children: [
        if (info != null) ...[
          _Row(
            label: S.browserStorageUsed,
            value: '${formatBytes(info.usage)} / ${formatBytes(info.quota)}',
          ),
          _Row(
            key: const ValueKey('browser-storage-keep'),
            label: info.persistent
                ? S.browserStorageKept
                : S.browserStorageNotKept,
            trailing: info.persistent
                ? null
                : TextButton(
                    onPressed: _keep,
                    child: Text(S.browserStorageKeep),
                  ),
          ),
        ],
      ],
    );
  }
}

/// Keeps the library on the server, sealed, and alike on every device (see `data/sync`).
class _SyncGroup extends StatelessWidget {
  const _SyncGroup({required this.sync});

  final SyncController sync;

  String _status() => switch (sync.phase) {
    SyncPhase.syncing => S.syncSyncing,
    SyncPhase.failed => syncFailureText(sync.failure),
    SyncPhase.refused => S.syncPaused(sync.refused?.loss.likes ?? 0, sync.refused?.loss.playlists ?? 0),
    _ => sync.lastSync == null ? S.syncNotYet : S.syncDone(syncTime(sync.lastSync!), sync.deviceCount),
  };

  Future<void> _tapStatus(BuildContext context) async {
    final refused = sync.refused;
    if (sync.phase == SyncPhase.refused && refused != null) {
      if (await askSyncRefused(context, refused)) await sync.syncNow(force: true);
    } else {
      await sync.syncNow();
    }
  }

  Future<void> _turnOff(BuildContext context) async {
    final deleteCopy = await askTurnOff(context);
    if (deleteCopy == null) return;
    await sync.disable(deleteRemote: deleteCopy);
  }

  Future<void> _undo(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      animationStyle: Motion.dialog(context),
      builder: (context) => AlertDialog(
        content: Text(S.syncUndoQuestion),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(S.syncUndoFirst)),
        ],
      ),
    );
    if (ok == true) await sync.undoFirst();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) {
      final p = context.palette;
      if (!sync.enabled) {
        return _Group(
          footer: S.syncOffHelp,
          children: [
            _Row(
              key: const ValueKey('sync-turn-on'),
              label: S.syncTurnOn,
              leading: Icon(Icons.cloud_upload_outlined, color: p.primary),
              onTap: () => startSync(context, sync),
            ),
            _Row(
              key: const ValueKey('sync-use-code'),
              label: S.syncUseCode,
              leading: Icon(Icons.key_rounded, color: p.primary),
              onTap: () => joinSync(context, sync),
            ),
          ],
        );
      }
      final problem = sync.phase == SyncPhase.failed || sync.phase == SyncPhase.refused;
      // What is used day to day first; going back in time and turning it off apart, below
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Group(
            children: [
              _Row(
                key: const ValueKey('sync-status'),
                label: _status(),
                leading: sync.phase == SyncPhase.syncing
                    ? const SizedBox.square(dimension: 24, child: Padding(padding: EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 2)))
                    : Icon(problem ? Icons.error_outline_rounded : Icons.cloud_done_outlined, color: problem ? p.error : p.primary),
                trailing: sync.phase == SyncPhase.refused ? null : Icon(Icons.sync_rounded, size: 18, color: p.textTertiary),
                onTap: sync.phase == SyncPhase.syncing ? null : () => _tapStatus(context),
              ),
              _Row(
                key: const ValueKey('sync-add-device'),
                label: S.syncAddDevice,
                leading: Icon(Icons.qr_code_2_rounded, color: p.primary),
                onTap: () => showAddDevice(context, sync),
              ),
              _Row(
                key: const ValueKey('sync-recovery'),
                label: S.syncRecovery,
                value: sync.recoverySaved ? null : S.syncNotSaved,
                leading: Icon(Icons.key_rounded, color: p.primary),
                onTap: () => showRecoveryCode(context, sync),
              ),
            ],
          ),
          _Group(
            children: [
              _Row(
                key: const ValueKey('sync-restore'),
                label: S.syncRestore,
                leading: Icon(Icons.history_rounded, color: p.primary),
                onTap: () => showSyncVersions(context, sync),
              ),
              if (sync.firstCopy != null)
                _Row(
                  key: const ValueKey('sync-undo'),
                  label: S.syncUndoFirst,
                  leading: Icon(Icons.undo_rounded, color: p.primary),
                  onTap: () => _undo(context),
                ),
              _Row(
                key: const ValueKey('sync-turn-off'),
                label: S.syncTurnOff,
                leading: Icon(Icons.cloud_off_outlined, color: p.primary),
                onTap: () => _turnOff(context),
              ),
            ],
          ),
        ],
      );
    },
  );
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
          : [
              S.backupSaved(saved.liked, saved.playlists, saved.listens),
              if (saved.local > 0) S.backupLocalLeftOut(saved.local),
            ].join('. '),
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
      more: S.backupMore,
      children: [
        _Row(
          label: S.backupSave,
          leading: Icon(Icons.save_alt_rounded, color: p.primary),
          onTap: () => _save(context),
        ),
        _Row(
          label: S.backupAdd,
          leading: Icon(Icons.file_open_outlined, color: p.primary),
          onTap: () => _add(context),
        ),
      ],
    );
  }
}

/// A page of one topic, opened from the settings list. A page on its own paints its own backdrop.
class _SubPage extends StatelessWidget {
  const _SubPage({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => AmbientBackdrop(
    child: Padding(
      padding: SideInset.paddingOf(context),
      child: Scaffold(
        body: _SettingsList(title: title, children: children),
      ),
    ),
  );
}

/// The settings list, or a topic's page: a round Back, the title large, and what is under it scrolling up under the
/// glass edge.
class _SettingsList extends StatelessWidget {
  const _SettingsList({
    super.key,
    required this.title,
    required this.children,
    this.back = true,
  });

  final String title;
  final List<Widget> children;

  /// False for a topic beside the list on a wide screen, which goes back with the list.
  final bool back;

  @override
  Widget build(BuildContext context) => ScrollEdge(
    child: ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      // The mini player and the tab bar are drawn over the end of the page: it scrolls clear of them, so the
      // last button (Install, Download) can be reached however long the text above it is
      padding: EdgeInsets.fromLTRB(
        16,
        ScrollEdge.topOf(context) + 8,
        16,
        HomeShell.bottomInsetOf(context),
      ),
      children: [
        SizedBox(
          height: 48,
          child: back
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: BackButton(style: roundButtonStyle(context, size: 48)),
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 18),
          child: Text(title, style: Theme.of(context).textTheme.headlineLarge),
        ),
        ...children,
      ],
    ),
  );
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
            InkWell(
              key: const ValueKey('settings-profile'),
              onTap: () => showProfileSheet(context),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ListenableBuilder(
                      listenable: AppScope.of(context).settings,
                      builder: (context, _) => Avatar(
                        name: name,
                        size: 52,
                        image: AppScope.of(context).settings.avatar,
                      ),
                    ),
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
                                ? '${snapshot.name ?? S.tabRoom} · ${S.listening(snapshot.members.length)}'
                                : S.noRoom,
                            style: theme.bodyMedium?.copyWith(
                              color: p.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.edit_outlined, size: 18, color: p.textTertiary),
                  ],
                ),
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
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;

  /// Its topic is the one shown beside the list, on a wide screen.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ColoredBox(
      color: selected ? p.veilStrong : Colors.transparent,
      child: _Row(
        label: label,
        value: value,
        leading: Icon(icon, color: p.primary),
        trailing: Icon(Icons.chevron_right_rounded, color: p.textTertiary),
        onTap: onTap,
      ),
    );
  }
}

/// The Storage row, with how much the songs kept on this phone take up.
class _StorageRow extends StatefulWidget {
  const _StorageRow({
    required this.library,
    required this.onTap,
    required this.selected,
  });

  final LibraryController library;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<_StorageRow> createState() => _StorageRowState();
}

class _StorageRowState extends State<_StorageRow> {
  StorageInfo? _info;

  @override
  void initState() {
    super.initState();
    // A finished download is told through the list of downloads, not the library
    widget.library.addListener(_load);
    widget.library.downloadList.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.library.removeListener(_load);
    widget.library.downloadList.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final info = await widget.library.storage();
    if (info != null && mounted) setState(() => _info = info);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return _NavRow(
      selected: widget.selected,
      key: const ValueKey('settings-storage'),
      icon: Icons.download_for_offline_outlined,
      label: S.storage,
      value: info == null ? null : formatBytes(info.downloadBytes + info.playBytes),
      onTap: widget.onTap,
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({this.title, required this.children, this.footer, this.more});

  final String? title;
  final List<Widget> children;

  /// One short sentence under the group.
  final String? footer;

  /// The rest of what there is to say, shown only when asked for, so that the page stays short.
  final String? more;

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
          // See-through on the page's backdrop, like the rest of what sits on it
          if (children.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                color: p.veil,
                borderRadius: BorderRadius.circular(SapocheTheme.groupRadius),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        indent: 16,
                        color: p.text.withValues(alpha: 0.07),
                      ),
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
          if (more != null) _More(text: more!),
        ],
      ),
    );
  }
}

/// "Learn more" under a group, which turns into the longer explanation in place, with "Less" under it to fold it again.
class _More extends StatefulWidget {
  const _More({required this.text});

  final String text;

  @override
  State<_More> createState() => _MoreState();
}

class _MoreState extends State<_More> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final toggle = Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () => setState(() => _open = !_open),
        child: Text(_open ? S.showLess : S.learnMore),
      ),
    );
    if (!_open) return toggle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Text(
            widget.text,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        toggle,
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.label,
    this.subtitle,
    this.value,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String label;

  /// A line under the label saying what it does.
  final String? subtitle;
  final String? value;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: LayoutBuilder(
          builder: (context, box) => _line(context, p, theme, box.maxWidth),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, Palette p, TextTheme theme, double width) => Row(
    children: [
      if (leading != null) ...[leading!, const SizedBox(width: 14)],
      Expanded(
        child: subtitle == null
            ? Text(label, style: theme.bodyLarge?.copyWith(color: p.text))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.bodyLarge?.copyWith(color: p.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.bodySmall?.copyWith(
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
      ),
      if (value != null)
        // As wide as the words need, up to half the window and most of the row (on a wide window the list is narrow):
        // a long address must not push the label out
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(MediaQuery.sizeOf(context).width * 0.5, width * 0.6),
          ),
          child: Text(
            value!,
            maxLines: 1,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: theme.bodyLarge?.copyWith(color: p.textSecondary),
          ),
        ),
      if (trailing != null) ...[const SizedBox(width: 10), trailing!],
    ],
  );
}

/// The equalizer: the presets, the six bands, and (on a phone that has one) a way into its own equalizer.
class _EqualizerPanel extends StatelessWidget {
  const _EqualizerPanel({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final eq = controller.equalizer;
      final ios = !kIsWeb && Platform.isIOS;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Group(
            title: S.eqPresets,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                // Two even columns, so that the chips stand in rows and the frame is as wide as the page
                child: LayoutBuilder(
                  builder: (context, box) {
                    const gap = 8.0;
                    final width = (box.maxWidth - gap) / 2;
                    return Wrap(
                      spacing: gap,
                      runSpacing: 4,
                      children: [
                        for (final id in [...EqPreset.all, EqPreset.custom])
                          SizedBox(
                            width: width,
                            child: ChoiceChip(
                              key: ValueKey('eq-preset-$id'),
                              label: SizedBox(
                                width: double.infinity,
                                child: Text(
                                  S.eqPreset(id),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              selected: eq.preset == id,
                              // "Custom" keeps the bands as they are and only says that they are one's own
                              onSelected: (_) => controller.setEqualizer(
                                id == EqPreset.custom
                                    ? EqSettings(preset: id, gains: eq.gains)
                                    : EqPreset.of(id),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
          _Group(
            title: S.eqBands,
            footer: ios ? '${S.eqHelp}\n\n${S.eqHelpIos}' : S.eqHelp,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                child: Row(
                  children: [
                    for (var band = 0; band < eqBands; band++)
                      Expanded(
                        child: _EqBand(
                          band: band,
                          gain: eq.gains[band],
                          onChanged: (gain) =>
                              controller.setEqualizer(eq.withBand(band, gain)),
                        ),
                      ),
                  ],
                ),
              ),
              _Row(
                key: const ValueKey('eq-reset'),
                label: S.eqReset,
                leading: Icon(
                  Icons.restart_alt_rounded,
                  color: eq.isFlat && eq.preset == EqPreset.off
                      ? context.palette.textTertiary
                      : context.palette.primary,
                ),
                onTap: eq.isFlat && eq.preset == EqPreset.off
                    ? null
                    : () => controller.setEqualizer(EqPreset.of(EqPreset.off)),
              ),
            ],
          ),
          if (controller.hasSystemEqualizer)
            _Group(
              children: [
                _Row(
                  key: const ValueKey('eq-system'),
                  label: S.eqSystem,
                  leading: Icon(
                    Icons.tune_rounded,
                    color: context.palette.primary,
                  ),
                  trailing: Icon(
                    Icons.open_in_new_rounded,
                    color: context.palette.textTertiary,
                  ),
                  onTap: controller.openSystemEqualizer,
                ),
              ],
            ),
        ],
      );
    },
  );
}

/// One band: its gain above a slider that stands up, and its frequency under it.
class _EqBand extends StatelessWidget {
  const _EqBand({
    required this.band,
    required this.gain,
    required this.onChanged,
  });

  final int band;
  final int gain;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final frequency = S.eqBand(eqFrequencies[band]);
    return Column(
      children: [
        Text(
          gain > 0 ? '+$gain' : '$gain',
          style: theme.bodySmall?.copyWith(
            color: gain == 0 ? p.textSecondary : p.primary,
          ),
        ),
        SizedBox(
          height: 190,
          // A band is a boost or a cut from the middle, so the track is not filled from the bottom: only the thumb moves
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: p.text.withValues(alpha: 0.24),
              inactiveTrackColor: p.text.withValues(alpha: 0.24),
              activeTickMarkColor: Colors.transparent,
              inactiveTickMarkColor: Colors.transparent,
            ),
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                key: ValueKey('eq-band-$band'),
                value: gain.toDouble(),
                min: minEqGain.toDouble(),
                max: maxEqGain.toDouble(),
                divisions: maxEqGain - minEqGain,
                semanticFormatterCallback: (v) =>
                    '$frequency, ${S.eqGain(v.round())}',
                onChanged: (v) {
                  if (v.round() != gain) onChanged(v.round());
                },
              ),
            ),
          ),
        ),
        Text(
          frequency,
          maxLines: 1,
          style: theme.labelSmall?.copyWith(color: p.textSecondary),
        ),
      ],
    );
  }
}

/// How long the soft change between songs is, from off to [maxCrossfadeSeconds] seconds.
class _CrossfadeRow extends StatefulWidget {
  const _CrossfadeRow({required this.controller});

  final RoomController controller;

  @override
  State<_CrossfadeRow> createState() => _CrossfadeRowState();
}

class _CrossfadeRowState extends State<_CrossfadeRow> {
  double? _dragging;

  static String _label(int seconds) =>
      seconds == 0 ? S.crossfadeOff : S.crossfadeSeconds(seconds);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final saved = widget.controller.crossfadeSeconds;
        final value = (_dragging ?? saved.toDouble()).clamp(
          0.0,
          maxCrossfadeSeconds.toDouble(),
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: Text(S.crossfade, style: theme.bodyLarge)),
                  Text(
                    _label(value.round()),
                    style: theme.bodyLarge?.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
              Slider(
                key: const ValueKey('crossfade-slider'),
                value: value,
                max: maxCrossfadeSeconds.toDouble(),
                divisions: maxCrossfadeSeconds,
                label: _label(value.round()),
                semanticFormatterCallback: (v) => _label(v.round()),
                onChanged: (v) => setState(() => _dragging = v),
                onChangeEnd: (v) {
                  widget.controller.setCrossfade(v.round());
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
                    child: Text(S.reset),
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

/// The colours the app can wear: the presets, then a circle that opens the picker for a colour of the person's own.
class _AccentSwatches extends StatelessWidget {
  const _AccentSwatches({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final chosen = settings.accent ?? Palette.pinkAccent;
    final preset = accentPresetId(chosen);
    final swatches = [
      for (final (id, color) in accentPresets)
        _Swatch(
          key: ValueKey('accent-$id'),
          label: S.accentName(id),
          color: color,
          selected: preset == id,
          // Pink is the default, so it is stored as nothing
          onTap: () => settings.accent = id == 'pink' ? null : color,
        ),
      _Swatch(
        key: const ValueKey('accent-custom'),
        label: S.accentCustom,
        color: preset == null ? chosen : null,
        selected: preset == null,
        onTap: () async {
          final picked = await showAccentPicker(context, chosen);
          if (picked != null) settings.accent = picked;
        },
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: LayoutBuilder(
        builder: (context, box) {
          // As many rows as the width needs, then as many circles in each as share them evenly (9 are 5 and 4, not
          // 6 and 3), every circle in the middle of a cell of the same width so that nothing is left over at one side
          final fit = (box.maxWidth / (_Swatch.size + 8)).floor().clamp(
            1,
            swatches.length,
          );
          final rows = (swatches.length / fit).ceil();
          final columns = (swatches.length / rows).ceil();
          final cell = (box.maxWidth / columns).floorToDouble();
          return Wrap(
            runSpacing: 8,
            children: [
              for (final swatch in swatches)
                SizedBox(
                  width: cell,
                  child: Center(child: swatch),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// One round colour; without [color] it shows the whole spectrum, for the picker.
class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  static const size = 48.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: FocusTap(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? p.text : Colors.transparent,
              width: 2,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              gradient: color == null
                  ? SweepGradient(
                      colors: [
                        for (var h = 0; h <= 360; h += 60)
                          HSVColor.fromAHSV(
                            1,
                            h.toDouble(),
                            0.85,
                            0.95,
                          ).toColor(),
                      ],
                    )
                  : null,
            ),
            child: selected
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
                : color == null
                ? const Icon(Icons.add_rounded, color: Colors.white, size: 20)
                : null,
          ),
        ),
      ),
    );
  }
}

/// One line above the artists of the person's taste that says what the two buttons at the end of each row are.
class _TasteLegend extends StatelessWidget {
  const _TasteLegend();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: p.textSecondary);
    Widget item(IconData icon, Color color, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(text, style: style),
      ],
    );
    return Padding(
      key: const ValueKey('taste-legend'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          item(Icons.remove_circle_outline_rounded, p.primary, S.suggestLess),
          item(Icons.block_rounded, p.textTertiary, S.blockArtist),
        ],
      ),
    );
  }
}

/// An artist of the person's taste: how much they listen to them beside the artist they listen to most, and the ways
/// to hear less of them.
class _TasteArtistRow extends StatelessWidget {
  const _TasteArtistRow({
    super.key,
    required this.artist,
    required this.share,
    required this.quiet,
    required this.onQuiet,
    required this.onBlock,
  });

  final ArtistRank artist;

  /// Their score as a part of the highest, 0 to 1.
  final double share;
  final bool quiet;
  final VoidCallback onQuiet;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Opacity(
      opacity: quiet ? 0.55 : 1,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4, top: 6, bottom: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    artist.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodyLarge,
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      key: const ValueKey('taste-bar'),
                      value: share.clamp(0.0, 1.0),
                      minHeight: 3,
                      color: p.primary,
                      backgroundColor: p.text.withValues(alpha: 0.08),
                    ),
                  ),
                  if (quiet) ...[
                    const SizedBox(height: 4),
                    Text(S.tasteFewer, style: theme.bodySmall),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: S.suggestLess,
              onPressed: onQuiet,
              icon: Icon(
                quiet
                    ? Icons.trending_down_rounded
                    : Icons.remove_circle_outline_rounded,
                color: p.primary,
              ),
            ),
            IconButton(
              tooltip: S.blockArtist,
              onPressed: onBlock,
              icon: Icon(Icons.block_rounded, color: p.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// How often songs were left in their first seconds, for each source that has enough listens to say.
class _TasteStats extends StatelessWidget {
  const _TasteStats({required this.stats});

  /// A source with fewer listens than this says nothing: two or three skips are not a rate.
  static const minListens = 20;

  final List<SourceStats> stats;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[];
    for (final (source, line) in <(String, String Function(int))>[
      (ListenSource.auto, S.tasteStatsAuto),
      (ListenSource.shelf, S.tasteStatsShelf),
      (ListenSource.chosen, S.tasteStatsChosen),
    ]) {
      final found = stats
          .where((s) => s.source == source && s.total >= minListens)
          .firstOrNull;
      if (found != null) lines.add(line((found.skipRate! * 100).round()));
    }
    return SizedBox(
      key: const ValueKey('taste-stats'),
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines.isEmpty ? [S.tasteStatsNone] : lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  line,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: lines.isEmpty ? context.palette.textSecondary : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The heights of the picture to choose from on this device. What was chosen on a device that plays more is shown as
/// the tallest this one has.
class _SettingQualityChips extends StatelessWidget {
  const _SettingQualityChips({required this.snapshot, required this.onPick});

  final RoomSnapshot snapshot;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final options = videoQualities(snapshot);
    final chosen = options.lastWhere(
      (h) => h <= snapshot.videoHeight,
      orElse: () => options.first,
    );
    // The heights as they come, one after the other from the start, on to the next line when there is no more room
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final h in options)
          ChoiceChip(
            key: ValueKey('setting-quality-$h'),
            label: Text(qualityName(h)),
            // The chip would grow by the tick when chosen, and move the ones after it
            showCheckmark: false,
            selected: chosen == h,
            onSelected: (_) => onPick(h),
          ),
      ],
    );
  }
}
