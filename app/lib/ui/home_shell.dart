import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../data/ios_update.dart';
import '../data/page_reload.dart';
import '../data/room_controller.dart';
import '../data/setup_link.dart';
import '../data/update_controller.dart';
import '../data/update_nudge.dart';
import '../data/version_check.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'chat_sheet.dart';
import 'focus_zones.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'now_playing_page.dart';
import 'player/video_controls.dart' show VideoFullScreen, openVideoFullScreen;
import 'player_sheet.dart';
import 'room_page.dart';
import 'rooms_sheet.dart';
import 'scope.dart';
import 'setup_dialog.dart';
import 'ios_update_sheet.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'sync_dialogs.dart';
import 'tv/tv.dart';
import 'tv/tv_rail.dart';
import 'update_sheet.dart';
import 'widgets/artwork.dart';
import 'widgets/cached_cover.dart';
import 'widgets/focus_nav.dart' show focusFirstOfNewRoute, keysAreInUse;
import 'widgets/glass.dart';
import 'widgets/mini_player.dart';
import 'widgets/play_problem_note.dart';
import 'widgets/motion.dart';
import 'widgets/page_width.dart';
import 'widgets/playlist_cover.dart';
import 'widgets/text_dialog.dart';
import 'widgets/video_frame.dart';
import 'widgets/player_bar.dart';

/// How the home screen is laid out for the size of its window, after Material's window size classes: by the width
/// of the window, not by which way the device is turned.
enum ShellLayout {
  /// A phone, upright or on its side: the tabs, Search and the mini player float at the bottom.
  bars,

  /// A tablet held upright, an unfolded phone, a small window: a rail of tabs on the left, the mini player floating
  /// at the bottom.
  rail,

  /// A tablet on its side, Samsung DeX, a computer: a sidebar on the left with the playlists in it, and a bar for the
  /// player along the bottom.
  sidebar,
}

/// The window the home screen is laid out for, whole, and how much of it the docked player takes. The pages beside the
/// docked player see a [MediaQuery] of the room they have; what is decided for the window (rail or sidebar, the size
/// of a card of a row) reads this, so that it does not change with the player.
class ShellWindow extends InheritedWidget {
  const ShellWindow({
    super.key,
    required this.size,
    required this.dock,
    required super.child,
  });

  final Size size;

  /// Width of the docked player, 0 with none.
  final double dock;

  static ShellWindow? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellWindow>();

  @override
  bool updateShouldNotify(ShellWindow old) =>
      size != old.size || dock != old.dock;
}

/// Tabs plus the floating mini player. Lists scroll behind both bars, which blur them.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// The window as the layout sees it: the whole of it, also from a page that has a narrower [MediaQuery] beside the
  /// docked player.
  static Size windowOf(BuildContext context) =>
      ShellWindow.maybeOf(context)?.size ?? MediaQuery.sizeOf(context);

  /// How wide the player is that stands beside the pages of a window wider than it is tall (0 for a window that is not),
  /// when a song is playing: a quarter more than a third of a tablet's width, and on a phone, which has little height,
  /// enough for the column of controls.
  static double dockWidthFor(Size size) {
    if (size.width <= size.height || size.width < 700) return 0;
    return size.height < 480
        ? (size.width * 0.40).clamp(300.0, 360.0)
        : (size.width * 0.32).clamp(360.0, 440.0);
  }

  /// The width of the docked player in this window, 0 with none (no song, or a window that is not wide).
  static double dockOf(BuildContext context) =>
      ShellWindow.maybeOf(context)?.dock ?? 0;

  /// Whether the player stands beside the pages, as a second screen.
  static bool isDocked(BuildContext context) => dockOf(context) > 0;

  /// Whether the screen is wider than it is tall, where the bars are lower to leave room for the page.
  static bool isWide(BuildContext context) {
    final size = windowOf(context);
    return size.width > size.height;
  }

  /// The least the pages keep when a sidebar and the docked player share a window: narrower than this the tabs go to a
  /// rail.
  static const _leastPage = 560.0;

  /// The room beside the pages that a sidebar takes (its width and the gaps at either side).
  static const _sidebarSpan = 12 + 256 + 12;

  static ShellLayout layoutOf(BuildContext context) =>
      layoutFor(windowOf(context), dockOf(context), tv: TvScope.of(context));

  /// Whether the app is drawn for a TV: the rail is the TV's, the player is the whole screen and not a card, and what is
  /// reached is reached with a remote.
  static bool isTv(BuildContext context) => TvScope.of(context);

  static ShellLayout layoutFor(Size size, double dock, {bool tv = false}) {
    // A TV has a rail of its own that opens, and no card beside the pages
    if (tv) return ShellLayout.rail;
    // A phone on its side is wide but short: two bars stacked along its foot would take a quarter of what height it
    // has, so the tabs go up the side, as a rail of icons, and the mini player floats alone
    if (size.height < 480) {
      return size.width > size.height && size.width >= 560
          ? ShellLayout.rail
          : ShellLayout.bars;
    }
    if (size.width < 600) return ShellLayout.bars;
    if (size.width < 840) return ShellLayout.rail;
    // Beside the docked player the pages need room of their own: a sidebar that leaves them less is a rail
    if (dock > 0 && size.width - dock - 24 - _sidebarSpan < _leastPage) {
      return ShellLayout.rail;
    }
    return ShellLayout.sidebar;
  }

  /// The rail of a phone on its side: icons only, and lower bars all round.
  static bool compactOf(BuildContext context) =>
      layoutOf(context) == ShellLayout.rail && windowOf(context).height < 480;

  /// Whether the pages end below the status bar, as on a phone, instead of scrolling up under a strip of glass there as
  /// they do on a tablet: a phone on its side has no height to give that strip.
  static bool endsBelowStatusOf(BuildContext context) =>
      layoutOf(context) == ShellLayout.bars || compactOf(context);

  /// Bottom padding lists need so their last row can scroll clear of the bars. A phone's bars are folded by the time a
  /// page has been scrolled to its end, so it is their folded height (the mini player's, the row above the system's bar) and a
  /// little room: made for the open bars, the end of every page was a long empty band under the folded ones. Scrolled
  /// back up, the open mini player covers the last rows, as glass that shows them.
  static double bottomInsetOf(BuildContext context) =>
      // With the player beside the pages there is no mini player or bar over their foot
      isDocked(context)
      ? math.max(_systemBottomOf(context), 0) + 24
      : switch (layoutOf(context)) {
          ShellLayout.bars =>
            math.max(_systemBottomOf(context), _barsBottom) +
                MiniPlayer.heightOf(context) +
                16,
          ShellLayout.rail =>
            compactOf(context)
                ? math.max(_systemBottomOf(context), 0) +
                      MiniPlayer.heightOf(context) +
                      _Side.compactBottom +
                      16
                : 120,
          ShellLayout.sidebar => 112,
        };

  /// Like [bottomInsetOf], but with the mini player open above the tabs: the room a page needs under its last line when
  /// that line must be seen with the bars as they are, because the page is too short to scroll and so never folds them.
  static double openBottomInsetOf(BuildContext context) => switch (layoutOf(
    context,
  )) {
    ShellLayout.bars => bottomInsetOf(context) + MiniPlayer.heightOf(context),
    _ => bottomInsetOf(context),
  };

  /// The system's own bar under the pages (the home indicator, the navigation bar). Read from the view: the bars are
  /// drawn by the scaffold around the pages, which takes that room off the media a page sees, so a page would find none.
  static double _systemBottomOf(BuildContext context) {
    final view = View.of(context);
    return view.viewPadding.bottom / view.devicePixelRatio;
  }

  /// The least room under a phone's bars, where the system has no bar of its own.
  static const _barsBottom = 10.0;

  /// The name of the fourth tab: its page is the room's while in one.
  static String listenLabelOf(BuildContext context) =>
      AppScope.roomOf(context).snapshot.inRoom ? S.tabRoom : S.tabListen;

  /// Side of a cover in a row of cards: larger where the window is.
  static double cardSizeOf(BuildContext context) => switch (layoutOf(context)) {
    ShellLayout.bars => 148,
    ShellLayout.rail => compactOf(context) ? 132 : 164,
    ShellLayout.sidebar => 172,
  };

  /// Height of the capsule of tabs and of the Search button: always a little more than the mini player's, which they
  /// come down to when the bars are folded.
  static double tabHeightOf(BuildContext context) => isWide(context) ? 42 : 54;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  int _tab = 0;

  /// The last tab of the capsule that was open, where its lens waits while Search is.
  int _browsing = 0;
  late final _sheet = PlayerSheetController(
    this,
    isStill: () => mounted && Motion.still(context),
  );

  /// 0 with the bars open, 1 with them folded away while a page is scrolled down, as Apple Music does: the tabs shrink
  /// to the one that is open and the mini player moves down between it and Search.
  late final _folded = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
  );
  bool _isFolded = false;

  /// The two parts of folding: the capsule of tabs shrinks first and the mini player comes down after, so that the
  /// two hardly cross; unfolding plays it backwards, the mini player going up first.
  late final _shrink = CurvedAnimation(
    parent: _folded,
    curve: const Interval(0, 0.6, curve: Curves.easeInOutCubic),
  );
  late final _drop = CurvedAnimation(
    parent: _folded,
    curve: const Interval(0.4, 1, curve: Curves.easeInOutCubic),
  );

  /// The page that comes with a tab fades in, so that a tab is not a cut; 1 while nothing changes.
  late final _pageFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: Motion.medium),
    value: 1,
  );
  late final _pageFadeIn = CurvedAnimation(
    parent: _pageFade,
    curve: Curves.easeOut,
  );

  /// Whether the scroll under way is the person's, and how far it has gone one way since it last turned.
  bool _touched = false;
  double _travel = 0;

  /// What the glass of every bar reads from, once for them all.
  final _backdrop = BackdropKey();

  /// Every tab has a navigator of its own, so that a page opened from it (a playlist, an artist) opens inside the
  /// tab, between the top of the screen and the bars, instead of on top of everything.
  final _navigators = List.generate(4, (_) => GlobalKey<NavigatorState>());

  /// Pings when a page is opened or closed in a tab, which the Back button has to know about.
  final _stack = ValueNotifier<int>(0);

  /// One for each navigator: an observer can watch only one.
  late final _watchers = List.generate(
    4,
    (_) => _StackWatcher(() {
      // Opening a page happens in the middle of building; the news waits for the frame to be done
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _stack.value++;
        // A page that opens or closes shows the bars, as a tab does
        _fold(false);
      });
    }),
  );

  /// Whether Search holds words or results, and the way to clear them, for Back.
  final _searchBack = SearchBack();

  /// The search field, for the sidebar and the `/` key to put the cursor in.
  final _searchFocus = FocusNode(debugLabel: 'search');

  /// What the sidebar of a wide screen asks the library to show.
  final _libraryRequests = LibraryRequests();

  /// Where the arrow keys of a remote go from the tabs to the page to the player.
  final _zones = FocusZones();

  NavigatorState? get _current => _navigators[_tab].currentState;
  StreamSubscription<String>? _messages;
  StreamSubscription<PlayProblem>? _playProblems;
  StreamSubscription<String>? _libraryMessages;
  StreamSubscription<Notice>? _notices;
  ValueNotifier<int>? _dropped;
  RoomController? _watched;
  UpdateController? _update;
  Timer? _nudgeTimer;
  Timer? _versionTimer;
  bool _newVersionTold = false;
  String? _precachedCover;

  void _tellDropped() {
    final left = _dropped?.value ?? 0;
    if (left == 0 || !mounted) return;
    _dropped!.value = 0;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.connectDropped(left))));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_messages != null) return;
    final room = _watched = AppScope.roomOf(context);
    _hasSong = room.snapshot.current != null;
    _messages = room.messages.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    });
    _playProblems = room.playProblems.listen((problem) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: PlayProblemNote(problem),
            duration: PlayProblemNote.duration,
          ),
        );
    });
    // Songs only the other device had stay behind when the playing moves here: the person is told once
    _dropped = AppScope.of(context).connect?.dropped;
    _dropped?.addListener(_tellDropped);
    _libraryMessages = AppScope.of(context).library.messages.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    });
    _notices = room.notices.listen((notice) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(notice.text),
            duration: const Duration(seconds: 6),
            action: notice.canKeepPlaying
                ? SnackBarAction(
                    label: S.keepPlaying,
                    onPressed: room.keepPlaying,
                  )
                : notice.opensChat
                ? SnackBarAction(
                    label: S.chatOpen,
                    onPressed: () => showChatSheet(context),
                  )
                : null,
          ),
        );
    });
    HardwareKeyboard.instance.addHandler(_onKey);
    VideoFullScreen.open.addListener(_fullScreenChanged);
    TabNavigation._active = () => _current;
    TabNavigation._top = () => _watchers[_tab].top;
    TabNavigation._closePlayer = () {
      if (_sheet.isOpen && !_sheet.docked.value) _sheet.close();
    };
    TabNavigation._search = _search;
    room.invite.addListener(_onInvite);
    room.chatRequests.addListener(_onChatRequest);
    room.setup.addListener(_onSetup);
    room.syncLink.addListener(_onSyncLink);
    room.addListener(_precacheCover);
    room.addListener(_watchRoom);
    room.addListener(_askForKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheCover());
    WidgetsBinding.instance.addPostFrameCallback((_) => _askForKey());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onInvite());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSetup());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSyncLink());
    final update = _update = AppScope.of(context).update;
    update.addListener(_scheduleNudge);
    _sheet.addListener(_scheduleNudge);
    WidgetsBinding.instance.addObserver(this);
    _scheduleNudge();
    if (kIsWeb) {
      _versionTimer = Timer.periodic(
        const Duration(minutes: 30),
        (_) => _checkVersion(),
      );
      Timer(const Duration(seconds: 30), _checkVersion);
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _versionTimer = Timer.periodic(
        const Duration(hours: 12),
        (_) => _checkRelease(),
      );
      Timer(const Duration(seconds: 20), _checkRelease);
    }
  }

  /// An iPhone has no store: the latest release of the public repository says whether a newer version is out, and the sheet
  /// takes the person to it. Asked once for each version and again only after a few days, like the sheet of Android.
  Future<void> _checkRelease() async {
    if (!mounted) return;
    final installed = (await PackageInfo.fromPlatform()).version;
    final offer = await IosUpdateCheck(
      installed: installed,
      fetch: () async {
        final reply = await http.get(
          Uri.parse(
            'https://api.github.com/repos/tranviethungpv/Sapoche/releases/latest',
          ),
          headers: const {'Accept': 'application/vnd.github+json'},
        );
        return reply.statusCode == 200 ? reply.body : null;
      },
    ).newer();
    if (offer == null || !mounted) return;
    final settings = AppScope.of(context).settings;
    final now = DateTime.now();
    final last = settings.updateSheetShown(offer.version);
    if ((last != null && now.difference(last) < UpdateNudge.every) ||
        !_quietMoment()) {
      return;
    }
    settings.updateSheetWasShown(offer.version, now);
    showIosUpdateSheet(context, offer);
  }

  /// Nothing is in the middle of being done: not over the player, a page of its own, a dialog or a keyboard.
  bool _quietMoment() {
    final focused = FocusManager.instance.primaryFocus?.context;
    final typing =
        focused?.widget is EditableText ||
        focused?.findAncestorWidgetOfExactType<EditableText>() != null;
    return !(_sheet.isOpen ||
        typing ||
        ModalRoute.of(context)?.isCurrent == false);
  }

  /// A tab left open keeps the version it loaded with: from time to time the server's `version.json` is asked, and a newer
  /// one is told once, with a way to load the page again.
  Future<void> _checkVersion() async {
    if (!mounted || _newVersionTold) return;
    final info = await PackageInfo.fromPlatform();
    final newer = await VersionCheck(
      loaded: '${info.version}+${info.buildNumber}',
      fetch: () async {
        final reply = await http.get(
          Uri.base.resolve(
            'version.json?t=${DateTime.now().millisecondsSinceEpoch}',
          ),
        );
        return reply.statusCode == 200 ? reply.body : null;
      },
    ).newer();
    if (newer == null || !mounted) return;
    _newVersionTold = true;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(S.webNewVersion),
          duration: const Duration(days: 1),
          action: SnackBarAction(label: S.webReload, onPressed: reloadPage),
        ),
      );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleNudge();
  }

  /// The sheet about a new version waits for a quiet moment: a few seconds after the app is opened or comes back, after
  /// the player is closed, or after the version turned up.
  void _scheduleNudge() {
    if (_nudgeTimer?.isActive ?? false) return;
    _nudgeTimer = Timer(const Duration(seconds: 6), _nudgeUpdate);
  }

  void _nudgeUpdate() {
    if (!mounted) return;
    final model = AppScope.of(context);
    final info = model.update.info;
    final version = info.version;
    if (version == null) return;
    final now = DateTime.now();
    if (!UpdateNudge.due(
      info,
      lastShown: model.settings.updateSheetShown(version),
      now: now,
    )) {
      return;
    }
    if (!_quietMoment()) return;
    model.settings.updateSheetWasShown(version, now);
    showUpdateSheet(context, model.update);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nudgeTimer?.cancel();
    _versionTimer?.cancel();
    _update?.removeListener(_scheduleNudge);
    _sheet.removeListener(_scheduleNudge);
    HardwareKeyboard.instance.removeHandler(_onKey);
    VideoFullScreen.open.removeListener(_fullScreenChanged);
    if (_statusIs == true) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    TabNavigation._active = null;
    TabNavigation._top = null;
    TabNavigation._closePlayer = null;
    TabNavigation._search = null;
    _stack.dispose();
    _watched?.invite.removeListener(_onInvite);
    _watched?.chatRequests.removeListener(_onChatRequest);
    _watched?.setup.removeListener(_onSetup);
    _watched?.syncLink.removeListener(_onSyncLink);
    _watched?.removeListener(_precacheCover);
    _watched?.removeListener(_watchRoom);
    _watched?.removeListener(_askForKey);
    _messages?.cancel();
    _playProblems?.cancel();
    _libraryMessages?.cancel();
    _notices?.cancel();
    _dropped?.removeListener(_tellDropped);
    _sheet.dispose();
    _zones.dispose();
    _searchFocus.dispose();
    _searchBack.dispose();
    _libraryRequests.dispose();
    _pageFadeIn.dispose();
    _pageFade.dispose();
    _shrink.dispose();
    _drop.dispose();
    _folded.dispose();
    super.dispose();
  }

  /// Fetches the current song's cover in the size the full player shows it, ahead of time, so
  /// opening the player shows the picture at once instead of a placeholder.
  void _precacheCover() {
    final url = _watched?.snapshot.current?.thumb;
    if (url == null || url == _precachedCover || !mounted) return;
    _precachedCover = url;
    precacheImage(
      CachedCover(sharpThumbnail(url)),
      context,
      // No enlarged picture for this one: the player will fall back to the original
      onError: (_, _) =>
          precacheImage(CachedCover(url), context, onError: (_, _) {}),
    );
  }

  bool _inRoom = false;
  bool _hasSong = false;

  /// Entering or leaving a room renames the fourth tab, in the rail and the sidebar as well as the capsule. A first song
  /// or the last one gone brings the docked player or takes it away.
  void _watchRoom() {
    final now = _watched?.snapshot.inRoom ?? false;
    final song = _watched?.snapshot.current != null;
    if ((now == _inRoom && song == _hasSong) || !mounted) return;
    setState(() {
      _inRoom = now;
      _hasSong = song;
    });
  }

  var _askedForKey = false;

  /// A browser that was never given the group key can do nothing: search, Home and rooms all need it. The person is
  /// asked for it once, the first time; after that a band at the top of the page asks again. The page loads again with
  /// the key. (Phones have it built in or are set up by a link.)
  Future<void> _askForKey() async {
    final room = _watched;
    if (!kIsWeb ||
        _askedForKey ||
        room == null ||
        room.profile.hasKey ||
        !mounted) {
      return;
    }
    _askedForKey = true;
    await _enterKey(room);
  }

  Future<void> _enterKey(RoomController room) async {
    final typed = await showTextDialog(
      context,
      title: S.webKeyTitle,
      hint: S.webKeyHint,
      maxLength: 400,
      capitalization: TextCapitalization.none,
    );
    if (typed == null || typed.trim().isEmpty) return;
    // The link an Android phone copies from its settings works too, so that nobody has to pick the key out of it
    final key = SetupLink.parse(typed)?.key ?? typed.trim();
    if (key.isEmpty) return;
    await room.configure(key: key);
    reloadPage();
  }

  /// A setup link arrived, from the camera of this phone or from a message: the server and key of another phone.
  /// The person touched a notice of the chat: the chat opens, over whatever is shown.
  void _onChatRequest() {
    if (mounted) showChatSheet(context);
  }

  /// A link with the key of a synced library was opened: offer to join it.
  Future<void> _onSyncLink() async {
    final room = AppScope.roomOf(context);
    final key = room.syncLink.value;
    final sync = AppScope.of(context).sync;
    if (key == null || sync == null || !mounted) return;
    room.syncLink.value = null;
    if (!sync.enabled) await joinSync(context, sync, key: key);
  }

  Future<void> _onSetup() async {
    final room = AppScope.roomOf(context);
    final link = room.setup.value;
    if (link == null || !mounted) return;
    room.setup.value = null;
    await askToUseSetup(context, room, link);
  }

  /// An invitation link arrived. Outside a room it opens the sheet with the code filled in; in a room
  /// it switches only if it is another room and the user agrees.
  Future<void> _onInvite() async {
    final room = AppScope.roomOf(context);
    final code = room.invite.value;
    if (code == null || !mounted) return;
    room.invite.value = null;
    if (code == room.snapshot.room) return;
    if (!room.snapshot.inRoom) return showRoomSheet(context, invitedCode: code);
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: Motion.dialog(context),
      builder: (context) => AlertDialog(
        title: Text(S.switchRoom),
        content: Text(S.inviteSwitch(code)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.join),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      room.join(code, room.snapshot.me?.name ?? room.profile.name ?? '');
    }
  }

  /// With keys in use, a tab that is chosen has the focus put into its page, where the person goes next.
  void _focusPage() {
    if (!keysAreInUse) return;
    _zones.forgetPage();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _zones.enter(FocusZone.page);
    });
  }

  void _select(int tab, {bool focusPage = true}) {
    _fold(false);
    if (tab == _tab) {
      // The tab that is open is touched again: back to its first page
      _current?.popUntil((route) => route.isFirst);
      if (focusPage) _focusPage();
      return;
    }
    if (focusPage) _focusPage();
    HapticFeedback.selectionClick();
    if (!Motion.reduced(context)) _pageFade.forward(from: 0.35);
    setState(() {
      _tab = tab;
      if (tab != 1) _browsing = tab;
    });
  }

  /// Opens Search with the cursor in its field.
  void _search() {
    // The cursor goes into the field of Search, not to the first control of the page
    _select(1, focusPage: false);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  /// Opens a list of the library from the sidebar: one of [LibraryRequests]'s.
  void _openLibrary(int list) {
    _select(2);
    _current?.popUntil((route) => route.isFirst);
    _libraryRequests.value = list;
  }

  /// Keys of a keyboard, for DeX and a computer: Space plays or pauses, Shift with an arrow goes back or on ten
  /// seconds, Ctrl with an arrow skips, `/` or Ctrl+F searches, Escape closes the player. Plain arrows are left to move
  /// between the buttons, as a TV remote does.
  /// Page Up and Page Down, and a remote's channel keys: the page that has the focus scrolls by most of a screen. False
  /// where nothing scrolls, so that the key is left to whoever else wants it.
  bool _scrollPage(int way) {
    final node = FocusManager.instance.primaryFocus;
    // The nearest list around the control that has anything to scroll (a small one round a header has not)
    ScrollPosition? scrollable(BuildContext? from) {
      var at = from;
      while (at != null && at.mounted) {
        final state = Scrollable.maybeOf(at, axis: Axis.vertical);
        if (state == null) return null;
        if (state.position.maxScrollExtent > 0) return state.position;
        // Past this one: the list around it
        at = state.context;
      }
      return null;
    }

    var position = scrollable(node?.context);
    // A control outside the list (the Back button, a header above it) still pages the page it is on
    if (position == null && node != null) {
      for (final other
          in node.nearestScope?.descendants ?? const <FocusNode>[]) {
        position = scrollable(other.context);
        if (position != null) break;
      }
    }
    if (position == null) return false;
    final to = (position.pixels + way * position.viewportDimension * 0.85)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    final time = Motion.of(context, 200);
    // With the motion turned off (a TV starts so) the page goes at once: an animation cannot last no time at all
    if (time == Duration.zero) {
      position.jumpTo(to);
    } else {
      unawaited(position.animateTo(to, duration: time, curve: Curves.easeOut));
    }
    return true;
  }

  static final _arrows = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent || !mounted) return false;
    // What is typed into a field is the field's, and a dialog or a sheet over the screen has its own keys
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        focused.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    if (Navigator.of(context, rootNavigator: true).canPop()) return false;
    final room = AppScope.roomOf(context);
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final playing = room.snapshot.current != null;
    final once = event is KeyDownEvent;
    final key = event.logicalKey;
    // The first press of an arrow, with nothing yet that has the focus: it lands on the page (a TV remote has no touch
    // to start from). Not under the full player, which keeps the focus in itself
    if (once &&
        _arrows.contains(key) &&
        !(_sheet.isOpen && !_sheet.docked.value) &&
        _zones.start()) {
      return true;
    }
    switch (key) {
      // The keys of a remote or a game pad, which a phone's headset sends to the player's session by itself: here they
      // are the app's own while it is in front, and nobody else's
      case LogicalKeyboardKey.mediaPlayPause when once && playing:
        room.togglePlay();
      case LogicalKeyboardKey.mediaPlay when once && playing:
        if (!room.isPlaying) room.togglePlay();
      case LogicalKeyboardKey.mediaPause when once && playing:
        if (room.isPlaying) room.togglePlay();
      case LogicalKeyboardKey.mediaTrackNext when once && playing:
      case LogicalKeyboardKey.gameButtonRight1 when once && playing:
        room.next();
      case LogicalKeyboardKey.mediaTrackPrevious when once && playing:
      case LogicalKeyboardKey.gameButtonLeft1 when once && playing:
        room.prev();
      case LogicalKeyboardKey.mediaFastForward when playing:
        room.seek(
          (room.positionMs() + 10000).clamp(0, room.durationMs()).toInt(),
        );
      case LogicalKeyboardKey.mediaRewind when playing:
        room.seek(
          (room.positionMs() - 10000).clamp(0, room.durationMs()).toInt(),
        );
      case LogicalKeyboardKey.browserSearch when once:
      case LogicalKeyboardKey.find when once:
        _search();
      case LogicalKeyboardKey.pageDown when once:
      case LogicalKeyboardKey.channelDown when once:
        return _scrollPage(1);
      case LogicalKeyboardKey.pageUp when once:
      case LogicalKeyboardKey.channelUp when once:
        return _scrollPage(-1);
      case LogicalKeyboardKey.gameButtonB when once:
        unawaited(Navigator.of(context).maybePop());
      case LogicalKeyboardKey.space when once && playing:
        room.togglePlay();
      case LogicalKeyboardKey.arrowRight when ctrl && once && playing:
        room.next();
      case LogicalKeyboardKey.arrowLeft when ctrl && once && playing:
        room.prev();
      case LogicalKeyboardKey.arrowRight when keys.isShiftPressed && playing:
        room.seek(
          (room.positionMs() + 10000).clamp(0, room.durationMs()).toInt(),
        );
      case LogicalKeyboardKey.arrowLeft when keys.isShiftPressed && playing:
        room.seek(
          (room.positionMs() - 10000).clamp(0, room.durationMs()).toInt(),
        );
      case LogicalKeyboardKey.slash when once:
        _search();
      case LogicalKeyboardKey.keyF when ctrl && once:
        _search();
      case LogicalKeyboardKey.escape
          when once && _sheet.isOpen && !_sheet.docked.value:
        _sheet.close();
      default:
        return false;
    }
    return true;
  }

  void _fold(bool fold) {
    if (fold == _isFolded) return;
    _isFolded = fold;
    if (Motion.still(context)) {
      _folded.value = fold ? 1 : 0;
    } else {
      _folded.animateTo(fold ? 1 : 0);
    }
  }

  /// Scrolling a page down folds the bars away, and they stay folded, however the page is scrolled back, until it is
  /// back at its top, as in Apple Music.
  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    // Only the phone's bars fold: beside a rail or a sidebar there is room for the player
    if (HomeShell.layoutOf(context) != ShellLayout.bars) return false;
    switch (notification) {
      case ScrollStartNotification(:final dragDetails):
        // Only a finger's scroll counts, with the glide after it, not a page moving by itself
        _touched = dragDetails != null;
        _travel = 0;
      case ScrollEndNotification():
        _touched = false;
      case ScrollUpdateNotification(:final scrollDelta?, :final metrics)
          when _touched && !metrics.outOfRange:
        // Past either end the page only bounces back, which says nothing of where the person is going
        if (scrollDelta.sign != _travel.sign) _travel = 0;
        _travel += scrollDelta;
        if (_travel > 24) _fold(true);
        if (metrics.extentBefore <= 0) _fold(false);
      // A page with too little to scroll cannot fold the bars by scrolling, yet its last rows may lie under the open
      // ones: pulling it on past its end folds them, and pulling it back the other way brings them back
      case ScrollUpdateNotification(:final scrollDelta?, :final metrics)
          when _touched && metrics.outOfRange:
        if (metrics.extentAfter == 0 && scrollDelta > 0) _fold(true);
        if (metrics.extentBefore == 0 && scrollDelta < 0) _fold(false);
      case OverscrollNotification(:final overscroll) when _touched:
        _fold(overscroll > 0);
      default:
    }
    return false;
  }

  /// Whether the window was on its side at the last look, to see the phone being turned.
  bool? _wasLandscape;

  /// What the sheet is told once the frame is built: whether the player stands beside the pages.
  bool _dockWanted = false;

  /// Whether the status bar of the system is hidden as things are: a phone on its side has no height to spare. A swipe
  /// from the top edge brings it back for a moment. An iPhone does it by itself, and a browser has none.
  bool _statusWanted = false;
  bool? _statusIs;

  void _applyStatus() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    // The full screen of a picture has its own say over the bars, and puts them as they were when it is left
    if (VideoFullScreen.open.value || _statusIs == _statusWanted) return;
    _statusIs = _statusWanted;
    unawaited(
      _statusWanted
          ? SystemChrome.setEnabledSystemUIMode(
              SystemUiMode.manual,
              overlays: [SystemUiOverlay.bottom],
            )
          : SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
    );
  }

  void _fullScreenChanged() {
    // Left again: the bars come back as the picture's own code set them, which is not what this screen wants
    if (!VideoFullScreen.open.value) {
      _statusIs = null;
      _applyStatus();
    }
  }

  /// A phone turned on its side while the picture plays and the player is open shows the picture across the whole
  /// screen, as video apps do. A tablet has room for the picture in the player beside the pages.
  void _watchTurn(Size window, RoomController room) {
    final landscape = window.width > window.height;
    final turned = _wasLandscape == false && landscape;
    _wasLandscape = landscape;
    if (turned &&
        !kIsWeb &&
        room.snapshot.video &&
        window.shortestSide < 600 &&
        _sheet.position.value == 1 &&
        !VideoFullScreen.open.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openVideoFullScreen(context, room, turned: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    final window = MediaQuery.sizeOf(context);
    // The player stands beside the pages in a window that is wider than it is tall, while a song is on
    final tv = TvScope.of(context);
    final dock = _hasSong && !tv ? HomeShell.dockWidthFor(window) : 0.0;
    final docked = dock > 0;
    final layout = HomeShell.layoutFor(window, dock, tv: tv);
    _watchTurn(window, controller);
    _statusWanted = window.height < 480 && window.width > window.height;
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyStatus());
    _dockWanted = docked;
    if (_sheet.docked.value != docked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sheet.setDocked(_dockWanted);
      });
    }
    // Which part lies next to which, for the arrows of a remote
    _zones.neighbours = layout == ShellLayout.bars
        ? const {
            FocusZone.page: {TraversalDirection.down: FocusZone.nav},
            FocusZone.nav: {TraversalDirection.up: FocusZone.page},
          }
        : {
            FocusZone.nav: const {TraversalDirection.right: FocusZone.page},
            FocusZone.page: {
              TraversalDirection.left: FocusZone.nav,
              if (docked)
                TraversalDirection.right: FocusZone.player
              else
                TraversalDirection.down: FocusZone.player,
            },
            FocusZone.player: {
              if (docked)
                TraversalDirection.left: FocusZone.page
              else ...{
                TraversalDirection.up: FocusZone.page,
                TraversalDirection.left: FocusZone.nav,
              },
            },
          };
    final pages = _zones.zone(
      FocusZone.page,
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: FadeTransition(
          opacity: _pageFadeIn,
          child: IndexedStack(
            index: _tab,
            // A tab that is not showing keeps its state but not its animations
            children: [
              for (final (i, page) in [
                const HomePage(),
                SearchPage(focusNode: _searchFocus, back: _searchBack),
                LibraryPage(requests: _libraryRequests),
                RoomPage(onAddSongs: _search),
              ].indexed)
                TickerMode(
                  enabled: i == _tab,
                  child: Navigator(
                    key: _navigators[i],
                    observers: [_watchers[i]],
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => PageWidth(child: page),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final home = Scaffold(
      extendBody: true,
      // Beside a notch, when the phone is on its side. With a rail or a sidebar the pages are not inside it: they take the
      // whole window, so that their backdrops are under the notch and the system's bar as well, and keep clear of them
      // by [SideInset]
      body: SafeArea(
        top: false,
        bottom: false,
        left: layout == ShellLayout.bars,
        right: layout == ShellLayout.bars,
        child: Column(
          children: [
            // Until the browser has the group key, the way to give it stays in sight
            if (kIsWeb)
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => controller.profile.hasKey
                    ? const SizedBox.shrink()
                    : _KeyBand(onEnter: () => _enterKey(controller)),
              ),
            Expanded(
              child: layout == ShellLayout.bars
                  ? pages
                  // The sidebar lights the page on top in the tab, which changes when a page is opened or closed in it
                  : ListenableBuilder(
                      listenable: _stack,
                      builder: (context, _) => _Side(
                        layout: layout,
                        dock: dock,
                        controller: controller,
                        index: _tab,
                        where: _watchers[_tab].top,
                        onSelect: _select,
                        onSearch: _search,
                        onLibrary: _openLibrary,
                        zones: _zones,
                        tv: tv,
                        child: pages,
                      ),
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: layout == ShellLayout.bars
          ? _zones.zone(
              FocusZone.nav,
              _Bars(
                controller: controller,
                shrink: _shrink,
                drop: _drop,
                hideMini: _sheet.miniHidden,
                index: _tab,
                browsing: _browsing,
                onSelect: _select,
                onUnfold: () => _fold(false),
              ),
            )
          : null,
    );
    // A toast floats over the pages, clear of the player beside them, with no mini player to lift it over
    final theme = Theme.of(context);
    final shown = docked
        ? Theme(
            data: theme.copyWith(
              snackBarTheme: theme.snackBarTheme.copyWith(
                width: null,
                insetPadding: EdgeInsets.fromLTRB(
                  15,
                  5,
                  15 + dock + 32,
                  10 + MediaQuery.viewPaddingOf(context).bottom,
                ),
              ),
            ),
            child: home,
          )
        : home;
    return ShellWindow(
      size: window,
      dock: dock,
      child: ZoneArrows(
        zones: _zones,
        child: PlayerSheetScope(
          controller: _sheet,
          // Back steps out one layer at a time: a panel of the player, the player, a page of the tab, the words and results
          // of Search, then any other tab back to Home; only from Home does it leave the screen
          child: ListenableBuilder(
            listenable: Listenable.merge([_sheet, _stack, _searchBack, _zones]),
            builder: (context, stack) {
              // With keys, the bottom of a page's pages is the tabs: Back goes to them before it goes anywhere else
              final inPage = keysAreInUse && _zones.current == FocusZone.page;
              return PopScope(
                // Beside the pages the player is not a layer to go back out of: Back is the pages'
                canPop:
                    !(_sheet.isOpen && !docked) &&
                    !(_current?.canPop() ?? false) &&
                    _tab == 0 &&
                    !inPage,
                onPopInvokedWithResult: (didPop, _) {
                  if (didPop) return;
                  if (_sheet.isOpen && !docked) {
                    _sheet.back();
                  } else if (_current?.canPop() ?? false) {
                    _current?.maybePop();
                  } else if (_tab == 1 && _searchBack.value) {
                    _searchBack.clear?.call();
                  } else if (inPage && _zones.enter(FocusZone.nav)) {
                    // On the tabs now
                  } else {
                    _select(0);
                  }
                },
                child: stack!,
              );
            },
            // Around the sheet as well, for the picture of the mini player it draws while it opens
            child: BackdropGroup(
              backdropKey: _backdrop,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Nothing to draw behind a fully open player
                  AnimatedBuilder(
                    animation: _sheet.position,
                    child: shown,
                    // Hidden behind the full player: not drawn, and its small animations stand still too. Not when the
                    // player stands beside the pages: they show
                    builder: (context, home) {
                      final covered = _sheet.position.value == 1 && !docked;
                      // A page that is hidden must not keep the arrow keys either
                      return TickerMode(
                        enabled: !covered,
                        child: ExcludeFocus(
                          excluding: covered,
                          child: Offstage(offstage: covered, child: home),
                        ),
                      );
                    },
                  ),
                  if (!docked)
                    PlayerSheetLayer(controller: _sheet, folded: _drop),
                  if (kIsWeb) VideoFrameHost(sheet: _sheet),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The pages of a large window beside a rail or a sidebar, with the player floating over their bottom, or, in a window
/// that is wider than it is tall, standing beside them on the right.
class _Side extends StatelessWidget {
  const _Side({
    required this.layout,
    required this.dock,
    required this.controller,
    required this.index,
    required this.where,
    required this.onSelect,
    required this.onSearch,
    required this.onLibrary,
    required this.zones,
    required this.tv,
    required this.child,
  });

  final ShellLayout layout;

  /// Width of the player that stands beside the pages, 0 with none.
  final double dock;
  final RoomController controller;
  final int index;

  /// The name of the page on top in the tab that is showing: what the sidebar lights besides the tab.
  final String? where;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearch;
  final ValueChanged<int> onLibrary;

  /// The parts the arrow keys of a remote go between.
  final FocusZones zones;

  /// Drawn for a TV: the rail is the one that opens.
  final bool tv;
  final Widget child;

  static const _gap = 12.0;

  /// Space under the mini player of a phone on its side, which has little height to spare.
  static const compactBottom = 12.0;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final rail = layout == ShellLayout.rail;
    final compact = HomeShell.compactOf(context);
    final railWidth = tv ? TvRail.width : _Rail.widthOf(compact);
    final edge = compact ? 12.0 : 16.0;
    // Where the pages start: right of the rail or the sidebar, with a gap on either side of it
    // The notch, or the system's bar, at either side
    final left = padding.left;
    final right = padding.right;
    final inset =
        left + (rail ? edge + railWidth + edge : _gap + _Sidebar.width + _gap);
    // The player beside the pages stands as far from the window's foot as it does from its top, over the system's bar
    // rather than above it (the pages go under it too): above it the card left a band the height of a tablet's
    // navigation bar. What is in the card keeps above the bar (`bottomInset`). The rail and the sidebar keep above it:
    // Settings is at their foot and would be under the bar
    final frame = compact
        ? compactBottom
        : rail
        ? 16.0
        : _gap;
    final bottom = padding.bottom + frame;
    // The player beside the pages: its width, and the space between it and the window's edge and the pages, which is the
    // one the rail has
    final edgeSide = rail ? edge : _gap;
    final slot = dock > 0 ? dock + 2 * edgeSide : 0.0;
    return LayoutBuilder(
      builder: (context, box) {
        final content = box.maxWidth - inset - right - slot;
        final mini = (content - 32).clamp(0.0, compact ? 400.0 : 460.0);
        // The pages are laid out for what is left of the window: what they read of its size is that
        final media = MediaQuery.of(context)
            .removePadding(removeLeft: true, removeRight: true);
        final pages = MediaQuery(
          data: slot > 0
              ? media.copyWith(
                  size: Size(media.size.width - slot, media.size.height),
                )
              : media,
          child: child,
        );
        return Stack(
          children: [
            // The pages take the whole window, and keep clear of the rail or the sidebar themselves
            Positioned.fill(
              child: SideInset(
                left: inset,
                right: right + slot,
                // What the pages are inset by is said once: a safe area inside a page is not to take it again
                child: pages,
              ),
            ),
            if (rail)
              Positioned(
                left: left + edge,
                top: padding.top + edge,
                bottom: bottom,
                width: railWidth,
                child: zones.zone(
                  FocusZone.nav,
                  tv
                      ? TvRail(index: index, onSelect: onSelect, zones: zones)
                      : _Rail(
                          index: index,
                          onSelect: onSelect,
                          compact: compact,
                        ),
                ),
              )
            else
              Positioned(
                left: left + _gap,
                top: padding.top + _gap,
                bottom: bottom,
                width: _Sidebar.width,
                child: zones.zone(
                  FocusZone.nav,
                  _Sidebar(
                    index: index,
                    where: where,
                    onSelect: onSelect,
                    onSearch: onSearch,
                    onLibrary: onLibrary,
                  ),
                ),
              ),
            // The player beside the pages: a card with its own colours, as tall as the rail
            if (dock > 0)
              Positioned(
                right: right + edgeSide,
                top: padding.top + edgeSide,
                bottom: frame,
                width: dock,
                child: zones.zone(
                  FocusZone.player,
                  NowPlayingPage(
                    docked: true,
                    bottomInset: math.max(0.0, padding.bottom - frame),
                  ),
                ),
              ),
            // The mini player floats in the middle of the pages, the player bar runs along them. Not with the player
            // beside them, which has all of it
            if (dock == 0)
              Positioned(
                left: rail ? inset + (content - mini) / 2 : inset,
                right: rail ? null : right + _gap,
                width: rail ? mini : null,
                bottom: bottom,
                child: zones.zone(
                  FocusZone.player,
                  rail
                      ? MiniPlayer(controller: controller)
                      // A wide window can be wider than the song and its buttons need: the bar stays a capsule in the
                      // middle of the pages instead of running across all of them
                      : Align(
                          heightFactor: 1,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 740),
                            child: PlayerBar(controller: controller),
                          ),
                        ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The tabs in a column of glass on the left of a tablet held upright, with Settings at the bottom.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.index,
    required this.onSelect,
    this.compact = false,
  });

  final int index;
  final ValueChanged<int> onSelect;

  /// Icons only, for a phone on its side.
  final bool compact;

  static const width = 80.0;
  static const compactWidth = 56.0;

  static double widthOf(bool compact) => compact ? compactWidth : width;

  /// A getter, not a constant: the names follow the language.
  static List<(int, IconData, String)> _items(String listen) => [
    (0, Icons.home_rounded, S.tabHome),
    (1, Icons.search_rounded, S.tabSearch),
    (2, Icons.library_music_rounded, S.tabLibrary),
    (3, Icons.graphic_eq_rounded, listen),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tile = compact ? 44.0 : 64.0;
    return Column(
      children: [
        Glass(
          borderRadius: BorderRadius.circular(widthOf(compact) / 2),
          child: Padding(
            padding: EdgeInsets.all(compact ? 6 : 8),
            child: Column(
              children: [
                for (final (tab, icon, label) in _items(
                  HomeShell.listenLabelOf(context),
                ))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Material(
                      color: tab == index ? p.veilStrong : Colors.transparent,
                      borderRadius: BorderRadius.circular(compact ? 22 : 20),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(compact ? 22 : 20),
                        onTap: () => onSelect(tab),
                        child: SizedBox.square(
                          dimension: tile,
                          child: compact
                              ? Tooltip(
                                  message: label,
                                  child: Icon(
                                    icon,
                                    size: 24,
                                    color: tab == index
                                        ? p.primary
                                        : p.textSecondary,
                                  ),
                                )
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      icon,
                                      size: 26,
                                      color: tab == index
                                          ? p.primary
                                          : p.textSecondary,
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      label,
                                      maxLines: 1,
                                      overflow: TextOverflow.fade,
                                      softWrap: false,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: tab == index
                                                ? p.link
                                                : p.textSecondary,
                                          ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const Spacer(),
        SizedBox.square(
          dimension: compact ? 44 : 56,
          child: Glass(
            borderRadius: BorderRadius.circular(compact ? 22 : 28),
            child: IconButton(
              onPressed: () => openSettings(context),
              tooltip: S.settingsTitle,
              icon: Icon(Icons.settings_outlined, color: p.text),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sidebar of a wide screen, in the manner of Apple Music and Spotify on a computer: Search, the tabs, the
/// playlists of the library, and Settings at the bottom.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.index,
    required this.where,
    required this.onSelect,
    required this.onSearch,
    required this.onLibrary,
  });

  final int index;

  /// The page on top in the tab ([Where]): Settings or a list of the library has its row lit instead of the tab's, so that
  /// one row is lit and it is where the person is.
  final String? where;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearch;
  final ValueChanged<int> onLibrary;

  static const width = 256.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final library = AppScope.of(context).library;
    final spot = Where.spotOf(where);
    final inSettings = where == Where.settings;
    // A named page has a row of its own
    final named = spot != null || inSettings;
    return Glass(
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
              child: Text(S.appName, style: theme.headlineSmall),
            ),
            // Looks like a field, and opens Search with the cursor in its own
            Material(
              color: index == 1 ? p.veilStrong : p.veil,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: onSearch,
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(
                        Icons.search_rounded,
                        size: 20,
                        color: index == 1 ? p.primary : p.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          S.tabSearch,
                          style: theme.bodyMedium?.copyWith(
                            color: index == 1 ? p.link : p.textSecondary,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          border: Border.all(color: p.outline),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('/', style: theme.labelSmall),
                      ),
                      const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _SideRow(
              icon: Icons.home_rounded,
              label: S.tabHome,
              selected: index == 0 && !named,
              onTap: () => onSelect(0),
            ),
            _SideRow(
              icon: Icons.library_music_rounded,
              label: S.tabLibrary,
              selected: index == 2 && !named,
              onTap: () => onSelect(2),
            ),
            _SideRow(
              icon: Icons.graphic_eq_rounded,
              label: HomeShell.listenLabelOf(context),
              selected: index == 3 && !named,
              onTap: () => onSelect(3),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 20, 10, 6),
              child: Text(
                S.playlists.toUpperCase(),
                style: theme.labelSmall?.copyWith(
                  letterSpacing: 0.8,
                  color: p.textSecondary,
                ),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: library,
                builder: (context, _) => ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    _SideRow(
                      leading: _SideTile(
                        icon: Icons.favorite_rounded,
                        color: p.primary,
                        on: p.onPrimary,
                      ),
                      label: S.likedSongs,
                      selected: spot == LibraryRequests.liked,
                      onTap: () => onLibrary(LibraryRequests.liked),
                    ),
                    if (!kIsWeb)
                      _SideRow(
                        leading: _SideTile(
                          icon: Icons.download_done_rounded,
                          color: p.veilStrong,
                          on: p.text,
                        ),
                        label: S.downloadedSongs,
                        selected: spot == LibraryRequests.downloaded,
                        onTap: () => onLibrary(LibraryRequests.downloaded),
                      ),
                    if (library.localStatus.enabled)
                      _SideRow(
                        leading: _SideTile(
                          icon: Icons.smartphone_rounded,
                          color: p.veilStrong,
                          on: p.text,
                        ),
                        label: S.localMusic,
                        selected: spot == LibraryRequests.local,
                        onTap: () => onLibrary(LibraryRequests.local),
                      ),
                    for (final playlist in library.playlists)
                      _SideRow(
                        leading: PlaylistCover(
                          thumbs: playlist.thumbs,
                          size: 32,
                          radius: 7,
                        ),
                        label: playlist.name,
                        selected: spot == playlist.id,
                        onTap: () => onLibrary(playlist.id),
                      ),
                  ],
                ),
              ),
            ),
            ListenableBuilder(
              listenable: AppScope.of(context).update,
              builder: (context, _) => _SideRow(
                icon: Icons.settings_outlined,
                label: S.settingsTitle,
                selected: inSettings,
                dot: AppScope.of(context).update.info.hasUpdate,
                onTap: () => openSettings(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A line of the sidebar: a tab, a playlist, Settings.
class _SideRow extends StatelessWidget {
  const _SideRow({
    required this.label,
    required this.onTap,
    this.icon,
    this.leading,
    this.selected = false,
    this.dot = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  /// A dot on the icon: something here is waiting (a newer version of the app).
  final bool dot;

  /// In place of the icon, a playlist's cover.
  final Widget? leading;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = selected ? p.link : p.text;
    return Material(
      color: selected ? p.veilStrong : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          // Not lower than a thing to touch (the sidebar is touched too: a tablet)
          height: 48,
          child: Row(
            children: [
              SizedBox(width: leading == null ? 12 : 6),
              leading ??
                  Badge(
                    key: dot ? const ValueKey('update-dot') : null,
                    smallSize: 9,
                    backgroundColor: p.primary,
                    isLabelVisible: dot,
                    child: Icon(
                      icon,
                      size: 22,
                      color: selected ? p.primary : p.textSecondary,
                    ),
                  ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: leading == null
                      ? Theme.of(context).textTheme.titleSmall
                            ?.copyWith(color: color)
                      : Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The small square in front of the liked and the downloaded songs in the sidebar.
class _SideTile extends StatelessWidget {
  const _SideTile({required this.icon, required this.color, required this.on});

  final IconData icon;
  final Color color;
  final Color on;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Icon(icon, size: 18, color: on),
  );
}

/// The mini player, the tabs and Search, in the manner of Apple Music, open or folded away. Open,
/// the mini player floats above a capsule of tabs, with Search apart as a round button. Folded, the capsule shrinks to
/// the tab that is open and the mini player moves down between it and Search.
///
/// The bars take the same height either way, so that folding them moves nothing on the page; only they themselves
/// take touches, not the room around them.
class _Bars extends StatelessWidget {
  const _Bars({
    required this.controller,
    required this.shrink,
    required this.drop,
    required this.hideMini,
    required this.index,
    required this.browsing,
    required this.onSelect,
    required this.onUnfold,
  });

  final RoomController controller;

  /// How far the capsule of tabs has shrunk, and the mini player come down, 0 to 1.
  final Animation<double> shrink;
  final Animation<double> drop;

  /// Whether the mini player gives way, while the bars are open, to a card on the page that shows the same song.
  final ValueNotifier<bool> hideMini;

  /// The tab that is open, and the last of the capsule's that was.
  final int index;
  final int browsing;
  final ValueChanged<int> onSelect;
  final VoidCallback onUnfold;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = HomeShell.isWide(context);
    final tabs = HomeShell.tabHeightOf(context);
    final mini = MiniPlayer.heightOf(context);
    // Between the mini player and the tabs, between the tabs and Search, and to the sides of the screen
    final gap = wide ? 4.0 : 10.0;
    final apart = wide ? 8.0 : 10.0;
    // Room at the sides, or the bars look as wide as the screen and flat
    final side = wide ? 16.0 : 24.0;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, shrink, drop]),
      builder: (context, _) {
        final shrink = this.shrink.value;
        final drop = this.drop.value;
        // Folded, the tab and Search are as high as the mini player between them, and as low as the bars were
        final high = tabs + (mini - tabs) * shrink;
        // Where the row of tabs starts: below the mini player, when there is a song
        final row = controller.snapshot.current == null ? 0.0 : mini + gap;
        // The bars, the room under them, and a little above for the fade to start in
        final pad = math.max(
          HomeShell._systemBottomOf(context),
          HomeShell._barsBottom,
        );
        final fade = pad + row + tabs + 28;
        return Stack(
          // The fade reaches above the bars, which are only as high as themselves
          clipBehavior: Clip.none,
          children: [
            // What scrolls under the bars fades into the page, a little under the mini player and the tabs and more
            // down to the system's own bar, so that nothing runs into the navigation buttons. Light over the glass:
            // the page shows through it, as through Apple Music's, and only the room under the tabs is nearly solid
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: fade,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [
                        0,
                        (fade - pad - tabs) / fade,
                        (fade - pad) / fade,
                        1,
                      ],
                      colors: [
                        p.base.withValues(alpha: 0),
                        p.base.withValues(alpha: 0.25),
                        p.base.withValues(alpha: 0.45),
                        p.base.withValues(alpha: 0.9),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Clear of the system's own bar
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: HomeShell._barsBottom),
              child: SizedBox(
                height: row + tabs,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final open = box.maxWidth - 2 * side - apart - tabs;
                    // The mini player's sides, folded: beside the tab on the left and Search on the right
                    final inset = side + mini + apart;
                    return Stack(
                      // A song that ends draws its capsule above the bars as it goes
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: side + (inset - side) * drop,
                          right: side + (inset - side) * drop,
                          top:
                              (row - gap - mini) * (1 - drop) +
                              (row + tabs - mini) * drop,
                          child: ValueListenableBuilder<bool>(
                            valueListenable: hideMini,
                            builder: (context, hidden, child) =>
                                AnimatedOpacity(
                                  duration: Motion.of(context, Motion.medium),
                                  // Folded, the capsule sits between the tab and Search, where nothing else is
                                  opacity: hidden && drop == 0 ? 0 : 1,
                                  child: IgnorePointer(
                                    ignoring: hidden && drop == 0,
                                    child: child,
                                  ),
                                ),
                            child: MiniPlayer(
                              controller: controller,
                              folded: drop,
                            ),
                          ),
                        ),
                        Positioned(
                          left: side,
                          top: row + tabs - high,
                          width: open + (mini - open) * shrink,
                          height: high,
                          child: _Tabs(
                            index: index,
                            browsing: browsing,
                            folded: shrink,
                            openWidth: open,
                            onSelect: onSelect,
                            onUnfold: onUnfold,
                          ),
                        ),
                        Positioned(
                          right: side,
                          top: row + tabs - high,
                          width: high,
                          height: high,
                          child: Glass(
                            borderRadius: BorderRadius.circular(high / 2),
                            child: IconButton(
                              onPressed: () => onSelect(1),
                              tooltip: S.tabSearch,
                              icon: Icon(
                                Icons.search_rounded,
                                size: wide ? 22 : 26,
                                color: index == 1 ? p.primary : p.text,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The capsule of tabs, with a soft lens under the tab that is open. Folded, it is a round button with only the tab
/// that is open (or was, while Search is), which opens the bars again.
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.index,
    required this.browsing,
    required this.folded,
    required this.openWidth,
    required this.onSelect,
    required this.onUnfold,
  });

  final int index;
  final int browsing;
  final double folded;

  /// The capsule's width when open, which the tabs keep while it shrinks over them.
  final double openWidth;
  final ValueChanged<int> onSelect;
  final VoidCallback onUnfold;

  /// The tabs of the capsule, each with its place among the tabs; Search, the second, is the round button. A getter,
  /// not a constant: the names follow the language.
  static List<(int, IconData, String)> _items(String listen) => [
    (0, Icons.home_rounded, S.tabHome),
    (2, Icons.library_music_rounded, S.tabLibrary),
    (3, Icons.graphic_eq_rounded, listen),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = HomeShell.isWide(context);
    final round = BorderRadius.circular(HomeShell.tabHeightOf(context) / 2);
    final items = _items(HomeShell.listenLabelOf(context));
    final slot = items.indexWhere((item) => item.$1 == browsing);
    return Glass(
      // A capsule whatever its height is while it shrinks
      borderRadius: BorderRadius.circular(HomeShell.tabHeightOf(context)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The tabs are gone half way, and the one that stays comes in once the capsule is nearly round: never both
          if (folded < 0.5)
            Opacity(
              opacity: 1 - 2 * folded,
              child: IgnorePointer(
                ignoring: folded > 0,
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: openWidth,
                  maxWidth: openWidth,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Slides to the tab that is opened; gone while Search is open
                      AnimatedOpacity(
                        opacity: index == 1 ? 0 : 1,
                        duration: Motion.of(context, 200),
                        child: AnimatedAlign(
                          alignment: Alignment(
                            2 * slot / (items.length - 1) - 1,
                            0,
                          ),
                          duration: Motion.of(context, 320),
                          curve: Curves.easeOutCubic,
                          child: FractionallySizedBox(
                            widthFactor: 1 / items.length,
                            heightFactor: 1,
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: p.text.withValues(alpha: 0.09),
                                  borderRadius: round,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          for (final (tab, icon, label) in items)
                            Expanded(
                              child: InkResponse(
                                onTap: () => onSelect(tab),
                                radius: 40,
                                child: TweenAnimationBuilder<Color?>(
                                  tween: ColorTween(
                                    end: tab == index
                                        ? p.primary
                                        : p.textSecondary,
                                  ),
                                  duration: Motion.of(context, 200),
                                  builder: (context, color, _) {
                                    final glyph = Icon(
                                      icon,
                                      color: color,
                                      size: wide ? 22 : 26,
                                    );
                                    // The word is in the deep shade of the accent: the accent itself is 3.5:1 on the tint
                                    // of the lit pill, which is too little for a word this small
                                    final name = TweenAnimationBuilder<Color?>(
                                      tween: ColorTween(
                                        end: tab == index
                                            ? p.link
                                            : p.textSecondary,
                                      ),
                                      duration: Motion.of(context, 200),
                                      builder: (context, color, _) => Text(
                                        label,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: color,
                                              fontSize: 10.5,
                                            ),
                                      ),
                                    );
                                    // On its side the label goes beside the icon: there is no height to stack them
                                    return wide
                                        ? Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              glyph,
                                              const SizedBox(width: 6),
                                              name,
                                            ],
                                          )
                                        : Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              glyph,
                                              const SizedBox(height: 2),
                                              // A longer word (Vietnamese, large text) shrinks to the room in the
                                              // lit pill instead of touching its edge
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                    ),
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  child: name,
                                                ),
                                              ),
                                            ],
                                          );
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (folded > 0.6)
            Opacity(
              opacity: (folded - 0.6) / 0.4,
              child: IgnorePointer(
                ignoring: folded < 1,
                child: IconButton(
                  onPressed: onUnfold,
                  tooltip: items[slot].$3,
                  icon: Icon(
                    items[slot].$2,
                    size: wide ? 22 : 26,
                    color: index == 1 ? p.text : p.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tells when a page is opened or closed in a tab.
class _StackWatcher extends NavigatorObserver {
  _StackWatcher(this.changed);

  final VoidCallback changed;

  /// The pages of the tab, the first at the bottom: the sidebar lights the row of the one on top ([Where]).
  final _routes = <Route<dynamic>>[];

  /// The name given to the page on top (`RouteSettings.name`), if it has one.
  String? get top => _routes.isEmpty ? null : _routes.last.settings.name;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    focusFirstOfNewRoute();
    changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (at >= 0) _routes.removeAt(at);
    if (newRoute != null) {
      _routes.insert(at < 0 ? _routes.length : at, newRoute);
    }
    changed();
  }
}

/// The names the pages that the sidebar has a row for go by, in `RouteSettings.name`.
abstract final class Where {
  static const settings = 'settings';

  /// A list of the library: [LibraryRequests]'s, or the id of a playlist.
  static String library(int spot) => 'library:$spot';

  static int? spotOf(String? name) =>
      name != null && name.startsWith('library:')
      ? int.tryParse(name.substring(8))
      : null;
}

/// Where a page opened from anywhere goes: into the tab that is showing, with the full player put away if it is open.
/// Sheets and the full player sit above the tabs, so their own navigator is the one for the whole screen, which is not
/// where such a page belongs.
abstract final class TabNavigation {
  static NavigatorState? Function()? _active;
  static String? Function()? _top;
  static VoidCallback? _closePlayer;
  static VoidCallback? _search;

  /// Opens Search with the cursor in its field, from a page that has nothing to show but a way to find songs.
  static void search() => _search?.call();

  /// A named page ([Where]) that is already on top of the tab is not opened again: a second touch of Settings, or
  /// several in a row, leaves the one that is open.
  static Future<T?> push<T>(BuildContext context, Route<T> route) {
    _closePlayer?.call();
    final name = route.settings.name;
    if (name != null && name == _top?.call()) return Future.value();
    return (_active?.call() ?? Navigator.of(context)).push(route);
  }
}

/// Across the top of the web app while the browser has no group key: says so, and asks for it again.
class _KeyBand extends StatelessWidget {
  const _KeyBand({required this.onEnter});

  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Icon(Icons.key_rounded, size: 20, color: p.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(S.webKeyMissing)),
              TextButton(onPressed: onEnter, child: Text(S.webKeyEnter)),
            ],
          ),
        ),
      ),
    );
  }
}
