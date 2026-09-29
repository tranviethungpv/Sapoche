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
  static const addSongs = 'Add songs';
  static const clearQueue = 'Clear queue';
  static const clearQueueQuestion = 'Remove every song from the queue?';
  static const clear = 'Clear';
  static const cancel = 'Cancel';
  static String addedBy(String name) => 'Added by $name';
  static const you = 'You';
  static const copyCode = 'Copy code';
  static const codeCopied = 'Room code copied';
  static const removed = 'Removed from queue';

  // Connection
  static const reconnecting = 'Reconnecting…';
  static const connecting = 'Connecting…';
  static const offline = 'Connection lost';
  static const unauthorized = 'This build is not allowed on the server';

  // Search
  static const searchHint = 'Songs, artists, or a YouTube link';
  static const searchEmptyTitle = 'Find something to play';
  static const searchEmptyBody =
      'Type a song or artist, or paste a YouTube link.';
  static const noResults = 'No results';
  static const searchFailed = 'Search failed. Check your connection.';
  static const playNext = 'Play next';
  static const addToQueue = 'Add to queue';
  static const addedToQueue = 'Added to queue';
  static const willPlayNext = 'Playing next';
  static const notInRoom = 'Join a room first';

  // Player
  static const buffering = 'Loading…';
  static const inSync = 'In sync';
  static const syncing = 'Syncing…';
  static const soloOut = 'Waiting for others';
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
