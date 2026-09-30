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
  static const tabLibrary = 'Library';
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
  static const alreadyInQueue = 'Already in the queue';
  static String addedSkipped(int added, int skipped) =>
      '$added added, $skipped already in the queue';
  static const notInRoom = 'Join a room first';

  // Downloads and storage
  static const download = 'Download';
  static const removeDownload = 'Remove download';
  static const downloading = 'Downloading…';
  static const downloadAll = 'Download all';
  static const downloadedSongs = 'Downloaded';
  static String downloadStarted(int n) =>
      n == 1 ? 'Downloading 1 song' : 'Downloading $n songs';
  static const useMobileData = 'Use mobile data?';
  static const useMobileDataBody =
      'You are not on Wi-Fi. Downloading uses your mobile data.';
  static const waitingToDownload = 'Waiting for Wi-Fi and a charger';
  static const queuedToDownload = 'Waiting to download';
  static const downloadFailed = 'Download failed';
  static const deleteAll = 'Delete all';
  static const deleteDownloadsQuestion =
      'Remove every downloaded song from this phone?';
  static const noDownloadsTitle = 'Nothing downloaded';
  static const noDownloadsBody =
      'Choose Download on a song, a playlist or your liked songs to keep them for when there is no network.';
  static const storage = 'Storage';
  static const storageDownloads = 'Downloads';
  static const storagePlayed = 'Played songs';
  static const cacheLimit = 'Size for played songs';
  static const cacheLimitHelp =
      'Songs you listened to are kept so that they play again without using data. The oldest go first when it is full. A new size counts from the next time the app starts.';
  static const autoDownload = 'Download liked songs';
  static const autoDownloadHelp =
      'Saves your liked songs by itself on Wi-Fi while the phone is charging.';
  static const clearCache = 'Clear';

  // Suggestions
  static const forYou = 'For you';
  static const recentSearches = 'Recent searches';
  static const autoplay = 'Autoplay';
  static const autoplayHelp =
      'When your queue runs out, keep playing songs like the last one.';

  // Library
  static const likedSongs = 'Liked songs';
  static const recentlyPlayed = 'Recently played';
  static String songCount(int n) => n == 1 ? '1 song' : '$n songs';
  static const like = 'Like';
  static const unlike = 'Unlike';
  static const play = 'Play';
  static const backToLibrary = 'Library';
  static const clearHistory = 'Clear history';
  static const clearHistoryQuestion =
      'Remove everything from your listening history? Liked songs are kept.';
  static const playlists = 'Playlists';
  static const newPlaylist = 'New playlist';
  static const importFromLink = 'Import from a link';
  static const playlistName = 'Playlist name';
  static const importHint = 'YouTube playlist or song link';
  static const importFailed = 'Could not read that link';
  static const importEmpty = 'That link has no songs';
  static const addToPlaylist = 'Add to playlist';
  static String addedToPlaylist(String name) => 'Added to $name';
  static String alreadyInPlaylist(String name) => 'Already in $name';
  static const deletePlaylist = 'Delete playlist';
  static String deletePlaylistQuestion(String name) =>
      'Delete “$name”? This cannot be undone.';
  static const delete = 'Delete';
  static const emptyPlaylistTitle = 'This playlist is empty';
  static const emptyPlaylistBody =
      'Choose “Add to playlist” on any song to put it here.';
  static const saveAsPlaylist = 'Save as playlist';
  static const playlistSaved = 'Playlist saved';
  static const noLikedTitle = 'No liked songs yet';
  static const noLikedBody = 'Tap the heart on a song to keep it here.';
  static const noRecentTitle = 'Nothing played yet';
  static const noRecentBody = 'Songs you listen to for a while show up here.';
  static String ago(Duration d) {
    if (d.inMinutes < 1) return 'Just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    if (d.inDays == 1) return 'Yesterday';
    return '${d.inDays} days ago';
  }

  // Backup
  static const backup = 'Backup';
  static const backupSave = 'Save your library to a file';
  static const backupAdd = 'Add from a backup file';
  static const backupHelp =
      'A backup keeps your liked songs, playlists and listening history in one file you can put anywhere. '
      'Adding one never removes anything. Downloaded songs are not in it.';
  static String _backupParts(int liked, int playlists, int listens) => [
    if (liked > 0) '$liked liked',
    if (playlists > 0) playlists == 1 ? '1 playlist' : '$playlists playlists',
    if (listens > 0) '$listens listens',
  ].join(', ');
  static String backupSaved(int liked, int playlists, int listens) =>
      'Saved: ${_backupParts(liked, playlists, listens)}';
  static String backupAdded(int liked, int playlists, int listens) =>
      'Added: ${_backupParts(liked, playlists, listens)}';
  static const backupNothingNew = 'Nothing new in that file';
  static const backupEmpty = 'Saved, but there was nothing in your library yet';

  // Sleep timer
  static const sleepTimer = 'Sleep timer';
  static String sleepMinutes(int minutes) => minutes == 60
      ? '1 hour'
      : minutes > 60
      ? '1 hour ${minutes - 60} min'
      : '$minutes minutes';
  static const sleepSongEnd = 'End of this song';
  static const sleepOff = 'Turn off timer';
  static const sleepInRoom =
      'In a room only this phone stops; the room plays on without you.';
  static String sleepStopsAt(String time) => 'Stops at $time';
  static const sleepStopsAfterSong = 'Stops after this song';

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
  static const playback = 'Playback';
  static const noRoom = 'Not in a room';
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
  static const diagnosticsHelp =
      'Recent events, useful when something goes wrong.';
  static const copyLog = 'Copy log';
  static const logCopied = 'Log copied';

  // Full player: lyrics, queue, related songs, song and artist pages
  static const lyrics = 'Lyrics';
  static const related = 'Related';
  static const noLyrics = 'No lyrics for this song';
  static const lyricsFailed = 'Couldn’t load the lyrics';
  static const musicFailed = 'Couldn’t reach YouTube Music';
  static const tryAgain = 'Try again';
  static const songInfo = 'Song info';
  static const goToArtist = 'Go to artist';
  static const suggested = 'Suggested';
  static const autoplayNote =
      'Similar songs keep playing when the queue runs out.';
  static const nothingAfter = 'Nothing is queued after this song.';
  static const youMightAlsoLike = 'You might also like';
  static const otherPerformances = 'Other performances';
  static const similarArtists = 'Similar artists';
  static const aboutArtist = 'About the artist';
  static const nothingRelated = 'Nothing related to this song was found';
  static const topSongs = 'Top songs';
  static const fansAlsoLike = 'Fans might also like';
  static const infoArtist = 'Artist';
  static const infoAlbum = 'Album';
  static const infoYear = 'Year';
  static const infoLength = 'Length';
  static const infoReach = 'Reach';
  static const infoKind = 'Version';
  static const addedByLabel = 'Added by';
  static const kindSong = 'Song';
  static const kindVideo = 'Video';
  static const showMore = 'More';
  static const showLess = 'Less';
  static String subscribers(String count) => '$count subscribers';
}
