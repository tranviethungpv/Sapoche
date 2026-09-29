/// All user-visible text in one place, so translating the app later is a single-file job.
abstract final class S {
  static const appName = 'Unison';
  static const tagline = 'Listen together, in perfect sync.';

  // Welcome
  static const yourName = 'Your name';
  static const createRoom = 'Create a room';
  static const joinRoom = 'Join a room';
  static const roomCode = 'Room code';
  static const join = 'Join';
  static const enterName = 'Enter your name first';
  static const codeInvalid = 'Room codes have 6 letters and numbers';
  static const joinFailed = 'Could not connect to the room';
  static const createFailed = 'Could not create a room';

  // Tabs
  static const tabListen = 'Listen';
  static const tabRoom = 'Room';
  static const tabSearch = 'Search';
  static const tabSettings = 'Settings';

  // Room
  static String listening(int n) =>
      n == 1 ? '1 person listening' : '$n people listening';
  static const nowPlaying = 'Now Playing';
  static const upNext = 'Up Next';
  static const played = 'Played';
  static const emptyQueueTitle = 'Nothing queued yet';
  static const emptyQueueBody =
      'Search for a song and add it. Everyone in the room hears it at the same time.';
  static const emptyQueueBodyAlone =
      'Search for a song and add it to start listening.';
  static const addSongs = 'Add songs';
  static const shuffle = 'Shuffle';
  static const playAgain = 'Play again';
  static const queueFinished = 'The queue has finished';
  static const clearQueue = 'Clear queue';
  static const clearQueueQuestion = 'Remove every song from the queue?';
  static const clear = 'Clear';
  static const cancel = 'Cancel';
  static String addedBy(String name) => 'Added by $name';
  static const you = 'You';
  static const copyCode = 'Copy code';
  static const codeCopied = 'Room code copied';
  static const removed = 'Removed from queue';
  static const invite = 'Invite friends';
  static String inviteText(String code, String link) =>
      'Join my room on Unison with the code $code\n$link';
  static String inviteSwitch(String code) => 'Leave this room and join $code?';
  static const switchRoom = 'Switch room';
  static const repeatOff = 'Repeat off';
  static const repeatAll = 'Repeat all';
  static const repeatOne = 'Repeat this song';

  // Starting and leaving rooms
  static const roomSheetIntro =
      'Start a room and everyone in it hears the same song at the same moment.';
  static const recentRooms = 'Recent rooms';
  static String recentLive(int n) => n == 0 ? 'Empty' : '$n listening';
  static const recentGone = 'Expired';
  static const forgetRoom = 'Forget this room';
  static const roomName = 'Room name';
  static const roomNameHint = 'Give it a name';
  static const addRoomName = 'Add a name';
  static const copyLink = 'Copy link';
  static const linkCopied = 'Link copied';
  static const scanToJoin = 'Scan to join';
  static const peopleInRoom = 'People in the room';
  static const guestsAddOnly = 'Guests can only add songs';
  static const guestsAddOnlyHelp =
      'Only you can play, pause, skip or change the queue.';
  static const guestsAddOnlyBanner = 'The owner lets guests add songs only';
  static const owner = 'Owner';
  static const removeFromRoom = 'Remove from room';
  static String removeQuestion(String name) =>
      'Remove $name from the room? They can join again with the code.';
  static const remove = 'Remove';

  // Connection
  static const reconnecting = 'Reconnecting…';
  static const connecting = 'Connecting…';
  static const offline = 'Connection lost';
  static const unauthorized = 'This build is not allowed on the server';

  // Search
  static const searchHint = 'Videos, songs, or a YouTube link';
  static const filterVideos = 'Videos';
  static const filterSongs = 'Songs';
  static const filterPlaylists = 'Playlists';
  static String playlistBy(String uploader, int count) => [
    if (uploader.isNotEmpty) uploader,
    if (count > 0) (count == 1 ? '1 song' : '$count songs'),
  ].join(' · ');
  static const backToPlaylists = 'All playlists';
  static const playlistFailed = 'Could not open that playlist';
  static const searchEmptyTitle = 'Find something to play';
  static const searchEmptyBody =
      'Type a song or artist, or paste a YouTube link.';
  static const noResults = 'No results';
  static const searchFailed = 'Search failed. Check your connection.';
  static String playlistSongs(int n) =>
      n == 1 ? 'Playlist · 1 song' : 'Playlist · $n songs';
  static const addAll = 'Add all';
  static const playlistAdded = 'Playlist added';
  static const playNext = 'Play next';
  static const addToQueue = 'Add to queue';
  static const addedToQueue = 'Added to queue';
  static const willPlayNext = 'Playing next';
  static const notInRoom = 'Join a room first';

  // Player
  static const buffering = 'Loading…';
  static const inSync = 'In sync';
  static const syncing = 'Syncing…';
  static const catchingUp = 'Catching up';
  static const soloOut = 'Waiting for others';
  static const onYourOwn = 'On your own';
  static const rejoin = 'Rejoin';
  static const soloBanner = 'You are listening on your own';
  static const keepPlaying = 'Keep playing';
  static const someone = 'Someone';
  static String pausedBy(String name) => '$name paused the room';
  static String skippedBy(String name, String title) =>
      title.isEmpty ? '$name skipped ahead' : '$name switched to $title';

  // Picture
  static const modeAudio = 'Audio';
  static const modeVideo = 'Video';
  static const videoSection = 'Video';
  static const videoQuality = 'Picture quality';
  static const videoQualityHelp =
      'Applies from the next song. Higher quality uses more data. Music keeps playing when the screen is off; the picture does not.';

  // Who is in the room
  static const membersTitle = 'In the room';
  static const listenTogether = 'Listen together';
  static const listenTogetherOn =
      'Play, pause and skip apply to everyone in the room.';
  static const listenTogetherOff =
      'You keep playing on your own. Your buttons only move you, and you can rejoin any time.';
  static const statusListening = 'Listening';
  static const statusAlone = 'On their own';
  static const statusAway = 'Connection lost';
  static const statusLoading = 'Loading…';
  static String awayCount(int n) => '$n away';
  static String unplayable(String title) =>
      'Nobody could play “$title”. Skipped.';

  // Settings
  static const settingsTitle = 'Settings';
  static const appearance = 'Appearance';
  static const themeSystem = 'System';
  static const themeLight = 'Light';
  static const themeDark = 'Dark';
  static const sync = 'Sync';
  static const latencyTrim = 'Latency trim';
  static const latencyTrimHelp =
      'If this phone is always a little early or late compared with the others, nudge it here.';
  static const reset = 'Reset';
  static const room = 'Room';
  static const rename = 'Rename';
  static const save = 'Save';
  static const leaveRoom = 'Leave room';
  static const leaveQuestion =
      'Leave this room? You can join again with the code.';
  static const leave = 'Leave';
  static const diagnostics = 'Diagnostics';
  static const diagnosticsHelp =
      'Recent events, useful when something goes wrong.';
  static const copyLog = 'Copy log';
  static const logCopied = 'Log copied';
}
