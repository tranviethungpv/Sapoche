import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/log_line.dart';
import '../data/log_model.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'log_share.dart';
import 'scope.dart';
import 'widgets/ambient_backdrop.dart';
import 'widgets/motion.dart';
import 'widgets/page_width.dart' show SideInset;
import 'widgets/play_row.dart';
import 'widgets/focus_nav.dart';

/// Reads the lines the log page was given: off the main isolate when there are many.
LogModel _parseLog(List<String> raw) => LogModel.parse(raw);

/// Settings > Diagnostics > Log: what the app did, for the person who wants to know whether something went wrong and for
/// whoever debugs it. The summary on top says at a glance whether there are errors; the list is cut into runs of the app,
/// shows the main lines first and folds the noise; a line opens into its detail; "Mark" leaves a flag at a moment and
/// "Share file" sends the whole log as a file.
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  /// The width of the page from which the line opens beside the list instead of in a sheet.
  static const _wideFrom = 900.0;
  static const _poll = Duration(seconds: 3);

  /// From this many rows the list runs from its end (see [_reversed]).
  static const _reverseFrom = 120;

  final _scroll = ScrollController();
  final _query = TextEditingController();
  final _target = GlobalKey();
  Timer? _timer;

  LogModel? _log;

  /// A newer log, kept back while the person reads older lines so that they do not move; taken by [_refresh].
  LogModel? _pending;
  List<String> _info = const [];
  int _rawCount = -1;
  LogMode _mode = LogMode.main;
  final _groups = <LogGroup>{};
  final _levels = <LogLevel>{};
  final _open = <String>{};
  bool _searching = false;
  List<LogRow> _rows = const [];
  List<int> _matches = const [];
  int _match = -1;
  int? _errorAt;
  LogLine? _selected;
  int _selectedAt = -1;
  int? _flash;
  bool _atBottom = true;
  int _newLines = 0;
  bool _loading = true;
  bool _wide = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(first: true));
    _timer = Timer.periodic(_poll, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  RoomController get _room => AppScope.of(context).room;

  /// A long list is laid out from its end, where the newest lines are. Run from its start, getting to its end means laying
  /// out every row on the way, as rows differ in height: over a second for a full log on a phone, the stutter of opening
  /// the page. A short one runs from its start, as one from its end would sit at the bottom of the page.
  bool get _reversed => _rows.length >= _reverseFrom;

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final nearEnd = _reversed
        ? _scroll.offset < 80
        : _scroll.position.maxScrollExtent - _scroll.offset < 80;
    if (nearEnd != _atBottom || (nearEnd && _newLines > 0)) {
      final caughtUp = nearEnd && _pending != null;
      setState(() {
        _atBottom = nearEnd;
        if (nearEnd) _newLines = 0;
        if (caughtUp) _refresh();
      });
      if (caughtUp) _toBottom();
    }
  }

  Future<void> _load({bool first = false}) async {
    final room = _room;
    final raw = await room.log();
    if (!mounted) return;
    if (!first && raw.length == _rawCount) return;
    final model = raw.length > 3000
        ? await compute(_parseLog, raw)
        : _parseLog(raw);
    final info = first ? await room.logInfo() : _info;
    if (!mounted) return;
    final added = _rawCount < 0 ? 0 : raw.length - _rawCount;
    final follow = first || _atBottom;
    setState(() {
      _info = info;
      _rawCount = raw.length;
      _loading = false;
      if (follow) {
        _log = model;
        _pending = null;
        _refresh();
      } else {
        _pending = model;
        if (added > 0) _newLines += added;
      }
    });
    if (follow) _toBottom();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!_scroll.hasClients) return;
    if (_reversed) {
      _scroll.jumpTo(0);
      return;
    }
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    // The extent of rows not drawn yet is an estimate: once more, with what was drawn
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  });

  /// Works the rows and the matches out again after the log or a filter changed.
  void _refresh() {
    final pending = _pending;
    if (pending != null) {
      _log = pending;
      _pending = null;
    }
    final model = _log;
    if (model == null) return;
    final query = _query.text.trim();
    _rows = model.rows(
      mode: _mode,
      groups: _groups,
      levels: _levels,
      query: query,
      open: _open,
      fold: query.isEmpty,
    );
    _matches = query.isEmpty
        ? const []
        : [
            for (var i = 0; i < _rows.length; i++)
              if (_rows[i] is LineRow) i,
          ];
    if (_match >= _matches.length) _match = _matches.isEmpty ? -1 : 0;
    _errorAt = null;
  }

  /// Applies a change of the filters and works the rows out again. The list goes back to its end (the newest lines), as a
  /// list that changed under the person's finger has no place worth keeping; [bottom] false for a caller that moves to a
  /// line itself.
  void _change(VoidCallback change, {bool bottom = true}) {
    setState(() {
      change();
      _refresh();
    });
    if (bottom) _toBottom();
  }

  /// Brings row [index] into view: a guess from the rows drawn so far, then the row itself once it is drawn.
  void _jumpTo(int index, {int? flash}) {
    if (!_scroll.hasClients || _rows.isEmpty) return;
    final position = _scroll.position;
    final per =
        (position.maxScrollExtent + position.viewportDimension) / _rows.length;
    // Where the row is, a third of the way down the page; a list that runs from its end counts from the bottom
    double guess(double place) =>
        (_reversed
                ? (_rows.length - 1 - index) * per -
                      position.viewportDimension * (1 - place)
                : index * per - position.viewportDimension * place)
            .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(guess(1 / 3));
    setState(
      () => _flash =
          flash ??
          (_rows[index] is LineRow ? (_rows[index] as LineRow).at : null),
    );
    for (var attempt = 0; attempt < 3; attempt++) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = _target.currentContext;
        if (context != null) {
          Scrollable.ensureVisible(
            context,
            alignment: .3,
            duration: Duration.zero,
          );
        } else if (_scroll.hasClients && attempt == 2) {
          _scroll.jumpTo(guess(0));
        }
      });
    }
  }

  List<int> get _errorRows => [
    for (var i = 0; i < _rows.length; i++)
      if (_rows[i] is LineRow &&
          (_rows[i] as LineRow).line.level == LogLevel.error)
        i,
  ];

  void _goToError(int step) {
    final errors = _errorRows;
    if (errors.isEmpty) return;
    // The first touch goes to the newest error, the nearest one; then Previous goes back in time, Next forward
    final at = _errorAt == null
        ? errors.length - 1
        : (_errorAt! + step).clamp(0, errors.length - 1);
    _errorAt = at;
    _jumpTo(errors[at]);
  }

  void _goToMatch(int step) {
    if (_matches.isEmpty) return;
    final at = _match < 0
        ? (step > 0 ? 0 : _matches.length - 1)
        : (_match + step) % _matches.length;
    setState(() => _match = at);
    _jumpTo(_matches[at]);
  }

  void _showHidden(HiddenRow row) {
    _change(() {
      _mode = LogMode.all;
      _levels.clear();
      _groups.clear();
    }, bottom: false);
    final index = _rows.indexWhere((r) => r is LineRow && r.at >= row.at);
    if (index >= 0) _jumpTo(index);
  }

  void _showAround(LogLine line, int at) {
    _change(() {
      _mode = LogMode.detail;
      _levels.clear();
      _groups.clear();
      _query.clear();
      _searching = false;
    });
    final index = _rows.indexWhere(
      (r) =>
          (r is LineRow && r.at == at) ||
          (r is FoldRow && r.lines.any((l) => l.at == at)),
    );
    if (index >= 0) {
      final row = _rows[index];
      if (row is FoldRow) _change(() => _open.add(row.key), bottom: false);
      final again = _rows.indexWhere((r) => r is LineRow && r.at == at);
      _jumpTo(again >= 0 ? again : index, flash: at);
    }
  }

  void _selectLine(LogLine line, int at) {
    if (_wide) {
      setState(() {
        _selected = line;
        _selectedAt = at;
      });
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: Motion.sheet(context),
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        maxChildSize: .95,
        builder: (_, controller) => _LineDetail(
          model: _log!,
          line: line,
          at: at,
          scroll: controller,
          onAround: () {
            Navigator.of(sheet).pop();
            _showAround(line, at);
          },
        ),
      ),
    );
  }

  Future<void> _mark() async {
    final room = _room;
    final messenger = ScaffoldMessenger.of(context);
    final note = await showDialog<String>(
      context: context,
      animationStyle: Motion.dialog(context),
      builder: (_) => const _MarkDialog(),
    );
    if (note == null) return;
    await room.logMark(note);
    messenger.showSnackBar(SnackBar(content: Text(S.logMarked)));
    await _load(first: true);
    _toBottom();
  }

  Future<void> _share() async {
    final room = _room;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final text = await room.logExport();
      final version = _info
          .firstWhere((l) => l.startsWith('app: '), orElse: () => 'app: ?')
          .substring(5);
      final platform = kIsWeb
          ? 'web'
          : defaultTargetPlatform.name.toLowerCase();
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final name =
          'sapoche-log-$version-$platform-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}.txt';
      await shareLogFile(name.replaceAll('+', '_'), text);
    } on Object {
      messenger.showSnackBar(SnackBar(content: Text(S.logShareFailed)));
    }
  }

  Future<void> _copyShort() async {
    final room = _room;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(
      ClipboardData(text: await room.logExport(short: true)),
    );
    messenger.showSnackBar(SnackBar(content: Text(S.logCopied)));
  }

  Future<void> _clear() async {
    final room = _room;
    final sure = await showDialog<bool>(
      context: context,
      animationStyle: Motion.dialog(context),
      builder: (dialog) => AlertDialog(
        title: Text(S.logClearQuestion),
        content: Text(S.logClearHelp),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(S.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(S.logClear),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await room.logClear();
    _change(() {
      _open.clear();
      _selected = null;
    });
    await _load(first: true);
  }

  @override
  Widget build(BuildContext context) => AmbientBackdrop(
    child: Padding(
      padding: SideInset.paddingOf(context),
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, box) {
            final wide = _wide = box.maxWidth >= _wideFrom;
            final list = _column(context, wide);
            if (!wide) return list;
            return Row(
              children: [
                Expanded(flex: 3, child: list),
                VerticalDivider(width: 1, color: context.palette.outlineSoft),
                Expanded(
                  flex: 2,
                  child: _selected == null || _log == null
                      ? const _PickLine()
                      : _LineDetail(
                          key: ValueKey(_selectedAt),
                          model: _log!,
                          line: _selected!,
                          at: _selectedAt,
                          onAround: () => _showAround(_selected!, _selectedAt),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  /// The summary and the filters, above the lines (or the first thing of them, on a short screen).
  Widget _top(LogModel model) => Column(
    children: [
      _SummaryCard(
        model: model,
        levels: _levels,
        onLevel: (level) => _change(() {
          if (!_levels.remove(level)) _levels.add(level);
        }),
        onPrevious: () {
          final at = model.runs.length - 2;
          if (at < 0) return;
          _change(() {
            _mode = LogMode.main;
            _levels.clear();
            _groups.clear();
          }, bottom: false);
          _jumpTo(_rows.indexWhere((r) => r is RunRow && r.index == at));
        },
      ),
      _FilterBar(
        mode: _mode,
        groups: _groups,
        searching: _searching,
        query: _query,
        matches: _matches.length,
        match: _match,
        onMode: (mode) => _change(() => _mode = mode),
        onGroup: (group) => _change(() {
          if (!_groups.remove(group)) _groups.add(group);
        }),
        onSearch: () => _change(() {
          _searching = !_searching;
          if (!_searching) _query.clear();
        }),
        onQuery: () => _change(() => _match = -1, bottom: false),
        onPreviousMatch: () => _goToMatch(-1),
        onNextMatch: () => _goToMatch(1),
      ),
    ],
  );

  Widget _column(BuildContext context, bool wide) {
    final p = context.palette;
    final model = _log;
    final errors = _errorRows;
    // A phone on its side: the summary and the filters scroll with the lines, or they would leave none of the screen
    final compact = MediaQuery.sizeOf(context).height < 600;
    return Column(
      children: [
        SizedBox(height: MediaQuery.paddingOf(context).top),
        _header(context),
        if (model != null && !compact) _top(model),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    _timeline(context, wide, compact),
                    if (errors.isNotEmpty)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: _ErrorJump(
                          onPrevious: () => _goToError(-1),
                          onNext: () => _goToError(1),
                        ),
                      ),
                    if (_newLines > 0 && !_atBottom)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 12,
                        child: Center(
                          child: FilledButton.icon(
                            key: const ValueKey('log-new-lines'),
                            onPressed: () {
                              setState(() {
                                _newLines = 0;
                                _refresh();
                              });
                              _toBottom();
                            },
                            icon: const Icon(Icons.arrow_downward_rounded),
                            label: Text(S.logNewLines),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        Material(
          color: p.surface,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              HomeShell.bottomInsetOf(context),
            ),
            child: _actions(context),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
    child: SizedBox(
      height: 56,
      child: Row(
        children: [
          BackButton(style: roundButtonStyle(context, size: 48)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              S.logTitle,
              style: Theme.of(context).textTheme.headlineMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            key: const ValueKey('log-device'),
            tooltip: S.logDevice,
            onPressed: _showDevice,
            style: roundButtonStyle(context, size: 48),
            icon: const Icon(Icons.smartphone_rounded),
          ),
          const SizedBox(width: 4),
          _menu(context),
        ],
      ),
    ),
  );

  Widget _menu(BuildContext context) => PopupMenuButton<String>(
    key: const ValueKey('log-menu'),
    tooltip: S.logMore,
    popUpAnimationStyle: Motion.dialog(context),
    style: roundButtonStyle(context, size: 48),
    icon: const Icon(Icons.more_vert_rounded),
    onSelected: (value) => value == 'short' ? _copyShort() : _clear(),
    itemBuilder: (_) => [
      PopupMenuItem(value: 'short', child: Text(S.logCopyShort)),
      PopupMenuItem(value: 'clear', child: Text(S.logClear)),
    ],
  );

  void _showDevice() => showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: Motion.sheet(context),
    useRootNavigator: true,
    showDragHandle: true,
    builder: (sheet) => Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.paddingOf(sheet).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(S.logDevice, style: Theme.of(sheet).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            _info.join('\n'),
            style: Theme.of(sheet).textTheme.bodyMedium
                ?.copyWith(color: sheet.palette.text),
          ),
        ],
      ),
    ),
  );

  Widget _actions(BuildContext context) {
    // Two modest buttons in the middle, 48 dp high: only the second one is filled, so the eye has one place to go
    const size = Size(0, 48);
    final p = context.palette;
    final mark = FilledButton.tonalIcon(
      key: const ValueKey('log-mark'),
      onPressed: _mark,
      style: FilledButton.styleFrom(
        minimumSize: size,
        backgroundColor: p.primaryContainer,
        foregroundColor: p.onPrimaryContainer,
      ),
      icon: const Icon(Icons.flag_rounded, size: 20),
      label: Text(S.logMark),
    );
    final share = FilledButton.icon(
      key: const ValueKey('log-share'),
      onPressed: _share,
      style: FilledButton.styleFrom(minimumSize: size),
      icon: const Icon(Icons.ios_share_rounded, size: 20),
      label: Text(S.logShare, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    // Large text: the two buttons one above the other, as side by side the second would be cut
    final stacked = MediaQuery.textScalerOf(context).scale(10) > 11.5;
    if (stacked) {
      return Column(
        children: [
          SizedBox(width: double.infinity, child: mark),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: share),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [mark, const SizedBox(width: 12), share],
    );
  }

  Widget _timeline(BuildContext context, bool wide, bool compact) {
    final model = _log;
    if (model == null ||
        model.lines.isEmpty ||
        _rows.every((r) => r is RunRow || r is DayRow || r is HiddenRow)) {
      final empty = _Empty(
        onAll: _mode == LogMode.main && model != null && model.lines.isNotEmpty
            ? () => _change(() => _mode = LogMode.all)
            : null,
      );
      return compact && model != null
          ? ListView(children: [_top(model), empty])
          : empty;
    }
    final header = compact ? 1 : 0;
    final count = _rows.length + header;
    final reversed = _reversed;
    return ListView.builder(
      controller: _scroll,
      reverse: reversed,
      padding: const EdgeInsets.only(bottom: 72),
      itemCount: count,
      itemBuilder: (context, index) {
        final at = reversed ? count - 1 - index : index;
        if (header == 1 && at == 0) return _top(model);
        final i = at - header;
        final row = _rows[i];
        final query = _query.text.trim();
        return switch (row) {
          RunRow() => _RunHeader(row: row),
          DayRow() => _DayHeader(day: row.day),
          LineRow() => _LineTile(
            key: _flash == row.at ? _target : null,
            line: row.line,
            flash: _flash == row.at,
            current:
                _match >= 0 &&
                _match < _matches.length &&
                _matches[_match] == i,
            selected: _selectedAt == row.at && _selected != null,
            query: query,
            onTap: () => _selectLine(row.line, row.at),
          ),
          FoldRow() => _FoldTile(
            row: row,
            onTap: () => _change(() => _open.add(row.key)),
          ),
          HiddenRow() => _HiddenTile(row: row, onTap: () => _showHidden(row)),
        };
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------

/// The colors and the icon of a level. The color is never the only sign: every level but the quiet ones has an icon too.
class _LevelLook {
  const _LevelLook(this.fg, this.bg, this.icon, this.label);

  final Color fg;
  final Color? bg;
  final IconData? icon;
  final String label;

  static const _warnLight = Color(0xFF7A4B00);
  static const _warnLightBg = Color(0xFFFFF0CC);
  static const _warnDark = Color(0xFFFFC857);

  static _LevelLook of(BuildContext context, LogLevel level) {
    final p = context.palette;
    final dark = p.brightness == Brightness.dark;
    return switch (level) {
      LogLevel.error => _LevelLook(
        p.error,
        p.error.withValues(alpha: dark ? .16 : .09),
        Icons.error_rounded,
        S.logErrors,
      ),
      LogLevel.warn => _LevelLook(
        dark ? _warnDark : _warnLight,
        dark ? _warnDark.withValues(alpha: .14) : _warnLightBg,
        Icons.warning_rounded,
        S.logWarnings,
      ),
      LogLevel.main => _LevelLook(p.primary, null, Icons.circle, S.logModeMain),
      LogLevel.info => _LevelLook(p.textSecondary, null, null, S.logModeAll),
      LogLevel.detail => _LevelLook(
        p.textTertiary,
        null,
        null,
        S.logModeDetail,
      ),
    };
  }
}

IconData _groupIcon(LogGroup group) => switch (group) {
  LogGroup.play => Icons.music_note_rounded,
  LogGroup.room => Icons.groups_rounded,
  LogGroup.network => Icons.wifi_rounded,
  LogGroup.system => Icons.memory_rounded,
  LogGroup.update => Icons.system_update_rounded,
  LogGroup.ui => Icons.phone_android_rounded,
  LogGroup.other => Icons.more_horiz_rounded,
};

String _groupName(LogGroup group) => switch (group) {
  LogGroup.play => S.logGroupPlay,
  LogGroup.room => S.logGroupRoom,
  LogGroup.network => S.logGroupNetwork,
  LogGroup.system => S.logGroupSystem,
  LogGroup.update => S.logGroupUpdate,
  LogGroup.ui => S.logGroupUi,
  LogGroup.other => S.logGroupOther,
};

String _two(int n) => n.toString().padLeft(2, '0');

String _clock(DateTime? t, {bool seconds = true}) => t == null
    ? '--:--'
    : '${_two(t.hour)}:${_two(t.minute)}${seconds ? ':${_two(t.second)}' : ''}';

String _dayName(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return S.logToday;
  if (diff == 1) return S.logYesterday;
  return '${_two(day.day)}/${_two(day.month)}';
}

// ---------------------------------------------------------------------------------------------------------------------

/// The state of the log in one look: is anything wrong in this run. The counts filter the list when touched.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.model,
    required this.levels,
    required this.onLevel,
    required this.onPrevious,
  });

  final LogModel model;
  final Set<LogLevel> levels;
  final ValueChanged<LogLevel> onLevel;
  final VoidCallback onPrevious;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final digest = model.digest;
    final theme = Theme.of(context).textTheme;
    final warn = _LevelLook.of(context, LogLevel.warn);
    final color = digest.errors > 0
        ? p.error
        : digest.warnings > 0
        ? warn.fg
        : p.success;
    final icon = digest.errors > 0
        ? Icons.error_rounded
        : digest.warnings > 0
        ? Icons.warning_rounded
        : Icons.check_circle_rounded;
    return _Narrow(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.outlineSoft),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The tiles carry the counts; the sentence is only for a run with nothing wrong
                if (digest.clean) ...[
                  Row(
                    children: [
                      Icon(icon, color: color, size: 26),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          S.logClean,
                          key: const ValueKey('log-summary'),
                          style: theme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    for (final (level, count) in [
                      (LogLevel.error, digest.errors),
                      (LogLevel.warn, digest.warnings),
                      (LogLevel.main, digest.marks),
                    ]) ...[
                      Expanded(
                        child: _CountTile(
                          level: level,
                          count: count,
                          selected: levels.contains(level),
                          onTap: () => onLevel(level),
                        ),
                      ),
                      if (level != LogLevel.main) const SizedBox(width: 8),
                    ],
                  ],
                ),
                if (digest.previousFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: warn.bg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Row(
                          children: [
                            const SizedBox(width: 12),
                            Icon(
                              Icons.history_rounded,
                              size: 20,
                              color: warn.fg,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                S.logPreviousFailed,
                                style: theme.bodyMedium?.copyWith(
                                  color: p.text,
                                ),
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('log-previous-run'),
                              onPressed: onPrevious,
                              child: Text(S.logShow),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A count of errors, warnings or marks: the number large, the name under it; touched, it keeps only those lines.
class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.level,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final LogLevel level;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final look = _LevelLook.of(context, level);
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final label = switch (level) {
      LogLevel.error => S.logErrors,
      LogLevel.warn => S.logWarnings,
      _ => S.logMarks,
    };
    return Semantics(
      button: true,
      selected: selected,
      label: '$label $count',
      excludeSemantics: true,
      child: Material(
        color: selected ? p.primaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? p.primary : p.outline),
        ),
        child: InkWell(
          key: ValueKey('log-chip-${level.letter}'),
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        level == LogLevel.main ? Icons.flag_rounded : look.icon,
                        size: 18,
                        color: count > 0 ? look.fg : p.textTertiary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$count',
                        style: theme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: selected ? p.onPrimaryContainer : p.text,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.labelSmall?.copyWith(
                      color: selected ? p.onPrimaryContainer : p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Main / All / Detail, the groups, and a search that counts its matches.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.mode,
    required this.groups,
    required this.searching,
    required this.query,
    required this.matches,
    required this.match,
    required this.onMode,
    required this.onGroup,
    required this.onSearch,
    required this.onQuery,
    required this.onPreviousMatch,
    required this.onNextMatch,
  });

  final LogMode mode;
  final Set<LogGroup> groups;
  final bool searching;
  final TextEditingController query;
  final int matches;
  final int match;
  final ValueChanged<LogMode> onMode;
  final ValueChanged<LogGroup> onGroup;
  final VoidCallback onSearch;
  final VoidCallback onQuery;
  final VoidCallback onPreviousMatch;
  final VoidCallback onNextMatch;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return _Narrow(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<LogMode>(
                    key: const ValueKey('log-mode'),
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      selectedBackgroundColor: p.primaryContainer,
                      selectedForegroundColor: p.onPrimaryContainer,
                      foregroundColor: p.textSecondary,
                      side: BorderSide(color: p.outline),
                      minimumSize: const Size(0, 48),
                    ),
                    segments: [
                      ButtonSegment(
                        value: LogMode.main,
                        label: Text(S.logModeMain, maxLines: 1),
                      ),
                      ButtonSegment(
                        value: LogMode.all,
                        label: Text(S.logModeAll, maxLines: 1),
                      ),
                      ButtonSegment(
                        value: LogMode.detail,
                        label: Text(S.logModeDetail, maxLines: 1),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => onMode(s.first),
                  ),
                ),
                IconButton(
                  key: const ValueKey('log-search-toggle'),
                  tooltip: S.logSearchOpen,
                  onPressed: onSearch,
                  style: roundButtonStyle(context, size: 48),
                  icon: Icon(
                    searching ? Icons.search_off_rounded : Icons.search_rounded,
                  ),
                ),
              ],
            ),
            if (searching)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TvFieldGate(
                        builder: (fieldNode, readOnly) => TextField(
                          focusNode: fieldNode,
                          readOnly: readOnly,
                          key: const ValueKey('log-search'),
                          controller: query,
                          autofocus: true,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: S.logSearch,
                            isDense: true,
                            suffixText: query.text.trim().isEmpty
                                ? null
                                : '${match < 0 ? 0 : match + 1}/$matches',
                          ),
                          onChanged: (_) => onQuery(),
                          onSubmitted: (_) => onNextMatch(),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: S.logSearchPrevious,
                      onPressed: matches == 0 ? null : onPreviousMatch,
                      icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    ),
                    IconButton(
                      tooltip: S.logSearchNext,
                      onPressed: matches == 0 ? null : onNextMatch,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ],
                ),
              ),
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final group in LogGroup.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Center(
                            child: FilterChip(
                              key: ValueKey('log-group-${group.name}'),
                              avatar: Icon(_groupIcon(group), size: 18),
                              label: Text(_groupName(group)),
                              selected: groups.contains(group),
                              showCheckmark: false,
                              onSelected: (_) => onGroup(group),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.padded,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorJump extends StatelessWidget {
  const _ErrorJump({required this.onPrevious, required this.onNext});

  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.surfaceRaised,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: p.outline),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('log-error-previous'),
            tooltip: S.logPreviousError,
            onPressed: onPrevious,
            icon: Icon(Icons.keyboard_arrow_up_rounded, color: p.error),
          ),
          Icon(Icons.error_rounded, size: 18, color: p.error),
          IconButton(
            key: const ValueKey('log-error-next'),
            tooltip: S.logNextError,
            onPressed: onNext,
            icon: Icon(Icons.keyboard_arrow_down_rounded, color: p.error),
          ),
        ],
      ),
    );
  }
}

/// The top of a run of the app: when it started, in what version, how it ended.
class _RunHeader extends StatelessWidget {
  const _RunHeader({required this.row});

  final RunRow row;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final run = row.run;
    final (label, icon, color) = switch (run.end) {
      RunEnd.running => (S.logEndRunning, Icons.play_circle_rounded, p.success),
      RunEnd.normal => (
        S.logEndNormal,
        Icons.check_circle_rounded,
        p.textSecondary,
      ),
      RunEnd.crash => (S.logEndCrash, Icons.error_rounded, p.error),
      RunEnd.anr => (S.logEndAnr, Icons.error_rounded, p.error),
      RunEnd.killed => (
        S.logEndKilled,
        Icons.warning_rounded,
        _LevelLook.of(context, LogLevel.warn).fg,
      ),
    };
    return _Narrow(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.primaryContainer.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.rocket_launch_rounded,
                  size: 20,
                  color: p.onPrimaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        S.logRunStarted(
                          _clock(run.started, seconds: false),
                          run.version,
                        ),
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(color: p.onPrimaryContainer),
                      ),
                      Row(
                        children: [
                          Icon(icon, size: 16, color: color),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              label,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: p.text),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) => _Narrow(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 2),
      child: Text(
        _dayName(day),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: context.palette.textSecondary,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

/// One line: the time, the level (color and icon), the group, the words.
class _LineTile extends StatelessWidget {
  const _LineTile({
    super.key,
    required this.line,
    required this.flash,
    required this.current,
    required this.selected,
    required this.query,
    required this.onTap,
  });

  final LogLine line;
  final bool flash;
  final bool current;
  final bool selected;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final look = _LevelLook.of(context, line.level);
    final theme = Theme.of(context).textTheme;
    final mark = line.isMark;
    final bold = line.level == LogLevel.main || mark;
    final background = mark
        ? p.primaryContainer
        : selected || current || flash
        ? p.primary.withValues(alpha: .14)
        : look.bg;
    final text =
        (bold
                ? theme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)
                : theme.bodyMedium)
            ?.copyWith(
              color: line.level == LogLevel.detail ? p.textSecondary : p.text,
            );
    return Semantics(
      button: true,
      label:
          '${look.label} ${_clock(line.time)} ${_groupName(line.group)} ${line.message}',
      excludeSemantics: true,
      child: _Narrow(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Material(
            color: background ?? Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        // The clock grows with the text, or at a large size its last digit drops to a line of its own
                        width: MediaQuery.textScalerOf(context).scale(56),
                        child: Text(
                          _clock(line.time),
                          style: theme.labelSmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: p.textSecondary,
                            height: 1.5,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 22,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: mark
                              ? Icon(
                                  Icons.flag_rounded,
                                  size: 18,
                                  color: p.primary,
                                )
                              : look.icon == null
                              ? Center(
                                  child: Container(
                                    width: 6,
                                    height: 6,
                                    margin: const EdgeInsets.only(top: 6),
                                    decoration: BoxDecoration(
                                      color: look.fg,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                )
                              : Icon(
                                  look.icon,
                                  size: line.level == LogLevel.main ? 8 : 18,
                                  color: look.fg,
                                ),
                        ),
                      ),
                      Expanded(
                        child: RichText(
                          maxLines: line.level == LogLevel.error ? 4 : 2,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            style: text,
                            children: [
                              if (line.tag != 'mark')
                                TextSpan(
                                  text: '[${line.tag}] ',
                                  style: TextStyle(
                                    color: p.textSecondary,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ..._highlight(line.message, query, p),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

List<InlineSpan> _highlight(String text, String query, Palette p) {
  if (query.isEmpty) return [TextSpan(text: text)];
  final lower = text.toLowerCase();
  final needle = query.toLowerCase();
  final spans = <InlineSpan>[];
  var at = 0;
  while (true) {
    final hit = lower.indexOf(needle, at);
    if (hit < 0) break;
    if (hit > at) spans.add(TextSpan(text: text.substring(at, hit)));
    spans.add(
      TextSpan(
        text: text.substring(hit, hit + needle.length),
        style: TextStyle(
          backgroundColor: p.primary.withValues(alpha: .3),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    at = hit + needle.length;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return spans;
}

/// Quiet lines of one tag in a row, as one: "24 lines [http] · 14:05–14:07".
class _FoldTile extends StatelessWidget {
  const _FoldTile({required this.row, required this.onTap});

  final FoldRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return _Narrow(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: InkWell(
          key: ValueKey('log-fold-${row.key}'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: MediaQuery.textScalerOf(context).scale(56) + 2,
                  ),
                  Icon(
                    Icons.unfold_more_rounded,
                    size: 18,
                    color: p.textTertiary,
                  ),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(
                      _groupIcon(row.first.group),
                      size: 16,
                      color: p.textTertiary,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      S.logFolded(
                        row.lines.length,
                        row.first.tag,
                        _clock(row.first.time),
                        _clock(row.last.time),
                      ),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: p.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "… 120 lines hidden" between two lines the mode shows; touching it shows all, from there.
class _HiddenTile extends StatelessWidget {
  const _HiddenTile({required this.row, required this.onTap});

  final HiddenRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return _Narrow(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: InkWell(
          key: ValueKey('log-hidden-${row.at}'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(child: Divider(color: p.outlineSoft)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    '… ${S.logHidden(row.count)}',
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: p.textSecondary),
                  ),
                ),
                Expanded(child: Divider(color: p.outlineSoft)),
                const SizedBox(width: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for the note of a mark; answers with it ("" for none), or null when cancelled. The dialog keeps its own field:
/// one made by the page would be disposed while the dialog is still leaving.
class _MarkDialog extends StatefulWidget {
  const _MarkDialog();

  @override
  State<_MarkDialog> createState() => _MarkDialogState();
}

class _MarkDialogState extends State<_MarkDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(S.logMarkTitle),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(S.logMarkHelp, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('log-mark-note'),
          controller: _note,
          autofocus: true,
          maxLength: 120,
          decoration: InputDecoration(hintText: S.logMarkHint),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.of(context).pop(_note.text),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(S.cancel),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_note.text),
        child: Text(S.logMark),
      ),
    ],
  );
}

/// A line of the width a page of this log is kept to, in the middle of what the window gives it.
class _Narrow extends StatelessWidget {
  const _Narrow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: child,
    ),
  );
}

/// The place of the detail beside the list, before a line was picked.
class _PickLine extends StatelessWidget {
  const _PickLine();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined, size: 48, color: p.textTertiary),
            const SizedBox(height: 12),
            Text(
              S.logPickLine,
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: p.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({this.onAll});

  final VoidCallback? onAll;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fact_check_outlined, size: 64, color: p.textTertiary),
            const SizedBox(height: 12),
            Text(
              S.logEmpty,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (onAll != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                key: const ValueKey('log-show-all'),
                onPressed: onAll,
                child: Text(S.logShowAll),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The whole of a line, and the ones around it.
class _LineDetail extends StatelessWidget {
  const _LineDetail({
    super.key,
    required this.model,
    required this.line,
    required this.at,
    required this.onAround,
    this.scroll,
  });

  final LogModel model;
  final LogLine line;
  final int at;
  final VoidCallback onAround;
  final ScrollController? scroll;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final look = _LevelLook.of(context, line.level);
    final at = this.at;
    final split = line.message.indexOf(' @ ');
    final head = split < 0 ? line.message : line.message.substring(0, split);
    final frames = split < 0
        ? const <String>[]
        : line.message.substring(split + 3).split(' | ');
    final mono = theme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      color: p.text,
    );
    final around = model.around(at);
    final first = (at - 10).clamp(0, model.lines.length);
    return SelectionArea(
      child: ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          HomeShell.bottomInsetOf(context),
        ),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (look.icon != null) Icon(look.icon, color: look.fg, size: 20),
              Text(
                look.label,
                style: theme.titleSmall?.copyWith(color: look.fg),
              ),
              Icon(_groupIcon(line.group), size: 18, color: p.textSecondary),
              Text(
                _groupName(line.group),
                style: theme.bodyMedium?.copyWith(color: p.textSecondary),
              ),
              Text(
                '${line.time == null ? '' : '${_dayName(DateTime(line.time!.year, line.time!.month, line.time!.day))} '}${_clock(line.time)}',
                style: theme.bodyMedium?.copyWith(color: p.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '[${line.tag}] $head',
            style: theme.bodyLarge?.copyWith(color: p.text),
          ),
          if (frames.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final frame in frames) Text(frame, style: mono),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('log-copy-line'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: line.raw));
                  messenger.showSnackBar(SnackBar(content: Text(S.logCopied)));
                },
                icon: const Icon(Icons.content_copy_rounded),
                label: Text(S.logCopyLine),
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('log-around'),
                onPressed: onAround,
                icon: const Icon(Icons.unfold_more_rounded),
                label: Text(S.logShowAround),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(S.logAround, style: theme.titleSmall),
          const SizedBox(height: 4),
          for (var i = 0; i < around.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${_clock(around[i].time)}  ${around[i].level.letter}  [${around[i].tag}] ${around[i].message}',
                style: mono?.copyWith(
                  fontWeight: first + i == at
                      ? FontWeight.w700
                      : FontWeight.w400,
                  color: first + i == at ? p.text : p.textSecondary,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
