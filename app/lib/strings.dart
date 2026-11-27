/// All user-visible text in one place. Each text is written in English and Vietnamese side by side, so a text
/// can never be missing in one of them; [current] says which one is shown.
abstract final class S {
  /// The languages the app has texts for, as the codes of [current].
  static const languages = ['en', 'vi'];

  /// Language of every text below, one of [languages]. The app sets it from the person's choice or the phone's language.
  static String current = 'en';

  static String _t(String en, String vi) => current == 'vi' ? vi : en;

  static String get appName => _t('Sapoche', 'Sapoche');
  static String get tagline => _t(
    'Listen together, in perfect sync.',
    'Cùng nghe nhạc, chung từng nhịp.',
  );

  // Welcome
  static String get yourName => _t('Your name', 'Tên của bạn');
  static String get nameInRoom => _t(
    'The name everyone in the room will see',
    'Tên mọi người trong phòng sẽ thấy',
  );
  static String get createRoom => _t('Create a room', 'Tạo phòng');
  static String get createRoomWithSong => _t(
    'Create a room with this song',
    'Bắt đầu với bài đang nghe',
  );
  static String get createEmptyRoom => _t('Empty room', 'Phòng trống');
  static String get joinRoom => _t('Join a room', 'Vào phòng');
  static String get roomCode => _t('Room code', 'Mã phòng');
  static String get join => _t('Join', 'Vào');
  static String get enterName =>
      _t('Enter your name first', 'Hãy nhập tên của bạn trước');
  static String get codeInvalid => _t(
    'Room codes have 6 letters and numbers',
    'Mã phòng gồm 6 chữ cái và chữ số',
  );
  static String get joinFailed =>
      _t('Could not connect to the room', 'Không kết nối được với phòng');
  static String get createFailed =>
      _t('Could not create a room', 'Không tạo được phòng');
  static String get checkConnection => _t(
    'Check the connection and try again.',
    'Hãy kiểm tra kết nối rồi thử lại.',
  );

  // Tabs
  static String get tabHome => _t('Home', 'Trang chủ');
  static String get tabListen => _t('Listen', 'Nghe');
  static String get tabRoom => _t('Room', 'Phòng');

  /// On the chip of the home page that goes back into the last room.
  static String get rejoinChip => _t('Rejoin', 'Vào lại');
  static String get tabSearch => _t('Search', 'Tìm kiếm');
  static String get tabLibrary => _t('Library', 'Thư viện');
  static String get tabSettings => _t('Settings', 'Cài đặt');

  // Room
  static String listening(int n) => _t(
    n == 1 ? '1 person listening' : '$n people listening',
    '$n người đang nghe',
  );
  static String get nowPlaying => _t('Now playing', 'Đang phát');
  static String get upNext => _t('Up next', 'Tiếp theo');
  static String get nextInQueue =>
      _t('Next in queue', 'Tiếp theo trong hàng đợi');
  static String nextFrom(String list) =>
      _t('Next from: $list', 'Tiếp theo từ: $list');
  static String get queueCleared =>
      _t('Queue cleared', 'Đã xoá hàng đợi');
  static String get played => _t('Played', 'Đã phát');
  static String get emptyQueueTitle =>
      _t('Nothing queued yet', 'Chưa có bài nào trong hàng đợi');
  static String get emptyQueueBody => _t(
    'Search for a song and add it. Everyone in the room hears it at the same time.',
    'Tìm một bài hát và thêm vào. Mọi người trong phòng nghe cùng một lúc.',
  );
  static String get emptyQueueBodyAlone => _t(
    'Search for a song and add it to start listening.',
    'Tìm một bài hát và thêm vào để bắt đầu nghe.',
  );
  static String get addSongs => _t('Add songs', 'Thêm bài hát');
  static String get shuffle => _t('Shuffle', 'Trộn bài');
  static String get repeat => _t('Repeat', 'Lặp lại');
  static String get shuffleOn => _t('Shuffle on', 'Đang bật trộn bài');
  static String get shuffleOff => _t('Shuffle off', 'Đang tắt trộn bài');
  static String get upNextShuffled =>
      _t('Up next shuffled', 'Đã trộn các bài tiếp theo');
  static String get noVideoVersion => _t(
    'No video version of this song was found',
    'Không tìm thấy bản video của bài này',
  );
  static String get videoForEveryone => _t(
    'Switched to the video version for everyone',
    'Đã chuyển sang bản video cho mọi người',
  );
  static String get playAgain => _t('Play again', 'Phát lại');
  static String get queueFinished =>
      _t('The queue has finished', 'Hàng đợi đã phát hết');
  static String get clearQueue => _t('Clear queue', 'Xoá hàng đợi');
  static String get clearQueueQuestion =>
      _t('Remove every song from the queue?', 'Xoá mọi bài khỏi hàng đợi?');
  static String get clear => _t('Clear', 'Xoá');
  static String get cancel => _t('Cancel', 'Huỷ');
  static String get close => _t('Close', 'Đóng');
  static String addedBy(String name) => _t('Added by $name', '$name đã thêm');
  static String get you => _t('You', 'Bạn');
  static String get copyCode => _t('Copy code', 'Sao chép mã');
  static String get codeCopied =>
      _t('Room code copied', 'Đã sao chép mã phòng');
  static String get removed => _t('Removed from queue', 'Đã xoá khỏi hàng đợi');
  static String get removeFromQueue =>
      _t('Remove from queue', 'Xoá khỏi hàng đợi');
  static String get moveUp => _t('Move up', 'Đưa lên');
  static String get moveDown => _t('Move down', 'Đưa xuống');
  static String get invite => _t('Invite friends', 'Mời bạn bè');
  static String get inviteShort => _t('Invite', 'Mời');
  static String get listeningAlone => _t('Listening alone', 'Đang nghe một mình');
  static String get listeningAloneBody => _t(
    'Invite a friend and you hear the same song at the same moment.',
    'Mời một người bạn, hai người sẽ nghe cùng một bài vào cùng một lúc.',
  );
  static String inviteText(String code, String link) => _t(
    'Join my room on Sapoche with the code $code\n$link',
    'Vào phòng của mình trên Sapoche bằng mã $code\n$link',
  );
  static String inviteSwitch(String code) => _t(
    'Leave this room and join $code?',
    'Rời phòng này và vào phòng $code?',
  );
  static String get switchRoom => _t('Switch room', 'Đổi phòng');
  static String get repeatOff => _t('Repeat off', 'Tắt lặp lại');
  static String get repeatAll => _t('Repeat all', 'Lặp lại tất cả');
  static String get repeatOne => _t('Repeat this song', 'Lặp lại bài này');

  // What the server refuses, by its error code; other codes are bugs of the app and show the server's own words
  static String? serverError(String code) => switch (code) {
    'forbidden' => _t(
      'Only the owner of the room can do that',
      'Chỉ chủ phòng làm được việc này',
    ),
    'removed' => _t(
      'The owner removed you from the room',
      'Chủ phòng đã mời bạn ra khỏi phòng',
    ),
    'room_not_found' => _t(
      'There is no room with this code',
      'Không có phòng nào với mã này',
    ),
    'room_full' => _t('The room is full', 'Phòng đã đầy'),
    'key_refused' => keyRefused,
    'server_busy' => _t(
      'The server is busy, try again in a minute',
      'Máy chủ đang bận, hãy thử lại sau một phút',
    ),
    'queue_full' => _t('The queue is full', 'Hàng đợi đã đầy'),
    'rate_limited' => _t(
      'Too many messages, slow down',
      'Bạn thao tác quá nhanh, hãy chậm lại',
    ),
    _ => null,
  };
  static String get thisSong => _t('this song', 'bài này');

  // Starting and leaving rooms
  static String get roomSheetIntro => _t(
    'Start a room and everyone in it hears the same song at the same moment.',
    'Tạo một phòng và mọi người trong đó nghe cùng một bài vào cùng một lúc.',
  );
  static String get recentRooms => _t('Recent rooms', 'Phòng gần đây');
  static String recentLive(int n) =>
      _t(n == 0 ? 'Empty' : '$n listening', n == 0 ? 'Trống' : '$n đang nghe');
  static String get recentGone => _t('Expired', 'Đã hết hạn');
  static String get forgetRoom => _t('Forget this room', 'Quên phòng này');
  static String get roomName => _t('Room name', 'Tên phòng');
  static String get roomNameHint => _t('Give it a name', 'Đặt một cái tên');
  static String get addRoomName => _t('Add a name', 'Thêm tên');
  static String get copyLink => _t('Copy link', 'Sao chép liên kết');
  static String get linkCopied => _t('Link copied', 'Đã sao chép liên kết');
  static String get scanToJoin => _t('Scan to join', 'Quét để vào phòng');
  static String get peopleInRoom =>
      _t('People in the room', 'Những người trong phòng');
  static String get guestsAddOnly =>
      _t('Guests can only add songs', 'Khách chỉ được thêm bài');
  static String get guestsAddOnlyHelp => _t(
    'Only you can play, pause, skip or change the queue.',
    'Chỉ bạn được phát, tạm dừng, chuyển bài hoặc sửa hàng đợi.',
  );
  static String get guestsAddOnlyBanner => _t(
    'The owner lets guests add songs only',
    'Chủ phòng chỉ cho khách thêm bài',
  );
  static String get waitWeak =>
      _t('Wait for slow connections', 'Đợi người mạng yếu');
  static String get waitWeakHelp => _t(
    'When someone\'s music stops loading, the room pauses for up to 15 seconds so they can keep up.',
    'Khi nhạc của ai đó ngừng tải, phòng dừng tối đa 15 giây để người đó theo kịp.',
  );
  static String waitingFor(String name) =>
      _t('Waiting for $name to load the music…', 'Đang đợi $name tải nhạc…');
  static String get statusWeak => _t('Weak network', 'Mạng yếu');
  static String get owner => _t('Owner', 'Chủ phòng');
  static String get removeFromRoom =>
      _t('Remove from room', 'Mời ra khỏi phòng');
  static String removeQuestion(String name) => _t(
    'Remove $name from the room? They can join again with the code.',
    'Mời $name ra khỏi phòng? Họ vẫn vào lại được bằng mã.',
  );
  static String get remove => _t('Remove', 'Mời ra');

  // Connection
  static String get reconnecting => _t('Reconnecting…', 'Đang kết nối lại…');
  static String get connecting => _t('Connecting…', 'Đang kết nối…');
  static String get offline => _t('Connection lost', 'Mất kết nối');
  static String get unauthorized => _t(
    'This copy of the app cannot use your group\'s server. Ask whoever set Sapoche up for you.',
    'Bản app này không vào được máy chủ của nhóm. Hãy nhờ người đã cài Sapoche cho bạn.',
  );

  // Search
  static String get searchHint => _t(
    'Videos, songs, or a YouTube link',
    'Video, bài hát hoặc liên kết YouTube',
  );
  static String get pasteLink => _t('Paste a link', 'Dán liên kết');
  static String get clearSearch => _t('Clear search', 'Xoá nội dung tìm');
  static String get searchTop => _t('Top results', 'Hàng đầu');
  static String get topResult => _t('Top result', 'Kết quả hàng đầu');
  static String get searchYouTube => 'YouTube';

  /// The name of a filter of a search as YouTube Music gives it (in English); one it is not known by is left as it is.
  static String searchChip(String label) => switch (label) {
    'Artists' => _t('Artists', 'Nghệ sĩ'),
    'Albums' => _t('Albums', 'Album'),
    'Songs' => _t('Songs', 'Bài hát'),
    'Videos' => _t('Videos', 'Video'),
    'Community playlists' => playlists,
    'Featured playlists' => _t('Featured playlists', 'Danh sách nổi bật'),
    'Profiles' => _t('Profiles', 'Hồ sơ'),
    'Episodes' => _t('Episodes', 'Tập'),
    'Podcasts' => _t('Podcasts', 'Podcast'),
    _ => label,
  };
  static String get kindEpisode => _t('Episode', 'Tập');
  static String get kindProfile => _t('Profile', 'Hồ sơ');
  static String get playlistFailed =>
      _t('Could not open that playlist', 'Không mở được danh sách phát đó');
  static String get searchEmptyTitle =>
      _t('Find something to play', 'Tìm thứ gì đó để nghe');
  static String get searchEmptyBody => _t(
    'Type a song or artist, or paste a YouTube link.',
    'Gõ tên bài hát hoặc nghệ sĩ, hoặc dán liên kết YouTube.',
  );
  static String get noResults => _t('No results', 'Không có kết quả');
  static String get noResultsBody => _t(
    'Check the spelling, or try the name of the artist.',
    'Kiểm tra chính tả, hoặc thử tên nghệ sĩ.',
  );
  static String get searchFailed => _t(
    'Search failed. Check your connection.',
    'Tìm kiếm không được. Hãy kiểm tra kết nối.',
  );
  static String get playlistAdded =>
      _t('Playlist added', 'Đã thêm danh sách phát');
  static String get playNext => _t('Play next', 'Phát tiếp theo');
  static String get playNextShort => _t('Play next', 'Phát tiếp');
  static String get addToQueue => _t('Add to queue', 'Thêm vào cuối');
  static String get addToQueueShort => _t('Add to queue', 'Thêm vào cuối');
  static String get addedToQueue =>
      _t('Added to queue', 'Đã thêm vào hàng đợi');
  static String get willPlayNext => _t('Playing next', 'Sẽ phát tiếp theo');
  static String get undo => _t('Undo', 'Hoàn tác');
  static String get alreadyInQueue =>
      _t('Already in the queue', 'Đã có trong hàng đợi');
  static String addedSkipped(int added, int skipped) => _t(
    '$added added, $skipped already in the queue',
    'Đã thêm $added bài, $skipped bài đã có trong hàng đợi',
  );
  static String get notInRoom =>
      _t('Join a room first', 'Hãy vào một phòng trước');

  // Downloads and storage
  static String get download => _t('Download', 'Tải về');
  static String get removeDownload => _t('Remove download', 'Xoá bản tải');
  static String get downloading => _t('Downloading…', 'Đang tải…');
  static String get downloadAll => _t('Download all', 'Tải tất cả');
  static String get downloadedSongs => _t('Downloaded', 'Đã tải');
  static String downloadStarted(int n) => _t(
    n == 1 ? 'Downloading 1 song' : 'Downloading $n songs',
    'Đang tải $n bài',
  );
  static String downloadingOf(int n, int total) =>
      _t('Downloading $n of $total', 'Đang tải $n/$total');
  static String downloadedAll(int n) => _t(
    n == 1 ? 'Downloaded 1 song' : 'Downloaded $n songs',
    'Đã tải xong $n bài',
  );
  static String downloadedSome(int n, int failed) => _t(
    'Downloaded $n, $failed could not be downloaded',
    'Đã tải $n bài, $failed bài không tải được',
  );
  static String get useMobileData =>
      _t('Use mobile data?', 'Dùng dữ liệu di động?');
  static String get useMobileDataBody => _t(
    'You are not on Wi-Fi. Downloading uses your mobile data.',
    'Bạn không dùng Wi-Fi. Tải về sẽ tốn dữ liệu di động.',
  );
  static String get waitingToDownload =>
      _t('Waiting for Wi-Fi and a charger', 'Đợi có Wi-Fi và đang sạc');
  static String get queuedToDownload =>
      _t('Waiting to download', 'Đang chờ tải');
  static String get downloadFailed => _t('Download failed', 'Tải không được');
  static String get downloadUnavailable =>
      _t('Not available on YouTube', 'Không có trên YouTube');
  static String get willTryAgain => _t('Will try again', 'Sẽ thử lại');
  static String downloadsTake(String size) =>
      _t('Takes $size on this phone', 'Chiếm $size trên điện thoại');
  static String notDownloadedCount(int n) => _t(
    n == 1 ? '1 song not downloaded' : '$n songs not downloaded',
    '$n bài chưa tải được',
  );
  static String get dropFromList => _t('Remove from list', 'Bỏ khỏi danh sách');
  static String get dropAll => _t('Remove all', 'Bỏ tất cả');
  static String dropAllQuestion(int n) => _t(
    'Remove $n songs that could not be downloaded from the list?',
    'Bỏ $n bài chưa tải được khỏi danh sách?',
  );
  static String get stopDownloading => _t('Stop', 'Dừng');
  static String stopDownloadingQuestion(int n) => _t(
    'Stop downloading and take the $n songs not downloaded yet off the list? What is on the phone stays.',
    'Dừng tải và bỏ $n bài chưa tải khỏi danh sách? Bài đã tải vẫn còn trên máy.',
  );
  static String get deleteAll => _t('Delete all', 'Xoá tất cả');
  static String get deleteDownloadsQuestion => _t(
    'Remove every downloaded song from this phone?',
    'Xoá mọi bài đã tải khỏi điện thoại này?',
  );
  static String get noDownloadsTitle =>
      _t('Nothing downloaded', 'Chưa tải gì cả');
  static String get noDownloadsBody => _t(
    'Choose Download on a song, a playlist or your liked songs to keep them for when there is no network.',
    'Chọn Tải về ở một bài hát, danh sách phát hoặc bài đã thích để giữ lại, nghe được cả khi không có mạng.',
  );
  static String get storage => _t('Storage', 'Bộ nhớ');
  static String get storageDownloads => _t('Downloads', 'Bài đã tải');
  static String get storagePlayed => _t('Played songs', 'Bài đã nghe');
  static String get browserStorageUsed =>
      _t('Used by Sapoche', 'Sapoche đang dùng');
  static String get browserStorageKeep =>
      _t('Keep my data', 'Giữ dữ liệu của tôi');
  static String get browserStorageKept =>
      _t('Kept unless you clear it', 'Được giữ, trừ khi bạn tự xoá');
  static String get browserStorageNotKept =>
      _t('The browser may clear it', 'Trình duyệt có thể xoá');
  static String get browserStorageDenied => _t(
    'The browser did not agree. It may agree once the page is installed or used more often.',
    'Trình duyệt chưa đồng ý. Có thể nó sẽ đồng ý khi trang được cài hoặc dùng thường xuyên hơn.',
  );
  static String get browserStorageHelp => _t(
    'Your library stays in this browser only.',
    'Thư viện chỉ nằm trong trình duyệt này.',
  );
  static String get browserStorageMore => _t(
    'It is lost if the browser runs short of space or site data is cleared. Songs are streamed, not saved.',
    'Nó mất nếu trình duyệt thiếu chỗ hoặc bạn xoá dữ liệu trang. Bài hát được phát trực tiếp, không lưu.',
  );
  static String get webQualityHelp => _t(
    'YouTube picks the quality of the sound in a browser, by your connection. It cannot be set here.',
    'Trình duyệt do YouTube tự chọn chất lượng âm thanh theo đường truyền. Không chỉnh được ở đây.',
  );
  static String get cacheLimit =>
      _t('Size for played songs', 'Dung lượng cho bài đã nghe');
  static String get cacheLimitHelp => _t(
    'Songs you listened to are kept, to play again without using data.',
    'Bài đã nghe được giữ lại để phát lại mà không tốn dữ liệu.',
  );
  static String get cacheLimitMore => _t(
    'The oldest go first when it is full. A new size counts from the next time the app starts.',
    'Khi đầy thì bài cũ nhất bị xoá trước. Dung lượng mới có hiệu lực từ lần mở app sau.',
  );
  static String get autoDownload =>
      _t('Download liked songs', 'Tải bài đã thích');
  static String get autoDownloadHelp => _t(
    'Saves your liked songs by itself on Wi-Fi while the phone is charging.',
    'Tự lưu các bài đã thích khi có Wi-Fi và điện thoại đang sạc.',
  );
  static String get clearCache => _t('Clear', 'Xoá');
  static String get offlineCellular =>
      _t('Download on mobile data', 'Tự tải qua dữ liệu di động');
  static String get offlineCellularHelp => _t(
    'Playlists and folders you download also get their new songs on mobile data, not only on Wi-Fi. About 4 MB a song.',
    'Playlist và thư mục đã bật tải về nhận cả bài mới qua dữ liệu di động, không chỉ Wi-Fi. Khoảng 4 MB mỗi bài.',
  );

  // Playlists and folders kept on the phone
  static String keptByFolder(String folder) =>
      _t('Downloaded with the folder $folder', 'Đang tải theo thư mục $folder');
  static String get waitForWifi => _t('Wait for Wi-Fi', 'Đợi Wi-Fi');
  static String get offlineWaitsForWifi =>
      _t('The songs will download on Wi-Fi', 'Bài sẽ tự tải khi có Wi-Fi');
  static String get stopOfflinePlaylist =>
      _t('Stop downloading this playlist?', 'Thôi tự tải playlist này?');
  static String get stopOfflineFolder =>
      _t('Stop downloading this folder?', 'Thôi tự tải thư mục này?');
  static String stopOfflineBody(int n) => _t(
    n == 1
        ? 'Songs added later will not download. Remove the 1 downloaded song from this phone too?'
        : 'Songs added later will not download. Remove the $n downloaded songs from this phone too?',
    'Bài thêm sau sẽ không tự tải nữa. Xoá luôn $n bài đã tải khỏi điện thoại?',
  );
  static String get keepSongs => _t('Keep songs', 'Giữ bài');

  // Suggestions
  static String get forYou => _t('For you', 'Dành cho bạn');
  static String get recentSearches => _t('Recent searches', 'Tìm kiếm gần đây');
  static String get autoplay => _t('Autoplay', 'Tự động phát');
  static String get autoplayHelp => _t(
    'When your queue runs out, keep playing songs like the last one.',
    'Khi hết hàng đợi, tự phát tiếp các bài gần giống bài vừa nghe.',
  );

  // Music on this phone
  static String get localMusic => _t('On this phone', 'Trên máy này');
  static String get localMusicSwitch =>
      _t('Show music on this phone', 'Hiện nhạc trên máy này');
  static String get localMusicSwitchBody => _t(
    'Plays the music files stored on this phone. They stay on it: they cannot be added to a room.',
    'Phát các tệp nhạc có trong máy. Chúng chỉ nằm trên máy này: không thể thêm vào phòng.',
  );
  static String get localAllowTitle =>
      _t('Play the music on your phone', 'Phát nhạc có trong máy');
  static String get localAllowBody => _t(
    'Allow Sapoche to read the music files on this phone to play them next to your YouTube songs. Nothing leaves your phone.',
    'Cho phép Sapoche đọc các tệp nhạc trong máy để phát cùng các bài YouTube. Không có gì rời khỏi máy.',
  );
  static String get localAllow => _t('Allow', 'Cho phép');
  static String get localBlockedBody => _t(
    'Access to your music was refused. You can allow it in the settings of your phone.',
    'Quyền đọc nhạc đã bị từ chối. Bạn có thể cho phép lại trong cài đặt của điện thoại.',
  );
  static String get localOpenSettings =>
      _t('Open phone settings', 'Mở cài đặt điện thoại');
  static String get localEmptyTitle =>
      _t('No music found', 'Không thấy bài nhạc nào');
  static String get localEmptyAndroid => _t(
    'Music files on this phone show up here. Songs shorter than 30 seconds are left out.',
    'Các tệp nhạc trong máy sẽ hiện ở đây. Bài ngắn hơn 30 giây được bỏ qua.',
  );
  static String get localEmptyIos => _t(
    'Copy music into Files › On My iPhone › Sapoche, or tap Add files.',
    'Chép nhạc vào Tệp › Trên iPhone › Sapoche, hoặc bấm Thêm tệp.',
  );
  static String get localAddFiles => _t('Add files', 'Thêm tệp');
  static String localAdded(int n) => _t(
    n == 1 ? 'Added 1 file' : 'Added $n files',
    'Đã thêm $n tệp',
  );
  static String localUnsupported(int n) => _t(
    n == 1
        ? '1 file cannot be played on an iPhone'
        : '$n files cannot be played on an iPhone',
    '$n tệp không phát được trên iPhone',
  );
  static String get localFilter => _t('Search this phone', 'Tìm trong máy');
  static String get localRefresh => _t('Refresh', 'Làm mới');
  static String get sortBy => _t('Sort by', 'Sắp xếp theo');
  static String get sortRecent => _t('Recently added', 'Mới thêm');
  static String get sortTitle => _t('Title', 'Tên');
  static String get sortArtist => _t('Artist', 'Nghệ sĩ');
  static String get sortAlbum => _t('Album', 'Album');
  static String get fileMissing => _t('File not found', 'Không tìm thấy tệp');
  static String get localNoRoom => _t(
    'This song is a file on your phone: others in the room do not have it',
    'Bài này là tệp trong máy bạn: người khác trong phòng không có',
  );
  static String localLeftOut(int n) => _t(
    n == 1
        ? 'Left out 1 song that is only on this phone'
        : 'Left out $n songs that are only on this phone',
    'Đã bỏ $n bài chỉ có trên máy này',
  );
  static String backupLocalLeftOut(int n) => _t(
    n == 1
        ? '1 song from this phone was not saved'
        : '$n songs from this phone were not saved',
    '$n bài trên máy này không được lưu',
  );

  // Library
  static String get likedSongs => _t('Liked songs', 'Bài đã thích');
  static String get recentlyPlayed => _t('Recently played', 'Nghe gần đây');
  static String songCount(int n) =>
      _t(n == 1 ? '1 song' : '$n songs', '$n bài');
  static String get like => _t('Like', 'Thích');
  static String get unlike => _t('Unlike', 'Bỏ thích');
  static String get play => _t('Play', 'Phát');
  static String get clearHistory => _t('Clear history', 'Xoá lịch sử');
  static String get clearHistoryQuestion => _t(
    'Remove everything from your listening history? Liked songs are kept.',
    'Xoá toàn bộ lịch sử nghe? Các bài đã thích vẫn được giữ.',
  );
  static String get playlists => _t('Playlists', 'Danh sách phát');
  static String get newPlaylist => _t('New playlist', 'Danh sách phát mới');
  static String get noPlaylistsTitle =>
      _t('No playlists yet', 'Chưa có danh sách phát');
  static String get noPlaylistsBody => _t(
    'Make one to keep songs together, or bring one in from a YouTube link.',
    'Tạo một danh sách để gom bài lại, hoặc nhập từ liên kết YouTube.',
  );
  static String get importFromLink =>
      _t('Import from a link', 'Nhập từ liên kết');
  static String get playlistName => _t('Playlist name', 'Tên danh sách phát');
  static String get importHint => _t(
    'YouTube playlist or song link',
    'Liên kết danh sách phát hoặc bài hát YouTube',
  );
  static String get importFailed =>
      _t('Could not read that link', 'Không đọc được liên kết đó');
  static String get importEmpty =>
      _t('That link has no songs', 'Liên kết đó không có bài nào');
  static String get addToPlaylist =>
      _t('Add to playlist', 'Thêm vào danh sách phát');
  static String addedToPlaylist(String name) =>
      _t('Added to $name', 'Đã thêm vào $name');
  static String alreadyInPlaylist(String name) =>
      _t('Already in $name', 'Đã có trong $name');
  static String get deletePlaylist =>
      _t('Delete playlist', 'Xoá danh sách phát');
  static String deletePlaylistQuestion(String name) => _t(
    'Delete “$name”? This cannot be undone.',
    'Xoá “$name”? Không thể hoàn tác.',
  );
  static String get delete => _t('Delete', 'Xoá');
  static String get findSongs => _t('Find songs', 'Tìm bài hát');
  static String get emptyPlaylistTitle =>
      _t('This playlist is empty', 'Danh sách phát này trống');
  static String get emptyPlaylistBody => _t(
    'Choose “Add to playlist” on any song to put it here.',
    'Chọn “Thêm vào danh sách phát” ở bất kỳ bài nào để đưa vào đây.',
  );
  static String get newFolder => _t('New folder', 'Thư mục mới');
  static String get folderName => _t('Folder name', 'Tên thư mục');
  static String folderSummary(int playlists, int songs) => _t(
    '${playlists == 1 ? '1 playlist' : '$playlists playlists'} · ${songCount(songs)}',
    '$playlists danh sách phát · ${songCount(songs)}',
  );
  static String get addPlaylists => _t('Add playlists', 'Thêm danh sách phát');
  static String get addPlaylistsHint => _t(
    'Pick the playlists to keep in this folder',
    'Chọn các danh sách phát để giữ trong thư mục này',
  );
  static String inFolder(String name) => _t('In $name', 'Trong $name');
  static String get noPlaylistsToAdd => _t(
    'Every playlist is in this folder already',
    'Mọi danh sách phát đã nằm trong thư mục này',
  );
  static String get moveToFolder => _t('Move to folder', 'Chuyển vào thư mục');
  static String get removeFromFolder =>
      _t('Remove from folder', 'Đưa ra khỏi thư mục');
  static String movedToFolder(String name) =>
      _t('Moved to $name', 'Đã chuyển vào $name');
  static String get deleteFolder => _t('Delete folder', 'Xoá thư mục');
  static String deleteFolderQuestion(String name) => _t(
    'Delete the folder “$name”? Its playlists are kept.',
    'Xoá thư mục “$name”? Các danh sách phát trong đó vẫn được giữ.',
  );
  static String get emptyFolderTitle =>
      _t('This folder is empty', 'Thư mục này trống');
  static String get emptyFolderBody => _t(
    'Add playlists to play them together, or to shuffle across them.',
    'Thêm danh sách phát để phát cùng nhau, hoặc trộn bài giữa chúng.',
  );
  static String get folderNoSongs =>
      _t('No songs in this folder yet', 'Chưa có bài nào trong thư mục này');
  static String playingSome(int kept, int total) => _t(
    'Playing $kept of $total songs, as many as a queue holds',
    'Đang phát $kept trên $total bài, số bài tối đa của một hàng đợi',
  );
  static String addedSome(int kept, int total) => _t(
    'Added $kept of $total songs, as many as the queue holds',
    'Đã thêm $kept trên $total bài, hàng đợi chỉ chứa được bấy nhiêu',
  );
  static String get saveAsPlaylist =>
      _t('Save as playlist', 'Lưu thành danh sách phát');
  static String get playlistSaved =>
      _t('Playlist saved', 'Đã lưu danh sách phát');
  static String get noLikedTitle =>
      _t('No liked songs yet', 'Chưa có bài nào được thích');
  static String get noLikedBody => _t(
    'Tap the heart on a song to keep it here.',
    'Chạm vào trái tim ở một bài để giữ nó ở đây.',
  );
  static String get noRecentTitle =>
      _t('Nothing played yet', 'Chưa nghe gì cả');
  static String get noRecentBody => _t(
    'Songs you listen to for a while show up here.',
    'Những bài bạn nghe được một lúc sẽ hiện ở đây.',
  );
  static String ago(Duration d) {
    if (d.inMinutes < 1) return _t('Just now', 'Vừa xong');
    if (d.inMinutes < 60) {
      return _t('${d.inMinutes} min ago', '${d.inMinutes} phút trước');
    }
    if (d.inHours < 24) {
      return _t('${d.inHours} h ago', '${d.inHours} giờ trước');
    }
    if (d.inDays == 1) return _t('Yesterday', 'Hôm qua');
    return _t('${d.inDays} days ago', '${d.inDays} ngày trước');
  }

  // Backup
  static String get backup => _t('Backup', 'Sao lưu');

  // Backup and sync (a library kept on the server, sealed with a key only the devices know)
  static String get syncTitle => _t('Backup & sync', 'Sao lưu và đồng bộ');
  static String get syncOffHelp => _t(
    'Keep your library safe and the same on all your devices. Encrypted: the server cannot read it.',
    'Giữ thư viện an toàn và giống nhau trên mọi máy. Đã mã hoá: máy chủ không đọc được.',
  );
  static String get syncTurnOn => _t('Turn on sync', 'Bật đồng bộ');
  static String get syncUseCode => _t('Use a code from another device', 'Dùng mã từ máy khác');
  static String get syncEnterCode => _t('Enter the code', 'Nhập mã');
  static String get syncCodeHint => _t('Code or link', 'Mã hoặc liên kết');
  static String get syncBadCode => _t('That is not a sync code', 'Đây không phải mã đồng bộ');
  static String get syncNoLibrary => _t('No library for this code', 'Không có thư viện nào cho mã này');
  static String get syncMergeQuestion => _t(
    'Add this device’s songs and playlists to the shared library? Nothing is removed.',
    'Thêm bài và danh sách phát của máy này vào thư viện chung? Không có gì bị xoá.',
  );
  static String get syncMerge => _t('Add', 'Thêm');
  static String get syncSyncing => _t('Syncing…', 'Đang đồng bộ…');
  static String get syncNotYet => _t('Not synced yet', 'Chưa đồng bộ');
  static String syncDone(String time, int devices) => _t(
    'Synced $time · $devices ${devices == 1 ? 'device' : 'devices'}',
    'Đã đồng bộ $time · $devices máy',
  );
  static String get syncOffline => _t('Offline, will try again', 'Không có mạng, sẽ thử lại');
  static String get syncRefusedKey => _t('The server refused the key', 'Khoá nhóm không đúng, chưa đồng bộ được');
  static String get syncUnavailable => _t('This server cannot sync', 'Máy chủ của nhóm chưa hỗ trợ đồng bộ');
  static String get syncTooBig => _t('The library is too big to sync', 'Thư viện quá lớn để đồng bộ');
  static String get syncTooOften => _t('Too many tries, wait a minute', 'Thử quá nhiều, đợi một phút');
  static String get syncFailed => _t('Sync failed', 'Đồng bộ lỗi');
  static String get syncNow => _t('Sync now', 'Đồng bộ ngay');
  static String syncPaused(int likes, int playlists) => _t(
    'Paused: this would remove ${_lostParts(likes, playlists, 'likes', 'playlists')}',
    'Tạm dừng: sẽ xoá ${_lostParts(likes, playlists, 'bài thích', 'playlist')}',
  );
  static String _lostParts(int likes, int playlists, String a, String b) =>
      [if (likes > 0) '$likes $a', if (playlists > 0) '$playlists $b'].join(', ');
  static String get syncContinue => _t('Continue', 'Tiếp tục');
  static String syncPausedQuestion(bool fromHere) => fromHere
      ? _t('Send these removals to your other devices?', 'Gửi các thay đổi xoá này sang máy khác?')
      : _t('Remove these from this device?', 'Xoá những mục này khỏi máy này?');
  static String get syncAddDevice => _t('Add a device', 'Thêm máy');
  static String get syncAddHelp => _t(
    'Scan with the camera, or enter the code in Backup & sync. Anyone with it can read and change your library.',
    'Quét bằng camera, hoặc nhập mã ở Sao lưu và đồng bộ. Ai có mã đều đọc và sửa được thư viện.',
  );
  static String get syncRecovery => _t('Recovery code', 'Mã khôi phục');
  static String get syncNotSaved => _t('Not saved', 'Chưa lưu');
  static String get syncRecoveryHelp => _t(
    'Save this code somewhere safe. If you lose every device without it, your library cannot be recovered.',
    'Hãy cất mã này ở nơi an toàn. Mất hết máy mà không có mã thì không lấy lại được thư viện.',
  );
  static String get syncCopy => _t('Copy', 'Chép');
  static String get syncShare => _t('Share', 'Chia sẻ');
  static String get syncSaved => _t('I saved it', 'Đã lưu');
  static String get syncCopied => _t('Copied', 'Đã chép');
  static String get syncRestore => _t('Restore an older copy', 'Khôi phục bản cũ');
  static String get syncNoCopies => _t('No older copies yet', 'Chưa có bản cũ');
  static String syncRestoreQuestion(String date) => _t(
    'Put back the library from $date on all your devices?',
    'Đưa thư viện ngày $date về mọi máy?',
  );
  static String get syncRestoreDo => _t('Restore', 'Khôi phục');
  static String get syncUndoFirst => _t('Go back to before sync', 'Về lại như trước khi đồng bộ');
  static String get syncUndoQuestion => _t(
    'Put this device’s library back as it was before the first sync, and turn sync off?',
    'Đưa thư viện máy này về như trước lần đồng bộ đầu và tắt đồng bộ?',
  );
  static String get syncTurnOff => _t('Turn off sync', 'Tắt đồng bộ');
  static String get syncTurnOffQuestion => _t(
    'Your library stays on this device. Delete the copy on the server too?',
    'Thư viện vẫn ở trên máy này. Xoá luôn bản trên máy chủ?',
  );
  static String get syncKeepCopy => _t('Keep the copy', 'Giữ bản trên máy chủ');
  static String get syncDeleteCopy => _t('Delete the copy', 'Xoá bản trên máy chủ');
  static String get syncCardTitle => _t('Keep your library safe?', 'Giữ thư viện an toàn?');
  static String get syncCardBody => _t(
    'Back it up and keep it the same on every device.',
    'Sao lưu và giữ giống nhau trên mọi máy.',
  );
  static String get syncCardAction => _t('Set up', 'Thiết lập');
  static String get syncCardLater => _t('Not now', 'Để sau');
  static String get backupSave =>
      _t('Save your library to a file', 'Lưu thư viện của bạn vào một tệp');
  static String get backupAdd =>
      _t('Add from a backup file', 'Thêm từ tệp sao lưu');
  static String get backupHelp => _t(
    'Saves your liked songs, playlists and listening history in one file.',
    'Lưu bài đã thích, danh sách phát và lịch sử nghe vào một tệp.',
  );
  static String get backupMore => _t(
    'Keep the file anywhere. Adding one never removes anything. Downloaded songs are not in it.',
    'Bạn cất tệp ở đâu cũng được. Thêm từ tệp sao lưu không bao giờ xoá gì. Bài đã tải không nằm trong đó.',
  );
  static String _backupParts(int liked, int playlists, int listens) => [
    if (liked > 0) _t('$liked liked', '$liked bài đã thích'),
    if (playlists > 0)
      _t(
        playlists == 1 ? '1 playlist' : '$playlists playlists',
        '$playlists danh sách phát',
      ),
    if (listens > 0) _t('$listens listens', '$listens lượt nghe'),
  ].join(', ');
  static String backupSaved(int liked, int playlists, int listens) => _t(
    'Saved: ${_backupParts(liked, playlists, listens)}',
    'Đã lưu: ${_backupParts(liked, playlists, listens)}',
  );
  static String backupAdded(int liked, int playlists, int listens) => _t(
    'Added: ${_backupParts(liked, playlists, listens)}',
    'Đã thêm: ${_backupParts(liked, playlists, listens)}',
  );
  static String get backupNothingNew =>
      _t('Nothing new in that file', 'Tệp đó không có gì mới');
  static String get backupEmpty => _t(
    'Saved, but there was nothing in your library yet',
    'Đã lưu, nhưng thư viện của bạn chưa có gì',
  );

  // The person's own name and picture
  static String get yourProfile => _t('Your profile', 'Hồ sơ của bạn');
  static String get choosePhoto => _t('Choose photo', 'Chọn ảnh');
  static String get removePhoto => _t('Remove photo', 'Bỏ ảnh');
  static String get photoOnlyHere => _t(
    'Others in a room see your photo too.',
    'Người trong phòng cũng thấy ảnh của bạn.',
  );

  // Suggestions: what the person does not want, and the mixes made from what they listen to
  static String get notInterested => _t('Not interested', 'Không quan tâm');
  static String get notInterestedSong =>
      _t('Don’t suggest this song', 'Không gợi ý bài này');
  static String notInterestedArtist(String artist) =>
      _t('Don’t suggest $artist', 'Không gợi ý $artist');
  static String get wontSuggest =>
      _t('Got it, we won’t suggest that again', 'Đã hiểu, sẽ không gợi ý lại');
  static String get suggestionsTitle => _t('Suggestions', 'Gợi ý');
  static String get tasteStatsHeading => _t('Last 30 days', '30 ngày qua');
  static String get tasteStatsHelp => _t(
    'How often a song was left in its first seconds, by where it came from.',
    'Tần suất một bài bị bỏ qua ngay những giây đầu, theo nguồn của bài.',
  );
  static String get tasteStatsNone => _t(
    'Not enough listening yet to compare.',
    'Chưa đủ lượt nghe để so sánh.',
  );
  static String tasteStatsAuto(int percent) =>
      _t('Autoplay songs skipped: $percent%', 'Bài tự động phát bị bỏ qua: $percent%');
  static String tasteStatsShelf(int percent) => _t(
    'Suggested songs skipped: $percent%',
    'Bài gợi ý bị bỏ qua: $percent%',
  );
  static String tasteStatsChosen(int percent) => _t(
    'Songs you picked skipped: $percent%',
    'Bài bạn chọn bị bỏ qua: $percent%',
  );
  static String get blockedHeading => _t('Not interested', 'Không quan tâm');
  static String get blockedHelp => _t(
    'Songs and artists you asked not to be offered. Tap one to offer it again.',
    'Những bài và nghệ sĩ bạn đã chọn không gợi ý. Chạm vào để được gợi ý lại.',
  );
  static String get blockedNone => _t(
    'Nothing here. Press and hold a song, or use its menu, to say you are not interested.',
    'Chưa có gì. Nhấn giữ một bài, hoặc dùng menu của bài, để chọn không quan tâm.',
  );
  static String get notCountedSong =>
      _t('Don’t count this in my taste', 'Không tính vào gu');
  static String suggestLessArtist(String artist) =>
      _t('Suggest less of $artist', 'Bớt gợi ý $artist');
  static String get wontCount => _t(
    'Got it, it won’t count',
    'Đã hiểu, sẽ không tính vào gu',
  );
  static String get willSuggestLess => _t(
    'Got it, fewer suggestions of this artist',
    'Đã hiểu, sẽ bớt gợi ý nghệ sĩ này',
  );
  static String get tasteHeading => _t('Your taste', 'Gu của bạn');
  static String get tasteHelp => _t(
    'The artists you listen to most. Suggest less of one, or block them.',
    'Những nghệ sĩ bạn nghe nhiều nhất. Có thể bớt gợi ý hoặc chặn một nghệ sĩ.',
  );
  static String get tasteNone => _t(
    'Listen to a few songs and your taste shows up here',
    'Nghe vài bài rồi gu của bạn sẽ hiện ở đây',
  );
  static String get tasteFewer => _t('Fewer suggestions', 'Bớt gợi ý');
  static String get suggestLess => _t('Suggest less', 'Bớt gợi ý');
  static String get blockArtist => _t('Block', 'Chặn');
  static String get tasteClustersHeading => _t('Tastes', 'Các cụm gu');
  static String get tasteClustersHelp => _t(
    'Artists you tend to listen to in the same sitting.',
    'Những nghệ sĩ bạn hay nghe trong cùng một lần.',
  );
  static String get shareTaste =>
      _t('Share my taste with the room', 'Chia sẻ gu với phòng');
  static String get shareTasteHelp => _t(
    'The device chosen to play on by itself will see a few songs you often listen to; in an encrypted room the server cannot read them.',
    'Máy được chọn để tự phát nhạc sẽ thấy vài bài bạn hay nghe; phòng mã hoá thì máy chủ không đọc được.',
  );
  static String get tasteMarksHeading =>
      _t('What you told the taste', 'Bạn đã chỉnh gu');
  static String get tasteMarksHelp => _t(
    'Tap one to take it off.',
    'Chạm vào để bỏ chỉnh.',
  );
  static String get tasteMarkArtist => _t('Fewer suggestions', 'Bớt gợi ý');
  static String get tasteMarkSong => _t('Not counted', 'Không tính');
  static String get tasteMarkStarter => _t('Starter', 'Bài khởi đầu');
  static String get removeMark => _t('Take off', 'Bỏ chỉnh');
  static String get pickArtists =>
      _t('Pick a few artists you like', 'Chọn vài nghệ sĩ bạn thích');
  static String get pickArtistsSearch =>
      _t('Search for an artist', 'Tìm nghệ sĩ');
  static String get pickArtistsStart => _t('Start', 'Bắt đầu');
  static String get pickArtistsNone => _t(
    'No artists to show right now. Try searching for one.',
    'Hiện chưa có nghệ sĩ nào để hiện. Hãy thử tìm một nghệ sĩ.',
  );
  static String get pickArtistsFailed => _t(
    'Could not load artists. Check the connection and try again.',
    'Không tải được danh sách nghệ sĩ. Kiểm tra kết nối rồi thử lại.',
  );
  static String get pickArtistsNothing => _t(
    'Could not start from those artists. Try others.',
    'Không bắt đầu được từ những nghệ sĩ này. Hãy thử nghệ sĩ khác.',
  );
  static String get discoverShelf =>
      _t('Try something new', 'Thử nghe cái mới');
  static String contextMix(String bucket) => switch (bucket) {
    'morning' => _t('Your morning mix', 'Mix buổi sáng của bạn'),
    'afternoon' => _t('Your afternoon mix', 'Mix buổi chiều của bạn'),
    'evening' => _t('Your evening mix', 'Mix buổi tối của bạn'),
    _ => _t('Your night mix', 'Mix ban đêm của bạn'),
  };

  // Where the sound goes
  static String get playOn => _t('Play on', 'Phát trên');
  static String get thisDevice => _t('This device', 'Máy này');
  static String get yourDevices => _t('Your devices', 'Máy của bạn');
  static String playingOn(String device) => _t('Playing on $device', 'Đang phát trên $device');
  static String playOnDevice(String device) => _t('Play on · $device', 'Phát trên · $device');
  static String movingTo(String device) => _t('Moving to $device…', 'Đang chuyển sang $device…');
  static String get movingHere => _t('Moving here…', 'Đang chuyển về máy này…');
  static String get devicesRecent => _t('Seen recently', 'Đã thấy gần đây');
  static String get deviceOffline => _t('Not here', 'Không có mạng');
  static String get forgetDevice => _t('Forget this device', 'Quên máy này');
  static String volumeOf(String device) => _t('Volume · $device', 'Âm lượng · $device');
  static String get deviceInRoom => _t('In a room', 'Đang ở phòng');
  static String get devicePlaying => _t('Playing', 'Đang phát');
  static String get connectNeedSync =>
      _t('Turn on sync to listen on your other devices.', 'Bật đồng bộ để nghe trên máy khác của bạn.');
  static String get connectTurnOnSync => _t('Turn on sync', 'Bật đồng bộ');
  static String get connectHint =>
      _t('Not here? Open Sapoche on that device.', 'Không thấy máy? Mở Sapoche trên máy đó.');
  static String get connectLooking => _t('Looking for your devices…', 'Đang tìm máy của bạn…');
  static String get connectRefused =>
      _t('This device cannot join: twelve at most, or another sync key.', 'Máy này không vào được: tối đa mười hai máy, hoặc khác khoá đồng bộ.');
  static String get connectOutput => _t('Sound output of this device', 'Đầu ra âm thanh của máy này');
  static String connectDropped(int n) => _t(
    n == 1 ? 'Left 1 song of this device behind' : 'Left $n songs of this device behind',
    'Bỏ $n bài chỉ có trên máy kia',
  );
  static String get connectName => _t('Name of this device', 'Tên của máy này');
  static String get connectRename => _t('Rename this device', 'Đổi tên máy này');

  // Sleep timer
  static String get sleepTimer => _t('Sleep timer', 'Hẹn giờ tắt');
  static String sleepMinutes(int minutes) => _t(
    minutes == 60
        ? '1 hour'
        : minutes > 60
        ? '1 hour ${minutes - 60} min'
        : '$minutes minutes',
    minutes == 60
        ? '1 giờ'
        : minutes > 60
        ? '1 giờ ${minutes - 60} phút'
        : '$minutes phút',
  );
  static String get sleepSongEnd => _t('End of this song', 'Hết bài này');
  static String get sleepCustom => _t('Another time…', 'Số phút khác…');
  static String get sleepCustomHint => _t('Minutes', 'Số phút');
  static String get sleepOff => _t('Turn off timer', 'Tắt hẹn giờ');
  static String get sleepInRoom => _t(
    'In a room only this phone stops; the room plays on without you.',
    'Trong phòng thì chỉ điện thoại này dừng; phòng vẫn phát tiếp mà không có bạn.',
  );
  static String sleepStopsAt(String time) =>
      _t('Stops at $time', 'Dừng lúc $time');
  static String get sleepStopsAfterSong =>
      _t('Stops after this song', 'Dừng sau bài này');
  static String sleepStatusAt(String time) =>
      _t('Music stops at $time', 'Nhạc tắt lúc $time');
  static String get sleepStatusSong =>
      _t('Music stops after this song', 'Nhạc tắt khi hết bài này');
  static String get sleepSongEndShort => _t('end of song', 'hết bài');
  static String sleepAround(String time) => '≈ $time';

  /// How long is left of a timer: "12 min left", "40 s left"; [clock] (2:31) for the end of a song.
  static String sleepLeft(Duration left, {bool clock = false}) {
    // Rounded up, as a countdown is: it says 0 only when it is over
    final seconds = left.isNegative ? 0 : (left.inMilliseconds + 999) ~/ 1000;
    if (clock) {
      final m = seconds ~/ 60;
      final s = (seconds % 60).toString().padLeft(2, '0');
      return _t('$m:$s left', 'còn $m:$s');
    }
    if (seconds < 60) return _t('$seconds s left', 'còn $seconds giây');
    final minutes = (seconds + 59) ~/ 60;
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return _t(
      h == 0
          ? '$minutes min left'
          : m == 0
          ? '$h h left'
          : '$h h $m min left',
      h == 0
          ? 'còn $minutes phút'
          : m == 0
          ? 'còn $h giờ'
          : 'còn $h giờ $m phút',
    );
  }

  /// The line of the sleep timer in a menu while one is set: "Sleep timer · 23:45".
  static String sleepTimerAt(String what) => '$sleepTimer · $what';

  // Player
  static String get buffering => _t('Loading…', 'Đang tải…');
  static String get inSync => _t('In sync', 'Cùng nhịp');
  static String get syncing => _t('Syncing…', 'Đang bắt nhịp…');
  static String get pausedHere =>
      _t('Paused here · room plays on', 'Đã dừng ở máy này · phòng vẫn phát');
  static String get catchingUp => _t('Catching up', 'Đang bắt kịp');
  static String get weakNetworkLabel => _t('Weak network', 'Mạng yếu');
  static String behindBy(String lag) => _t('$lag behind', 'chậm $lag');
  static String get soloOut => _t('Waiting for others', 'Đang đợi người khác');
  static String get onYourOwn => _t('On your own', 'Nghe riêng');
  static String get rejoin => _t('Rejoin', 'Nghe cùng lại');
  static String get soloBanner =>
      _t('You are listening on your own', 'Bạn đang nghe riêng');
  static String get keepPlaying => _t('Keep playing', 'Tiếp tục phát');
  static String get someone => _t('Someone', 'Ai đó');
  static String get chat => _t('Chat', 'Trò chuyện');
  static String get chatTheme => _t('Chat theme', 'Giao diện trò chuyện');
  static String get chatThemeShared =>
      _t('Everyone in the room sees it.', 'Cả phòng cùng thấy.');
  static String get chatThemeLocked => _t(
    'Only the owner can change it right now.',
    'Hiện chỉ chủ phòng đổi được.',
  );
  static String get chatThemeFromPhoto => _t('From a photo', 'Từ một ảnh');
  static String get chatThemeFromPhotoHint => _t(
    'Pick a photo, place it, and it goes behind the chat, blended with its colours. Everyone in the room gets the picture; choosing another look takes it away.',
    'Chọn một ảnh, căn chỉnh rồi đặt làm nền chat, hoà với màu của ảnh. Cả phòng nhận tấm ảnh này; chọn giao diện khác thì ảnh sẽ bị gỡ.',
  );
  static String get wallpaperTitle => _t('Fit the picture', 'Căn chỉnh ảnh');
  static String get wallpaperUse => _t('Use', 'Dùng');
  static String get wallpaperHint => _t(
    'Drag to move the picture, pinch or slide to zoom. Shown as the chat will look.',
    'Kéo để dời ảnh, chụm hoặc trượt để phóng. Hiển thị đúng như khung chat sẽ có.',
  );
  static String get wallpaperSaving =>
      _t('Getting the picture ready…', 'Đang chuẩn bị ảnh…');
  static String get wallpaperShowPhoto =>
      _t('Show the photo alone', 'Chỉ xem ảnh');
  static String get wallpaperShowBlend =>
      _t('Show it with the colours', 'Xem cùng màu hoà vào');
  static String get wallpaperSample1 =>
      _t('What shall we play next?', 'Mình nghe bài gì tiếp nhỉ?');
  static String get wallpaperSample2 =>
      _t('Something slow tonight', 'Bài nào nhẹ nhàng đi');
  static String get wallpaperSample3 => _t('Good idea', 'Hay đó');
  static String get chatThemeUnreadable =>
      _t('That photo could not be read', 'Không đọc được ảnh này');
  static String chatThemeName(String id) => switch (id) {
    'default' => _t('Classic', 'Mặc định'),
    'ocean' => _t('Ocean', 'Đại dương'),
    'sunset' => _t('Sunset', 'Hoàng hôn'),
    'forest' => _t('Forest', 'Rừng xanh'),
    'grape' => _t('Grape', 'Nho tím'),
    'honey' => _t('Honey', 'Mật ong'),
    'mono' => _t('Graphite', 'Than chì'),
    _ => _t('Your photo', 'Ảnh của bạn'),
  };
  static String chatFrom(String name, String text) =>
      '${name.isEmpty ? someone : name}: $text';
  static String get chatOpen => _t('Open', 'Mở');
  static String get chatHint => _t('Say something…', 'Nhắn gì đó…');
  static String get chatSend => _t('Send', 'Gửi');

  // Notices of the chat while the app is away
  static String get notices => _t('Notifications', 'Thông báo');
  static String get noticesOn => _t('On', 'Bật');
  static String get noticesOff => _t('Off', 'Tắt');
  static String get noticesSwitch => _t('Notify me of the chat', 'Thông báo khi có tin nhắn');
  static String get noticesSwitchHelp => _t(
    'Tells you of new messages while the app is not open.',
    'Báo khi có tin nhắn mới lúc bạn không mở app.',
  );
  static String get noticesSwitchMore => _t(
    'Answers and reactions to your messages too. Each room can be kept quiet from its chat.',
    'Gồm cả lời trả lời và cảm xúc cho tin của bạn. Mỗi phòng có thể tắt tiếng từ khung chat.',
  );
  static String get noticesPreview => _t('Show the message in the notice', 'Hiện nội dung tin trong thông báo');
  static String get noticesPreviewHelp => _t(
    'Off: the notice says only who wrote.',
    'Tắt: thông báo chỉ cho biết ai đã nhắn.',
  );
  static String get noticesDenied => _t(
    'Blocked. Allow notifications for Sapoche in the settings of the browser or the phone, then come back here.',
    'Đang bị chặn. Hãy cho phép thông báo cho Sapoche trong cài đặt của trình duyệt hoặc điện thoại, rồi quay lại đây.',
  );
  static String get noticesNeedInstall => _t(
    'On an iPhone, notifications come only once Sapoche is on the Home Screen: in Safari choose Share, then Add to Home Screen, and open it from there.',
    'Trên iPhone, thông báo chỉ có khi Sapoche nằm trên Màn hình chính: trong Safari chọn Chia sẻ, rồi Thêm vào Màn hình chính, và mở app từ đó.',
  );
  static String get noticesOffer => _t(
    'Get notified of new messages',
    'Nhận thông báo tin nhắn mới',
  );
  static String get noticesTurnOn => _t('Turn on', 'Bật');
  static String get noticesNotNow => _t('Not now', 'Để sau');
  static String get noticesMute => _t('Mute notifications of this room', 'Tắt tiếng thông báo của phòng này');
  static String get noticesMute1h => _t('For 1 hour', 'Trong 1 giờ');
  static String get noticesMute8h => _t('For 8 hours', 'Trong 8 giờ');
  static String get noticesMuteTomorrow => _t('Until tomorrow morning', 'Đến sáng mai');
  static String get noticesMuteAlways => _t('Until I turn them back on', 'Cho đến khi tôi bật lại');
  static String get noticesUnmute => _t('Turn notifications of this room back on', 'Bật lại thông báo của phòng này');

  static String get chatEmpty => _t('No messages yet', 'Chưa có tin nhắn nào');
  static String get chatEmptyBody => _t(
    'Say hi, or react to what is playing.',
    'Chào mọi người, hoặc thả cảm xúc cho bài đang phát.',
  );
  // End-to-end encrypted chat
  static String get encryptionTitle =>
      _t('End-to-end encrypted chat', 'Chat mã hoá đầu cuối');
  static String get encryptionOffHelp => _t(
    'Only people with the invitation link can read the messages and photos in the chat, not even the server. Room name, queue and profile pictures are not encrypted.',
    'Chỉ người có liên kết mời đọc được tin nhắn và ảnh trong chat, máy chủ cũng không. Tên phòng, hàng đợi và ảnh đại diện không được mã hoá.',
  );
  static String get encryptionOnHelp => _t(
    'Only people with the invitation link can read the messages and photos in the chat, not even the server; it cannot be turned off. Room name, queue and profile pictures are not encrypted.',
    'Chỉ người có liên kết mời đọc được tin nhắn và ảnh trong chat, máy chủ cũng không; không thể tắt. Tên phòng, hàng đợi và ảnh đại diện không được mã hoá.',
  );
  static String get encryptionShort => _t(
    'Only people with the invitation link can read it.',
    'Chỉ người có liên kết mời đọc được.',
  );
  static String get advanced => _t('Advanced', 'Nâng cao');
  static String get inviteEncryptedHint => _t(
    'Send the link or let them scan: someone who types the code cannot read the chat.',
    'Gửi liên kết hoặc cho quét mã: ai gõ mã thì không đọc được chat.',
  );
  static String get learnMore => _t('Learn more', 'Tìm hiểu thêm');
  static String get roomSettings => _t('Room settings', 'Cài đặt phòng');
  static String get encryptionTurnOn => _t('Turn on', 'Bật');
  static String get encryptionConfirmBody => _t(
    'The messages so far are deleted, and it cannot be turned off. Then send everyone the new invitation link; people on an old app must update.',
    'Tin cũ sẽ bị xoá, không tắt lại được. Sau đó gửi liên kết mời mới cho mọi người; ai dùng app cũ phải cập nhật.',
  );
  static String get encryptionTurnedOn => _t(
    'On. Send the new invitation link to everyone.',
    'Đã bật. Hãy gửi liên kết mời mới cho mọi người.',
  );
  static String get encryptionCannot => _t(
    'Could not turn it on',
    'Không bật được',
  );
  static String get encryptionNoKey => _t(
    'This device has no key for the chat of this room.',
    'Thiết bị này chưa có khoá của chat phòng này.',
  );
  static String get encryptionPaste =>
      _t('Paste invitation link', 'Dán liên kết mời');
  static String get encryptionPasteHint =>
      _t('Link with the key', 'Liên kết có khoá');
  static String get encryptionNotALink =>
      _t('That is not an invitation link', 'Đây không phải liên kết mời');
  static String get encryptionNoKeyInLink => _t(
    'That link has no key in it',
    'Liên kết này không có khoá',
  );
  static String get encryptionNeedsKey => _t(
    'You cannot read the messages yet. Ask someone in the room to send you the invitation link, then open it.',
    'Bạn chưa đọc được tin nhắn. Hãy nhờ người trong phòng gửi liên kết mời cho bạn, rồi mở nó.',
  );
  static String get chatLocked => _t('Cannot be read', 'Không đọc được');
  static String get linkCannotOpen =>
      _t('Could not open this link', 'Không mở được liên kết này');

  static String get chatNotSent =>
      _t('Not sent · tap to try again', 'Chưa gửi được · chạm để thử lại');
  static String get chatReply => _t('Reply', 'Trả lời');
  static String chatPhotoText(int count) => count == 1
      ? _t('📷 Photo', '📷 Ảnh')
      : _t('📷 $count photos', '📷 $count ảnh');
  static String get chatPhotosFull => _t(
    'This room is out of space for pictures',
    'Phòng tạm hết chỗ cho ảnh',
  );
  static String chatPhotoTooLarge(String name) => _t(
    '$name is too large to send (animated pictures can be 3 MB at most)',
    '$name quá lớn để gửi (ảnh động tối đa 3 MB)',
  );
  static String chatPhotoUnreadable(String name) => _t(
    '$name is not a picture that can be sent',
    '$name không phải ảnh có thể gửi',
  );
  static String get chatAddPhoto => _t('Add photos', 'Thêm ảnh');
  static String get chatAddSong => _t('Send a song', 'Gửi bài hát');
  static String get chatAddSticker => _t('Stickers', 'Nhãn dán');
  static String get chatKeyboard => _t('Keyboard', 'Bàn phím');
  static String get chatAttachMore => _t('More', 'Thêm');
  static String get stickerSearchHint =>
      _t('Search stickers', 'Tìm nhãn dán');
  static String get stickerSearchClear => _t('Clear', 'Xoá chữ');
  static String get stickerRecent => _t('Recent', 'Gần đây');
  static String get stickerRecentEmpty => _t(
    'The stickers you send show up here',
    'Nhãn dán bạn đã gửi sẽ hiện ở đây',
  );
  static String get stickerNoMatch =>
      _t('No stickers match', 'Không có nhãn dán phù hợp');
  static String get stickerNone => _t(
    'No sticker packs yet. Open the store to add some.',
    'Chưa có bộ nhãn dán nào. Mở cửa hàng để thêm.',
  );
  static String get stickerStore => _t('Sticker store', 'Cửa hàng nhãn dán');
  static String get stickerAddPack => _t('Add', 'Thêm');
  static String get stickerRemovePack => _t('Remove', 'Gỡ');
  static String get stickerDownload => _t('Download', 'Tải về');
  static String get stickerNotDownloaded =>
      _t('Not downloaded yet', 'Chưa tải về');
  static String stickerDownloading(int percent) =>
      _t('Downloading $percent%', 'Đang tải $percent%');
  static String stickerCount(int count) =>
      _t('$count stickers', '$count nhãn dán');
  static String get stickerStoreEmpty => _t(
    'The sticker store is not open right now',
    'Cửa hàng nhãn dán chưa mở được',
  );
  static String get stickerStoreEmptyBody => _t(
    'Check your connection and try again.',
    'Hãy kiểm tra kết nối rồi thử lại.',
  );
  static String stickerCredit(String name, String by, String license) => _t(
    'Art: $name by $by · $license',
    'Hình: $name của $by · $license',
  );
  static String get stickerLicenses =>
      _t('Open-source licenses', 'Giấy phép mã nguồn mở');
  static String get chatSongSearchHint =>
      _t('Search for a song', 'Tìm một bài hát');
  static String get chatSongNoResults =>
      _t('No songs found', 'Không tìm thấy bài hát');
  static String get chatSongSearchFailed => _t(
    'Could not search. Check your connection.',
    'Không tìm được. Hãy kiểm tra kết nối.',
  );
  static String get chatSongEmpty => _t(
    'Search for a song to send to the room',
    'Tìm một bài hát để gửi vào phòng',
  );
  static String get chatSongDrop =>
      _t('Do not send the song', 'Không gửi bài hát');
  static String get chatSongPlayNow => _t('Play now', 'Phát ngay');
  static String get chatSongPlaying => _t('Now playing', 'Đang phát');
  static String get chatSongQueued => _t('In the queue', 'Trong hàng đợi');
  static String get songSendToChat =>
      _t('Send to room chat', 'Gửi vào chat phòng');
  static String get songSentToChat =>
      _t('Sent to the chat', 'Đã gửi vào chat');
  static String get photoGallery => _t('Photo library', 'Thư viện ảnh');
  static String get photoFlip => _t('Flip left to right', 'Lật ngang');
  static String get videoGallery => _t('Video library', 'Thư viện video');
  static String get videoRecord => _t('Record a video', 'Quay video');
  static String get chatVideoText => _t('🎬 Video', '🎬 Video');
  static String get videoPreparing =>
      _t('Squeezing the video…', 'Đang nén video…');
  static String get chatNoMix => _t(
    'Photos and a video cannot go in the same message',
    'Ảnh và video không gửi chung một tin được',
  );
  static String chatVideoTooLarge(String name, bool squeezable) => squeezable
      ? _t(
          '$name is too long to fit in 10 MB, even squeezed',
          '$name quá dài để nén xuống 10 MB',
        )
      : _t(
          '$name is over 10 MB: squeeze it on your phone first',
          '$name nặng hơn 10 MB: hãy nén trên điện thoại trước',
        );
  static String chatVideoUnreadable(String name) => _t(
    '$name is not a video that can be sent',
    '$name không phải video có thể gửi',
  );
  static String get videoSave => _t('Save video', 'Lưu video');
  static String get videoSaved => _t('Video saved', 'Đã lưu video');
  static String get videoCannotPlay =>
      _t('This video cannot be played', 'Không phát được video này');
  static String get photoCamera => _t('Camera', 'Máy ảnh');
  static String get photoPreparing =>
      _t('Preparing photos…', 'Đang chuẩn bị ảnh…');
  static String get photoRemove => _t('Remove photo', 'Bỏ ảnh này');
  static String get chatPasteImage => _t('Paste image', 'Dán ảnh');
  static String chatAlbumFull(int max) => _t(
    'A message holds $max photos at most',
    'Một tin nhắn chứa tối đa $max ảnh',
  );
  static String photoCount(int count) => count == 1
      ? _t('1 photo', '1 ảnh')
      : _t('$count photos', '$count ảnh');
  static String get photoSave => _t('Save photo', 'Lưu ảnh');
  static String get photoSaveAll => _t('Save all photos', 'Lưu tất cả ảnh');
  static String get photoSaved => _t('Photo saved', 'Đã lưu ảnh');
  static String photosSaved(int count) => count == 1
      ? photoSaved
      : _t('$count photos saved', 'Đã lưu $count ảnh');
  static String get photoSaveFailed =>
      _t('Could not save the photo', 'Không lưu được ảnh');
  static String get photoSaveDenied => _t(
    'Allow access to your photos to save pictures',
    'Hãy cho phép truy cập ảnh để lưu ảnh',
  );
  static String get photoLoadFailed =>
      _t('This photo could not be loaded', 'Không tải được ảnh này');
  static String get chatCancelSend => _t('Cancel sending', 'Huỷ gửi');
  static String chatReplyingTo(String name) => _t(
    'Replying to ${name.isEmpty ? someone : name}',
    'Đang trả lời ${name.isEmpty ? someone : name}',
  );
  static String get chatReplyingToYourself =>
      _t('Replying to yourself', 'Đang trả lời chính mình');
  static String get chatCancelReply => _t('Cancel reply', 'Huỷ trả lời');
  static String get chatToNewest => _t('Latest messages', 'Tin nhắn mới nhất');
  static String get chatCopy => _t('Copy', 'Sao chép');
  static String get chatCopied => _t('Message copied', 'Đã sao chép tin nhắn');
  static String get chatReactions => _t('Reactions', 'Cảm xúc');
  static String get chatSending => _t('Sending…', 'Đang gửi…');
  static String get chatSent => _t('Sent', 'Đã gửi');
  static String get chatDelivered => _t('Delivered', 'Đã nhận');
  static String get chatSeen => _t('Seen', 'Đã xem');
  static String chatSeenBy(List<String> names, int others) {
    if (names.length >= others && others > 1) {
      return _t('Seen by everyone', 'Mọi người đã xem');
    }
    if (others <= 1) return chatSeen;
    final shown = names.take(2).join(', ');
    final more = names.length - 2;
    return _t(
      more > 0 ? 'Seen by $shown and $more more' : 'Seen by $shown',
      more > 0 ? '$shown và $more người khác đã xem' : '$shown đã xem',
    );
  }

  static String get react => _t('React', 'Thả cảm xúc');
  static String get reactMore => _t('More reactions', 'Thêm cảm xúc');
  static String get reactNoRecents =>
      _t('Nothing sent yet', 'Chưa gửi cảm xúc nào');
  static String get reactKeepTapping =>
      _t('Tap as many as you like', 'Chạm bao nhiêu lần tuỳ ý');
  static String get reactSearch => _t('Search emoji', 'Tìm cảm xúc');
  static String unreadMessages(int n) =>
      _t(n == 1 ? '1 unread message' : '$n unread messages', '$n tin chưa đọc');
  static String pausedBy(String name) =>
      _t('$name paused the room', '$name đã tạm dừng phòng');
  static String skippedBy(String name, String title) => _t(
    title.isEmpty ? '$name skipped ahead' : '$name switched to $title',
    title.isEmpty ? '$name đã chuyển bài' : '$name đã chuyển sang $title',
  );

  // Sound quality
  static String get soundSection => _t('Sound', 'Âm thanh');
  static String get audioQualityLow => _t('Low', 'Thấp');
  static String get audioQualityNormal => _t('Normal', 'Vừa');
  static String get audioQualityHigh => _t('High', 'Cao');
  static String get audioQualityMax => _t('Highest', 'Cao nhất');
  static String get audioQualityLowRate =>
      _t('about 22 MB an hour', 'khoảng 22 MB mỗi giờ');
  static String get audioQualityNormalRate =>
      _t('about 32 MB an hour', 'khoảng 32 MB mỗi giờ');
  static String get audioQualityHighRate =>
      _t('about 58 MB an hour', 'khoảng 58 MB mỗi giờ');
  static String get audioQualityMaxRate => _t('up to 72 MB an hour', 'đến 72 MB mỗi giờ');
  static String get audioQualityMaxRateIos =>
      _t('about 58 MB an hour', 'khoảng 58 MB mỗi giờ');
  static String get audioQualityHelp => _t(
    'Applies from the next song. On a weak network it drops by itself.',
    'Áp dụng từ bài sau. Mạng yếu thì tự hạ.',
  );
  static String get audioQualityMore => _t(
    'Without signing in, YouTube offers nothing higher. Songs already saved or downloaded keep their quality.',
    'Khi chưa đăng nhập, YouTube không có mức nào cao hơn. Bài đã lưu hoặc đã tải giữ chất lượng cũ.',
  );

  // Content advisory badge shown beside explicit tracks
  static String get explicit => _t('Explicit', 'Nội dung nhạy cảm');

  static String get normalizeVolume =>
      _t('Even out loudness', 'Cân bằng âm lượng');
  // Beside the switch, two lines at most; the rest is `normalizeVolumeHelp`, under the card
  static String get normalizeVolumeShort => _t(
    'Loud songs are turned down so that songs sound about equally loud.',
    'Bài to được hạ xuống để các bài nghe to bằng nhau.',
  );
  static String get normalizeVolumeHelp => _t(
    'Loud songs are turned down to the level YouTube plays them at; quiet ones stay as they are. Files on this phone are not changed.',
    'Bài to được hạ xuống mức YouTube vẫn phát; bài nhỏ giữ nguyên. Tệp trên máy không bị đổi.',
  );

  static String get crossfade => _t('Soft song change', 'Chuyển bài mềm');
  static String get crossfadeOff => _t('Off', 'Tắt');
  static String crossfadeSeconds(int seconds) =>
      _t('$seconds s', '$seconds giây');
  static String get crossfadeHelp => _t(
    'The end of a song fades out and the next fades in.',
    'Cuối bài nhỏ dần, đầu bài kế to dần.',
  );
  static String get crossfadeMore => _t(
    'They do not overlap, so a room stays in step. Not used for Next, short songs or video.',
    'Hai bài không chồng nhau nên cả phòng vẫn cùng nhịp. Không áp dụng khi bấm Bài sau, bài ngắn hoặc khi hiện video.',
  );

  static String get equalizer => _t('Equalizer', 'Bộ chỉnh âm');
  static String eqPreset(String id) => switch (id) {
    'off' => _t('Off', 'Tắt'),
    'bassBoost' => _t('Bass boost', 'Tăng bass'),
    'bassCut' => _t('Bass cut', 'Giảm bass'),
    'trebleBoost' => _t('Treble boost', 'Tăng treble'),
    'vocal' => _t('Vocal', 'Giọng hát'),
    'acoustic' => _t('Acoustic', 'Acoustic'),
    'electronic' => _t('Electronic', 'Điện tử'),
    _ => _t('Custom', 'Tuỳ chỉnh'),
  };
  static String get eqPresets => _t('Presets', 'Mẫu có sẵn');
  static String get eqBands => _t('Bands', 'Các dải');
  static String get eqReset => _t('Reset', 'Đặt lại');
  /// 60 Hz, 1 kHz, 2.4 kHz: a unit is not translated.
  static String eqBand(int hz) => hz >= 1000
      ? '${(hz / 1000).toString().replaceAll(RegExp(r'\.0$'), '')} kHz'
      : '$hz Hz';
  static String eqGain(int db) => db > 0 ? '+$db dB' : '$db dB';
  static String get eqSystem =>
      _t('Open the equalizer of this phone', 'Mở bộ chỉnh âm của điện thoại');
  static String get eqHelp => _t(
    'Six bands, up to 12 dB each way, on this phone only. Boosting turns the whole sound down a little first, so that it does not crackle.',
    'Sáu dải, mỗi chiều tối đa 12 dB, chỉ trên máy này. Khi tăng, cả bài được hạ nhẹ trước để không vỡ tiếng.',
  );
  static String get eqHelpIos => _t(
    'On iPhone only songs played from a file (downloaded or saved) go through it; videos do not.',
    'Trên iPhone chỉ bài phát từ tệp (đã tải hoặc đã lưu) đi qua bộ chỉnh âm; video thì không.',
  );

  // Scrobble: ListenBrainz and Last.fm
  static String get scrobbleTitle => 'Scrobble';
  static String get scrobbleTitleListenBrainz => 'ListenBrainz';
  static String get scrobbleNotConnected => _t('Not connected', 'Chưa kết nối');
  static String scrobbleConnectedAs(String user) =>
      _t('Connected as $user', 'Đã kết nối: $user');
  static String get scrobbleHelp => _t(
    'Sends the songs you play on this phone to your ListenBrainz account.',
    'Gửi các bài bạn nghe trên máy này lên tài khoản ListenBrainz.',
  );
  static String get scrobbleMore => _t(
    'Nothing is sent until you connect, and nothing about the room. Listens may be public there.',
    'Chưa kết nối thì không gửi gì, và không có gì về phòng. Lượt nghe có thể công khai ở đó.',
  );
  static String get scrobbleGetToken =>
      _t('Open ListenBrainz to get your token', 'Mở ListenBrainz để lấy token');
  static String get scrobbleEnterToken =>
      _t('Paste your token', 'Dán token của bạn');
  static String get scrobbleTokenHint => _t('User token', 'Token người dùng');
  static String get scrobbleConnecting => _t('Connecting…', 'Đang kết nối…');
  static String get scrobbleBadToken => _t(
    'That token is not valid. Copy it again from your ListenBrainz settings.',
    'Token không hợp lệ. Hãy sao chép lại từ trang cài đặt ListenBrainz của bạn.',
  );
  static String get scrobbleOffline => _t(
    'Could not reach ListenBrainz. Check the connection and try again.',
    'Không nối được tới ListenBrainz. Hãy kiểm tra kết nối rồi thử lại.',
  );
  static String get scrobbleReconnect => _t(
    'ListenBrainz refused the token. Paste it again to go on.',
    'ListenBrainz từ chối token. Hãy dán lại để tiếp tục.',
  );
  static String scrobblePending(int n) =>
      _t('Waiting to be sent: $n', 'Đang chờ gửi: $n');
  static String get scrobbleNowPlaying =>
      _t('Show what I am playing', 'Hiện bài đang nghe');
  static String get scrobbleNowPlayingHelp => _t(
    'The song that plays now shows on your ListenBrainz page a few seconds after it starts.',
    'Bài đang phát hiện trên trang ListenBrainz của bạn vài giây sau khi bắt đầu.',
  );
  static String get lastFmName => 'Last.fm';
  static String get lastFmHelp => _t(
    'Sends the songs you play on this phone to your Last.fm account. You allow it on the Last.fm page; no password is typed here.',
    'Gửi các bài bạn nghe trên máy này lên tài khoản Last.fm. Bạn cho phép trên trang Last.fm, không gõ mật khẩu ở đây.',
  );
  static String get lastFmMore => _t(
    'Nothing is sent until you connect, and nothing about the room. Your group\'s server signs for the app and keeps nothing.',
    'Chưa kết nối thì không gửi gì, và không có gì về phòng. Máy chủ của nhóm ký thay app và không lưu gì.',
  );
  static String get lastFmConnect => _t('Connect Last.fm', 'Kết nối Last.fm');
  static String get lastFmAllowed => _t('I have allowed it', 'Tôi đã cho phép');
  static String get lastFmWaiting => _t(
    'Allow Sapoche on the Last.fm page, then come back',
    'Hãy cho phép Sapoche trên trang Last.fm rồi quay lại',
  );
  static String get lastFmNotAllowedYet => _t(
    'Last.fm has not seen you allow it yet. Allow it on its page, then try again.',
    'Chưa thấy bạn cho phép trên Last.fm. Hãy cho phép trên trang đó rồi thử lại.',
  );
  static String get lastFmCannotOpen => _t(
    'Could not open the Last.fm page. Try again with a browser installed.',
    'Không mở được trang Last.fm. Hãy thử lại khi máy có trình duyệt.',
  );
  static String get lastFmExpired => _t(
    'That request has expired. Connect again.',
    'Yêu cầu đã hết hạn. Hãy kết nối lại.',
  );
  static String get lastFmUnavailable => _t(
    'Last.fm is not set up on this server.',
    'Máy chủ của nhóm chưa bật Last.fm.',
  );
  static String get lastFmOffline => _t(
    'Could not reach Last.fm. Check the connection and try again.',
    'Không nối được tới Last.fm. Hãy kiểm tra kết nối rồi thử lại.',
  );
  static String get lastFmReconnect => _t(
    'Last.fm no longer accepts this connection. Connect again to go on.',
    'Last.fm không còn nhận kết nối này. Hãy kết nối lại để tiếp tục.',
  );
  static String get lastFmNowPlayingHelp => _t(
    'The song that plays now shows on your Last.fm page a few seconds after it starts.',
    'Bài đang phát hiện trên trang Last.fm của bạn vài giây sau khi bắt đầu.',
  );
  static String get scrobbleDisconnect => _t('Disconnect', 'Ngắt kết nối');
  static String scrobbleDisconnectQuestion(int pending) => _t(
    '$pending listens have not been sent yet and will be dropped. Disconnect anyway?',
    '$pending lượt nghe chưa được gửi và sẽ bị bỏ. Vẫn ngắt kết nối?',
  );

  // Picture
  static String get modeAudio => _t('Audio', 'Âm thanh');
  static String get modeVideo => _t('Video', 'Video');
  static String get videoSection => _t('Video', 'Video');
  static String get videoQuality => _t('Picture quality', 'Chất lượng hình');
  static String get videoQualityHelp => _t(
    'Applies at once. On a slow connection it drops by itself.',
    'Áp dụng ngay. Mạng chậm thì hình tự hạ.',
  );
  static String get videoQualityMore => _t(
    'The song does not stop. Above 1080p only on Wi-Fi. The picture stops when the screen is off; the music does not.',
    'Bài không dừng. Trên 1080p chỉ khi có Wi-Fi. Tắt màn hình thì hình dừng, nhạc vẫn phát.',
  );
  static String get videoQualityHelpWeb => _t(
    'A higher quality applies at once; a lower one reloads the picture for a moment. A browser plays no picture below 480p.',
    'Cao hơn thì áp dụng ngay; thấp hơn thì hình tải lại một chút. Trình duyệt không phát hình dưới 480p.',
  );
  static String get videoApplyNow => _t(
    'Applies at once; the song keeps playing',
    'Áp dụng ngay, bài vẫn tiếp tục phát',
  );
  static String get videoApplyNowWeb => _t(
    'A higher quality applies at once; a lower one loads the picture again for a moment',
    'Lên cao hơn thì áp dụng ngay; xuống thấp hơn thì hình tải lại một chút',
  );
  static String get videoPlayingNow => _t('Playing now', 'Đang phát');
  static String get videoLimitMetered => _t(
    'On mobile data the picture is at most 1080p. Higher only on Wi-Fi.',
    'Đang dùng dữ liệu di động: hình tối đa 1080p. Cao hơn chỉ khi dùng Wi-Fi.',
  );
  static String get videoLimitMeteredNotice => _t(
    'On mobile data: the picture is at most 1080p',
    'Đang dùng dữ liệu di động: hình tối đa 1080p',
  );
  static String videoLimitVideo(int h) =>
      _t('This video has no more than ${h}p', 'Video này tối đa ${h}p');
  static String videoLimitNetwork(int h) => _t(
    'The network cannot carry more: playing ${h}p',
    'Mạng chưa đủ cho mức cao hơn: đang phát ${h}p',
  );
  static String get videoLimitReload =>
      _t('Loading the picture again…', 'Đang tải lại hình…');
  static String videoLimitDevice(int h) => _t(
    'This device plays pictures up to ${h}p',
    'Máy này phát hình tối đa ${h}p',
  );
  static String get pause => _t('Pause', 'Tạm dừng');
  static String get fullScreen => _t('Full screen', 'Toàn màn hình');
  static String get exitFullScreen =>
      _t('Exit full screen', 'Thoát toàn màn hình');
  static String get pictureInPicture => _t('Small window', 'Cửa sổ nổi');
  static String get videoSettings => _t('Video settings', 'Cài đặt video');
  static String get playbackSpeed => _t('Playback speed', 'Tốc độ phát');
  static String get speedNormal => _t('Normal', 'Bình thường');
  static String get speedInRoom => _t(
    'In a room everybody plays at normal speed, to stay in step.',
    'Trong phòng mọi người phát ở tốc độ thường để cùng nhịp.',
  );
  static String get previousSong => _t('Previous', 'Bài trước');
  static String get nextSong => _t('Next', 'Bài sau');
  static String get songPosition => _t('Song position', 'Vị trí trong bài');
  static String get back10 => _t('Back 10 seconds', 'Lùi 10 giây');
  static String get forward10 => _t('Forward 10 seconds', 'Tới 10 giây');
  static String seconds(int n) => _t('$n seconds', '$n giây');
  static String get fillScreen => _t('Fill the screen', 'Lấp đầy màn hình');
  static String get fitScreen => _t('Fit the screen', 'Vừa màn hình');

  // Who is in the room
  static String get membersTitle => _t('In the room', 'Trong phòng');
  static String get listenTogether => _t('Listen together', 'Nghe cùng nhau');
  static String get listenTogetherOn => _t(
    'Play, pause and skip apply to everyone in the room.',
    'Phát, tạm dừng và chuyển bài áp dụng cho mọi người trong phòng.',
  );
  static String get listenTogetherOff => _t(
    'You keep playing on your own. Your buttons only move you, and you can rejoin any time.',
    'Bạn tiếp tục nghe riêng. Các nút chỉ tác động đến bạn, và bạn nghe cùng lại được bất cứ lúc nào.',
  );
  static String get statusListening => _t('Listening', 'Đang nghe');
  static String get statusAlone => _t('On their own', 'Đang nghe riêng');
  static String get statusAway => _t('Connection lost', 'Mất kết nối');
  static String get viewPhoto => _t('View photo', 'Xem ảnh');
  static String get profileListeningTo => _t('Listening to', 'Đang nghe');
  static String get profileAloneNote => _t(
    'Listening on their own. What they play is not shared with the room.',
    'Đang nghe riêng. Bài họ nghe không được chia sẻ với phòng.',
  );
  static String get profileAwayNote => _t(
    'The connection was lost. They may be back soon.',
    'Mất kết nối. Có thể họ sẽ quay lại sớm.',
  );
  static String get profileNothing =>
      _t('Nothing is playing in the room', 'Phòng chưa phát bài nào');
  static String profileQueued(int n) => _t(
    n == 1 ? '1 song in the queue is theirs' : '$n songs in the queue are theirs',
    '$n bài trong hàng đợi do họ thêm',
  );
  static String profileApp(String? version) => _t(
    version == null ? 'App version: unknown (an older app)' : 'App version: $version',
    version == null ? 'Phiên bản app: chưa rõ (bản cũ hơn)' : 'Phiên bản app: $version',
  );
  static String get profileEdit => _t('Edit my profile', 'Sửa hồ sơ của tôi');
  static String get profileGone =>
      _t('They have left the room', 'Họ đã rời khỏi phòng');
  static String get statusLoading => _t('Loading…', 'Đang tải…');
  static String awayCount(int n) => _t('$n away', '$n mất kết nối');
  static String unplayable(String title) => _t(
    'Nobody could play “$title”. Skipped.',
    'Không ai phát được “$title”. Đã bỏ qua.',
  );

  // Why this device's own player has not started a song yet. Two lines: what happened in a few words, and what it means
  // for the person (whose fault it is, what the app does, what to do), so that waiting or skipping does not look like a
  // broken app
  static String loadHead(String code) => switch (code) {
    'load_slow' => _t('Still loading…', 'Vẫn đang tải…'),
    'load_offline' => _t('No internet', 'Không có mạng'),
    'load_skipped' || 'load_unplayable' => _t(
      'YouTube doesn’t provide this song',
      'YouTube không cung cấp bài này',
    ),
    'load_broken' => _t(
      'The connection keeps dropping',
      'Kết nối liên tục bị ngắt',
    ),
    _ => _t('Couldn’t load the song', 'Không tải được bài'),
  };
  static String loadDetail(String code, String title) => switch (code) {
    'load_slow' => _t(
      '“$title” is taking longer than usual because your connection is slow. The app keeps trying.',
      '“$title” tải lâu hơn bình thường vì mạng đang chậm. App vẫn đang thử.',
    ),
    'load_offline' => _t(
      'Press play to hear “$title” once you’re back online.',
      'Khi có mạng, bấm phát để nghe “$title”.',
    ),
    'load_skipped' => _t(
      '“$title” was removed, is private or is blocked where you are. Skipped to the next song. It is not a fault of your phone or the app.',
      '“$title” đã bị gỡ, để riêng tư hoặc bị chặn ở khu vực của bạn. Đã chuyển sang bài tiếp. Đây không phải lỗi của điện thoại hay app.',
    ),
    'load_unplayable' => _t(
      '“$title” is not available, and neither were the songs before it, so the app stopped skipping. Pick another song.',
      '“$title” không có, các bài trước đó cũng vậy nên app dừng lại, không bỏ qua nữa. Hãy chọn bài khác.',
    ),
    'load_broken' => _t(
      '“$title” would not play, even after trying again, so it was skipped. This usually means a weak or unstable connection.',
      '“$title” không phát được, thử lại vẫn vậy nên đã bỏ qua. Thường do mạng yếu hoặc chập chờn.',
    ),
    _ => _t(
      '“$title” did not load, usually because the connection is weak or unstable. Press play to try again.',
      '“$title” không tải được, thường do mạng yếu hoặc chập chờn. Bấm phát để thử lại.',
    ),
  };

  // Settings
  static String get settingsTitle => _t('Settings', 'Cài đặt');
  static String get appearance => _t('Appearance', 'Giao diện');
  static String get playback => _t('Playback', 'Phát nhạc');
  static String get noRoom => _t('Not in a room', 'Chưa vào phòng');
  static String get themeSystem => _t('System', 'Theo hệ thống');
  static String get themeLight => _t('Light', 'Sáng');
  static String get themeDark => _t('Dark', 'Tối');
  static String get tvLayout => _t('TV layout', 'Giao diện TV');
  static String get tvLayoutHelp => _t(
    'Bigger text and a menu for a remote, for a TV or a TV box. Automatic is on only where the device says it is a TV.',
    'Chữ to và menu cho điều khiển từ xa, dành cho TV hoặc TV box. Tự động chỉ bật khi thiết bị khai là TV.',
  );
  static String get tvAuto => _t('Automatic', 'Tự động');
  static String get tvOn => _t('On', 'Bật');
  static String get tvOff => _t('Off', 'Tắt');
  static String get playerStyle => _t('Player style', 'Kiểu trình phát');
  static String get playerStyleHelp => _t(
    'How the full player looks on this phone. The song bar and the small player stay as they are.',
    'Dáng của trình phát đầy đủ trên máy này. Thanh bài hát và trình phát nhỏ giữ nguyên.',
  );
  static String get playerStyleClassic => _t('Classic', 'Cổ điển');
  static String get playerStyleCards => _t('Cards', 'Thẻ');
  static String get playerStyleFullCover => _t('Full cover', 'Tràn bìa');
  static String get playerStyleClassicAbout => _t(
    'The cover in the middle, colours moving behind it',
    'Bìa ở giữa, màu trôi phía sau',
  );
  static String get playerStyleCardsAbout => _t(
    'Shuffle and repeat by the play button; lyrics, the artist, the queue and comments in cards below',
    'Xáo trộn và lặp cạnh nút phát; lời, nghệ sĩ, hàng đợi và bình luận thành thẻ bên dưới',
  );
  static String get playerStyleFullCoverAbout => _t(
    'The cover across the whole width, plain buttons, big lyrics',
    'Bìa tràn hết bề ngang, nút trơn, lời chữ to',
  );
  static String get accentColor => _t('Accent colour', 'Màu chủ đạo');
  static String get accentCustom => _t('Custom', 'Tùy chỉnh');
  static String get accentHue => _t('Hue', 'Sắc màu');
  static String get accentSaturation => _t('Saturation', 'Độ đậm');
  static String get accentBrightness => _t('Brightness', 'Độ sáng');
  static String get accentUse => _t('Use this colour', 'Dùng màu này');
  static String get accentHelp => _t(
    'Shades are adjusted so words stay easy to read. The icon of the app keeps its colour.',
    'Sắc màu được chỉnh để chữ luôn dễ đọc. Biểu tượng app giữ nguyên màu.',
  );
  static String accentName(String id) => switch (id) {
    'pink' => _t('Pink', 'Hồng'),
    'red' => _t('Red', 'Đỏ'),
    'orange' => _t('Orange', 'Cam'),
    'green' => _t('Green', 'Lá'),
    'teal' => _t('Teal', 'Ngọc'),
    'blue' => _t('Blue', 'Dương'),
    'purple' => _t('Purple', 'Tím'),
    _ => _t('Graphite', 'Than chì'),
  };
  static String get effectsTitle => _t('Effects', 'Hiệu ứng');
  static String get effectsFull => _t('Full', 'Đầy đủ');
  static String get effectsFullAbout => _t(
    'Frosted glass, moving colours and all animations',
    'Kính mờ, nền chuyển động và đủ hoạt ảnh',
  );
  static String get effectsLight => _t('Light', 'Nhẹ');
  static String get effectsLightAbout => _t(
    'Solid bars, still player background, quieter motion',
    'Thanh đặc, nền trình phát đứng yên, bớt hoạt ảnh',
  );
  static String get effectsMinimal => _t('Minimal', 'Tối giản');
  static String get effectsMinimalAbout => _t(
    'Instant pages and player, flat backgrounds, no blur or shadows',
    'Chuyển trang và trình phát tức thì, nền phẳng, bỏ mờ và bóng',
  );
  static String get effectsHelp => _t(
    'Picked for this device automatically until you choose one here.',
    'Tự chọn theo sức máy cho tới khi bạn tự chọn ở đây.',
  );
  static String get languageLabel => _t('Language', 'Ngôn ngữ');
  static String get languageSystem => _t('System', 'Theo hệ thống');
  static String get languageHelp => _t(
    'Songs and artists keep the names they have on YouTube Music.',
    'Bài hát và nghệ sĩ giữ nguyên tên trên YouTube Music.',
  );

  /// A language is always written in itself, so that it can be found whatever the app speaks now.
  static String languageName(String code) => switch (code) {
    'vi' => 'Tiếng Việt',
    _ => 'English',
  };
  static String get sync => _t('Timing in a room', 'Nhịp trong phòng');
  static String get latencyTrim => _t(
    'Latency trim',
    'Chỉnh sớm hoặc muộn',
  );
  static String get latencyTrimHelp => _t(
    'If this phone is always a little early or late compared with the others, nudge it here.',
    'Nếu điện thoại này luôn nhanh hoặc chậm hơn các máy khác một chút, hãy chỉnh ở đây.',
  );
  static String get latencyTrimHelpWeb => _t(
    'If this browser is always a little early or late compared with the others, nudge it here.',
    'Nếu trình duyệt này luôn nhanh hoặc chậm hơn các máy khác một chút, hãy chỉnh ở đây.',
  );
  static String get reset => _t('Reset', 'Đặt lại');
  static String get room => _t('Room', 'Phòng');
  static String get rename => _t('Rename', 'Đổi tên');
  static String get save => _t('Save', 'Lưu');
  static String get leaveRoom => _t('Leave room', 'Rời phòng');
  static String get leaveQuestion => _t(
    'Leave this room? You can join again with the code.',
    'Rời phòng này? Bạn vào lại được bằng mã.',
  );
  static String get leave => _t('Leave', 'Rời');
  static String get diagnosticsHelp => _t(
    'Recent events and errors, useful when something goes wrong.',
    'Sự kiện và lỗi gần đây, hữu ích khi có gì đó trục trặc.',
  );
  static String get logCopied => _t('Log copied', 'Đã sao chép nhật ký');

  // The log page (Settings > Diagnostics > Log)
  static String get logTitle => _t('Log', 'Nhật ký');
  static String get logClean =>
      _t('No errors in this run', 'Không có lỗi trong lần chạy này');
  static String get logErrors => _t('Errors', 'Lỗi');
  static String get logWarnings => _t('Warnings', 'Cảnh báo');
  static String get logMarks => _t('Marks', 'Đánh dấu');
  static String get logPreviousFailed => _t(
    'The run before this one ended badly',
    'Lần chạy trước kết thúc không êm',
  );
  static String get logShow => _t('Show', 'Xem');
  static String get logDevice => _t('This device', 'Máy này');
  static String get logModeMain => _t('Main', 'Chính');
  static String get logModeAll => _t('All', 'Tất cả');
  static String get logModeDetail => _t('Detail', 'Chi tiết');
  static String get logGroupPlay => _t('Playback', 'Phát nhạc');
  static String get logGroupRoom => _t('Room', 'Phòng');
  static String get logGroupNetwork => _t('Network', 'Mạng');
  static String get logGroupSystem => _t('System', 'Hệ thống');
  static String get logGroupUpdate => _t('Updates', 'Cập nhật');
  static String get logGroupUi => _t('Screen', 'Giao diện');
  static String get logGroupOther => _t('Other', 'Khác');
  static String get logSearch => _t('Search the log', 'Tìm trong nhật ký');
  static String get logSearchOpen => _t('Search', 'Tìm');
  static String get logSearchPrevious => _t('Previous match', 'Kết quả trước');
  static String get logSearchNext => _t('Next match', 'Kết quả sau');
  static String logRunStarted(String time, String? version) => _t(
    'Opened at $time${version == null ? '' : ' · version $version'}',
    'Mở app lúc $time${version == null ? '' : ' · bản $version'}',
  );
  static String get logEndRunning => _t('Running now', 'Đang chạy');
  static String get logEndNormal =>
      _t('Ended normally', 'Kết thúc bình thường');
  static String get logEndCrash => _t('Crashed', 'Bị sự cố (crash)');
  static String get logEndAnr => _t('Stopped responding', 'Bị treo (ANR)');
  static String get logEndKilled =>
      _t('Closed by the system', 'Bị hệ thống tắt');
  static String get logToday => _t('Today', 'Hôm nay');
  static String get logYesterday => _t('Yesterday', 'Hôm qua');
  static String logFolded(int count, String tag, String from, String to) => _t(
    '${count == 1 ? '1 line' : '$count lines'} [$tag] · $from–$to',
    '$count dòng [$tag] · $from–$to',
  );
  static String logHidden(int count) => _t(
    count == 1 ? '1 line hidden' : '$count lines hidden',
    '$count dòng ẩn',
  );
  static String get logNewLines => _t('New lines', 'Có dòng mới');
  static String get logPreviousError => _t('Previous error', 'Lỗi trước');
  static String get logNextError => _t('Next error', 'Lỗi sau');
  static String get logCopyLine => _t('Copy line', 'Sao chép dòng');
  static String get logShowAround =>
      _t('Show around this line', 'Xem quanh dòng này');
  static String get logAround => _t('Lines around it', 'Các dòng quanh nó');
  static String get logMark => _t('Mark', 'Đánh dấu');
  static String get logMarkTitle =>
      _t('Mark this moment', 'Đánh dấu thời điểm này');
  static String get logMarkHelp => _t(
    'Something went wrong? Mark it now and send the log later: whoever reads it finds the moment at once.',
    'Vừa gặp lỗi? Đánh dấu ngay, gửi nhật ký lúc nào cũng được: người đọc tìm thấy đúng thời điểm.',
  );
  static String get logMarkHint =>
      _t('Note (optional)', 'Ghi chú (không bắt buộc)');
  static String get logMarked => _t('Marked', 'Đã đánh dấu');
  static String get logShare => _t('Share file', 'Chia sẻ tệp');
  static String get logShareFailed =>
      _t('Could not share the file', 'Không chia sẻ được tệp');
  static String get logCopyShort =>
      _t('Copy short version', 'Sao chép bản ngắn');
  static String get logClear => _t('Clear log', 'Xoá nhật ký');
  static String get logClearQuestion => _t('Clear the log?', 'Xoá nhật ký?');
  static String get logClearHelp => _t(
    'The lines written so far are deleted from this device.',
    'Các dòng đã ghi sẽ bị xoá khỏi máy này.',
  );
  static String get logEmpty =>
      _t('Nothing worth noting', 'Chưa có gì đáng chú ý');
  static String get logShowAll => _t('Show all', 'Xem tất cả');
  static String get logPickLine => _t(
    'Pick a line to read it in full',
    'Chọn một dòng để đọc đủ',
  );
  static String get logMore => _t('More', 'Thêm');

  // Full player: lyrics, queue, song and artist pages
  static String get lyrics => _t('Lyrics', 'Lời bài hát');
  static String get showCover => _t('Back to the cover', 'Về ảnh bìa');
  static String get volume => _t('Volume', 'Âm lượng');
  static String get noLyrics =>
      _t('No lyrics for this song', 'Bài này chưa có lời');
  static String get lyricsFailed =>
      _t('Couldn’t load the lyrics', 'Không tải được lời bài hát');
  static String get musicFailed =>
      _t('Couldn’t reach YouTube Music', 'Không kết nối được YouTube Music');
  static String get tryAgain => _t('Try again', 'Thử lại');
  static String get songInfo => _t('Song info', 'Thông tin bài hát');
  static String get goToArtist => _t('Go to artist', 'Đến trang nghệ sĩ');
  static String get suggested => _t('Suggested', 'Gợi ý');
  static String get roomAutoplayQueued => _t(
    'After your queue; the songs you add go first.',
    'Phát sau hàng đợi; bài bạn thêm vẫn được phát trước.',
  );
  // One line beside the heading, where the full explanation (`autoplayHelp`) is in Settings
  static String get autoplayShort =>
      _t('plays after your queue', 'phát sau hàng đợi của bạn');
  static String get roomAutoplayShort =>
      _t('plays after the room\'s queue', 'phát sau hàng đợi của phòng');
  static String get nothingAfter =>
      _t('Nothing is queued after this song.', 'Không có bài nào sau bài này.');
  static String get youMightAlsoLike =>
      _t('You might also like', 'Có thể bạn cũng thích');
  static String get otherPerformances =>
      _t('Other performances', 'Các bản trình diễn khác');
  static String get similarArtists => _t('Similar artists', 'Nghệ sĩ tương tự');
  static String get show => _t('Show', 'Hiện');
  static String get aboutArtist => _t('About the artist', 'Về nghệ sĩ');
  static String get topSongs => _t('Top songs', 'Bài hát hàng đầu');
  static String get fansAlsoLike =>
      _t('Fans might also like', 'Người hâm mộ cũng có thể thích');
  static String get infoArtist => _t('Artist', 'Nghệ sĩ');
  static String get infoAlbum => _t('Album', 'Album');
  static String get infoYear => _t('Year', 'Năm');
  static String get infoLength => _t('Length', 'Thời lượng');
  static String get infoReach => _t('Reach', 'Lượt xem');
  static String get infoKind => _t('Version', 'Phiên bản');
  static String get addedByLabel => _t('Added by', 'Người thêm');
  static String get infoPlays => _t('Plays', 'Lượt phát');
  static String get decimalSeparator => _t('.', ',');
  static String get unitThousand => _t('K', ' N');
  static String get unitMillion => _t('M', ' Tr');
  static String get unitBillion => _t('B', ' Tỷ');
  static String viewCount(String n) => _t('$n views', '$n lượt xem');
  static String playCount(String n) => _t('$n plays', '$n lượt phát');
  static String likeCount(String n) => _t('$n likes', '$n lượt thích');
  static String get infoLikes => _t('Likes', 'Lượt thích');

  // YouTube comments in the full player (read only)
  static String get comments => _t('Comments', 'Bình luận');
  static String get youtubeComments =>
      _t('YouTube comments', 'Bình luận YouTube');
  static String get commentsTop => _t('Top', 'Hàng đầu');
  static String get commentsNewest => _t('Newest', 'Mới nhất');
  static String get commentsOff =>
      _t('Comments are turned off for this song', 'Bài này đã tắt bình luận');
  static String get commentsNone =>
      _t('No comments yet', 'Chưa có bình luận nào');
  static String get commentsFailed =>
      _t('Couldn’t load the comments', 'Không tải được bình luận');
  static String get commentsPinned => _t('Pinned', 'Đã ghim');
  static String get commentsCreator => _t('Creator', 'Chủ kênh');
  static String get commentsReadMore => _t('Read more', 'Xem thêm');
  static String get commentsReadLess => _t('Show less', 'Thu gọn');
  static String get commentsOpenOnYoutube =>
      _t('Comment on YouTube', 'Bình luận trên YouTube');
  static String commentReplies(String n) =>
      _t(n == '1' ? '1 reply' : '$n replies', '$n phản hồi');
  static String get commentsHideReplies =>
      _t('Hide replies', 'Ẩn phản hồi');
  static String get commentsMoreReplies =>
      _t('Show more replies', 'Xem thêm phản hồi');
  static String get kindSong => _t('Song', 'Bài hát');
  static String get kindVideo => _t('Video', 'Video');
  static String get goToAlbum => _t('Go to album', 'Đến trang album');
  static String get shareSong => _t('Share', 'Chia sẻ');
  static String get noAlbum => _t('This song is not on an album', 'Bài này không có trong album nào');
  static String get seeAll => _t('See all', 'Xem tất cả');
  static String get albums => _t('Albums', 'Album');
  static String get singlesAndEps => _t('Singles & EPs', 'Đĩa đơn & EP');

  /// What YouTube calls a page of songs, in the language of the app; a word it does not know is left as it is.
  static String collectionKind(String kind) => switch (kind) {
    'Album' => _t('Album', 'Album'),
    'Single' => _t('Single', 'Đĩa đơn'),
    'EP' => 'EP',
    'Playlist' => _t('Playlist', 'Danh sách phát'),
    _ => kind,
  };

  /// The name of a row of a page as YouTube gives it (in English); the ones that are always there are translated.
  static String shelfTitle(String title) => switch (title) {
    'Videos' => _t('Videos', 'Video'),
    'Live performances' => _t('Live performances', 'Biểu diễn trực tiếp'),
    'Featured on' => _t('Featured on', 'Xuất hiện trong'),
    'Playlists' => playlists,
    'Video charts' => _t('Charts', 'Bảng xếp hạng'),
    'Top artists' => _t('Top artists', 'Nghệ sĩ hàng đầu'),
    _ => title,
  };
  static String get showMore => _t('More', 'Xem thêm');
  static String get showLess => _t('Less', 'Thu gọn');
  static String subscribers(String count) =>
      _t('$count subscribers', '$count người đăng ký');

  // Home
  static String get goodMorning => _t('Good morning', 'Chào buổi sáng');
  static String get goodAfternoon => _t('Good afternoon', 'Chào buổi chiều');
  static String get goodEvening => _t('Good evening', 'Chào buổi tối');
  static String get quickPicks => _t('Quick picks', 'Chọn nhanh');
  static String get listenAgain => _t('Listen again', 'Nghe lại');
  static String get mixedForYou => _t('Mixed for you', 'Mix dành cho bạn');
  static String get forgottenFavorites =>
      _t('Forgotten favorites', 'Bài yêu thích đã lâu không nghe');
  static String get trending => _t('Trending', 'Thịnh hành');
  static String mixOf(String artist) => _t('$artist Mix', 'Mix $artist');
  static String get madeForYou => _t('Made for you', 'Dành riêng cho bạn');
  static String dailyMix(int number) => _t('Mix $number', 'Mix $number');

  /// The artists of a mix on one line: the first two, and that there are more when there are.
  static String mixArtists(List<String> artists) => switch (artists.length) {
    0 => '',
    1 => artists[0],
    2 => _t(
      '${artists[0]} and ${artists[1]}',
      '${artists[0]} và ${artists[1]}',
    ),
    _ => _t(
      '${artists[0]}, ${artists[1]} and more',
      '${artists[0]}, ${artists[1]} và những nghệ sĩ khác',
    ),
  };
  static String chipContext(String bucket) => switch (bucket) {
    'morning' => _t('Morning mix', 'Mix buổi sáng'),
    'afternoon' => _t('Afternoon mix', 'Mix buổi chiều'),
    'evening' => _t('Evening mix', 'Mix buổi tối'),
    _ => _t('Night mix', 'Mix ban đêm'),
  };
  static String get chipForgotten => _t('Long unheard', 'Lâu rồi chưa nghe');
  static String get chipNew => _t('Something new', 'Thử cái mới');
  static String get artistRadio =>
      _t('Radio from your artists', 'Radio từ nghệ sĩ của bạn');
  static String get latestFromArtists =>
      _t('Latest from your artists', 'Mới nhất từ nghệ sĩ của bạn');
  static String get moodFailed => _t(
    'This mood could not be loaded.',
    'Không tải được danh sách theo tâm trạng này.',
  );
  static String becauseYouListened(String title) =>
      _t('Because you listened to $title', 'Vì bạn đã nghe $title');
  static String similarTo(String artist) =>
      _t('Similar to $artist', 'Tương tự $artist');
  static String get homeEmptyTitle =>
      _t('Your music starts here', 'Âm nhạc của bạn bắt đầu từ đây');
  static String get homeEmptyBody => _t(
    'Play some songs and this page fills with what you like: quick picks, mixes and more.',
    'Hãy nghe vài bài và trang này sẽ đầy những gì bạn thích: chọn nhanh, mix và hơn thế nữa.',
  );
  static String get listenWithFriends =>
      _t('Listen with friends', 'Nghe cùng bạn bè');
  static String get fromYouTubeMusic =>
      _t('From YouTube Music', 'Từ YouTube Music');
  static String get mixFailed =>
      _t('Couldn’t start the mix', 'Không bắt đầu được mix');

  // Updates of the app
  static String get updates => _t('Updates', 'Cập nhật');
  static String get releaseNotes =>
      _t('Release notes', 'Lịch sử bản phát hành');
  static String get releaseNotesNew => _t('New', 'Mới');
  static String get releaseNotesUpdateHint => _t(
    'These are in a newer version than the one on this phone: install it under Updates.',
    'Những điều này nằm ở bản mới hơn bản trên máy: cài ở mục Cập nhật.',
  );
  static String get releaseNotesInstalled => _t('Installed', 'Đang dùng');
  static String get releaseNotesOlder =>
      _t('Show older versions', 'Xem bản cũ hơn');
  static String get releaseNotesNone =>
      _t('The notes could not be read', 'Không đọc được ghi chú');
  static String get serverSection => _t('Server', 'Máy chủ');
  static String get serverAddress => _t('Address', 'Địa chỉ');
  static String get serverKey => _t('Group key', 'Khoá nhóm');
  static String get webKeyTitle => _t(
    'Enter the group key to start',
    'Nhập khoá nhóm để bắt đầu',
  );
  static String get webKeyHint => _t(
    'Group key, or the link copied from the Android app',
    'Khoá nhóm, hoặc liên kết chép từ app Android',
  );
  static String get webKeyMissing =>
      _t('No group key yet', 'Chưa có khoá nhóm');
  static String get webKeyEnter => _t('Enter', 'Nhập');
  static String get keyRefused => _t(
    'The group key was not accepted. Ask whoever set Sapoche up for you, or check it in Settings > Advanced > Server.',
    'Khoá nhóm không đúng. Hãy nhờ người đã cài Sapoche cho bạn, hoặc kiểm tra ở Cài đặt > Nâng cao > Máy chủ.',
  );
  static String get serverKeySet => _t('Set', 'Đã đặt');
  static String get serverKeyNotSet => _t('Not set', 'Chưa đặt');
  static String get libraryLostTitle =>
      _t('The library could not be opened', 'Không mở được thư viện');
  static String get libraryLostBody => _t(
    'What you change now will not be saved when the app closes. Do not restore a backup yet: restart the app first.',
    'Thay đổi bây giờ sẽ không được lưu khi tắt app. Đừng khôi phục sao lưu lúc này: hãy khởi động lại app trước.',
  );
  static String get checkConnectionRow =>
      _t('Check the connection', 'Kiểm tra kết nối');
  static String get checkingConnection =>
      _t('Checking…', 'Đang kiểm tra…');
  static String get checkServerReached =>
      _t('The server answers', 'Máy chủ có trả lời');
  static String get checkServerUnreachable => _t(
    'The server does not answer. Check the network, then the address.',
    'Máy chủ không trả lời. Hãy kiểm tra mạng, rồi đến địa chỉ.',
  );
  static String get checkKeyOk => _t('The group key is accepted', 'Khoá nhóm được chấp nhận');
  static String get checkKeyRefused => _t(
    'The group key is not accepted',
    'Khoá nhóm không được chấp nhận',
  );
  static String get checkKeyUnknown =>
      _t('The group key could not be tried', 'Chưa thử được khoá nhóm');
  static String checkVersionOk(int protocol) => _t(
    'The server is up to date (protocol $protocol)',
    'Máy chủ đủ mới (giao thức $protocol)',
  );
  static String checkVersionOld(int protocol, int needed) => _t(
    'The server needs an update (protocol $protocol, needs $needed). Tell whoever runs your group.',
    'Máy chủ cần cập nhật (giao thức $protocol, cần $needed). Hãy báo người quản lý nhóm.',
  );
  static String get checkVersionUnknown =>
      _t('The server version is not known', 'Chưa biết phiên bản máy chủ');
  static String get serverHelp => _t(
    'The address of your Sapoche server and the group key. Easiest: on a phone that already works, open Settings > Connect another phone and scan the code.',
    'Địa chỉ máy chủ và khoá nhóm, chỉ nằm trên máy này. Dễ nhất: trên máy đã dùng được, mở Cài đặt > Kết nối máy khác rồi quét mã.',
  );
  static String get serverHelpWeb => _t(
    'Where your Sapoche server is and the group key it asks for. They stay in this browser: clearing the site’s data removes them.',
    'Địa chỉ máy chủ Sapoche của bạn và khoá nhóm nó yêu cầu. Chúng chỉ nằm trong trình duyệt này: xoá dữ liệu của trang là mất.',
  );
  static String get setupAnother =>
      _t('Connect another phone', 'Kết nối máy khác');
  static String get setupAnotherHelp => _t(
    'On the other phone, open the camera and point it at this code. Or copy the link and send it to that phone. Show it only to people in your group.',
    'Trên máy kia, mở camera và đưa vào mã này. Hoặc sao chép liên kết rồi gửi sang máy kia. Chỉ cho người trong nhóm xem mã.',
  );
  static String get setupAnotherWeb => _t('Invite to the web app', 'Mời bạn dùng bản web');
  static String get setupAnotherWebHelp => _t(
    'Whoever opens this link, or points a phone camera at this code, is in at once with no key to type. It holds the group key: send it only to people in your group.',
    'Ai mở liên kết này, hoặc đưa camera điện thoại vào mã này, là vào thẳng và không phải gõ khoá. Liên kết chứa khoá nhóm: chỉ gửi cho người trong nhóm của bạn.',
  );
  static String get setupCopy => _t('Copy link', 'Sao chép liên kết');
  static String get setupCopied => _t('Link copied', 'Đã sao chép liên kết');
  static String get setupNone => _t(
    'This phone has no server to share',
    'Máy này chưa có máy chủ để chia sẻ',
  );
  static String get setupPaste =>
      _t('Paste the group link', 'Dán liên kết của nhóm');
  static String get setupNeededTitle =>
      _t('Set up the server first', 'Cần thiết lập máy chủ trước');
  static String get setupNeededBody => _t(
    'On a phone where Sapoche already works, open Settings > Connect another phone and point this phone\'s camera at the code. Or paste the link that phone sends you.',
    'Trên máy đã dùng được Sapoche, mở Cài đặt > Kết nối máy khác rồi đưa camera máy này vào mã. Hoặc dán liên kết máy đó gửi cho bạn.',
  );
  static String get setupEnterByHand =>
      _t('Enter address and key', 'Nhập địa chỉ và khoá');
  static String get setupUseTitle =>
      _t('Use this server?', 'Dùng máy chủ này?');
  static String setupUseBody(String host) => _t(
    'Rooms will be made on $host, with the group key from the link.',
    'Phòng sẽ được tạo trên $host, với khoá nhóm trong liên kết.',
  );
  static String get setupUse => _t('Use', 'Dùng');
  static String get setupBad => _t(
    'That is not a Sapoche group link. Ask someone in your group to send it again.',
    'Đây không phải liên kết nhóm Sapoche. Hãy nhờ người trong nhóm gửi lại.',
  );
  static String get setupDone => _t('Server set', 'Đã đặt máy chủ');
  static String get serverNotSet => _t(
    'Enter the server address and group key first (Settings > Advanced > Server).',
    'Hãy nhập địa chỉ máy chủ và khoá nhóm trước (Cài đặt > Nâng cao > Máy chủ).',
  );
  static String get updateVersion => _t('Version', 'Phiên bản');
  static String get updateUpToDate =>
      _t('Sapoche is up to date', 'Sapoche đã là bản mới nhất');
  static String get updateCheck => _t('Check for updates', 'Kiểm tra cập nhật');
  static String get updateChecking => _t('Checking…', 'Đang kiểm tra…');
  static String updateAvailable(String version) =>
      _t('Version $version is available', 'Đã có phiên bản $version');
  static String updateReady(String version) => _t(
    'Version $version is ready to install',
    'Phiên bản $version đã sẵn sàng để cài',
  );
  static String get updateDownload => _t('Download', 'Tải về');
  static String get updateDownloading => _t('Downloading…', 'Đang tải…');
  static String get updateInstall => _t('Install', 'Cài');
  static String get updateInstalling => _t('Installing…', 'Đang cài…');
  static String get updateRestartTitle =>
      _t('Install the update?', 'Cài bản cập nhật?');
  static String get updateRestartBody => _t(
    'Sapoche closes to install it and opens again afterwards. Music stops, and a room is joined again when the app is back.',
    'Sapoche sẽ đóng để cài và mở lại sau đó. Nhạc sẽ dừng, và nếu đang trong phòng thì app tự vào lại khi mở.',
  );
  static String get updatePermission => _t(
    'Android asks you to allow Sapoche to install updates, once. Allow it on the page that opens, then come back and press Install.',
    'Android yêu cầu bạn cho phép Sapoche cài cập nhật, chỉ một lần. Hãy bật ở trang sắp mở, rồi quay lại và bấm Cài.',
  );
  static String get updatePermissionTitle =>
      _t('Allow installing updates', 'Cho phép cài bản cập nhật');
  static String get updatePermissionBody => _t(
    'Android needs you to allow Sapoche to install updates, once. On the next page turn on “Allow from this source”, then come back and press Install.',
    'Android cần bạn cho phép Sapoche cài bản mới, chỉ một lần. Ở trang sắp mở, bật “Cho phép từ nguồn này”, rồi quay lại và bấm Cài.',
  );
  static String get updateOpenSettings => _t('Open settings', 'Mở cài đặt');
  static String get updateWhatsNew => _t('What’s new', 'Có gì mới');
  static String updateSheetReady(String version) => _t(
    'Sapoche $version is ready',
    'Sapoche $version đã sẵn sàng',
  );
  static String updateSheetAvailable(String version) =>
      _t('Sapoche $version is out', 'Đã có Sapoche $version');
  static String get updateSheetStops => _t(
    'Music stops for a moment while it installs.',
    'Nhạc sẽ dừng một lúc khi cài.',
  );
  static String get updateNow => _t('Update now', 'Cập nhật ngay');
  static String get updateOpenRelease =>
      _t('Open the download page', 'Mở trang tải');
  static String get updateViaSideStore => _t(
    'Open the page, then update Sapoche in SideStore.',
    'Mở trang tải rồi cập nhật Sapoche trong SideStore.',
  );
  static String get webNewVersion => _t(
    'A new version of Sapoche is out. Reloading stops the music for a moment.',
    'Đã có bản Sapoche mới. Tải lại sẽ làm nhạc dừng một lúc.',
  );
  static String get webReload => _t('Reload', 'Tải lại');
  static String get autoUpdate =>
      _t('Update automatically', 'Tự động cập nhật');
  static String get autoUpdateHelp => _t(
    'Looks for new versions on Wi-Fi and installs one when nothing is playing, no room is joined and the app is closed.',
    'Tự tìm bản mới khi có Wi-Fi và cài khi không có nhạc đang phát, không ở trong phòng và app đang đóng.',
  );
  static String get updateLater => _t('Later', 'Để sau');
  static String get updateTryAgain => _t('Try again', 'Thử lại');
  static String updateError(String? code) => switch (code) {
    'unreachable' => _t(
      'Couldn’t reach the server to look for updates.',
      'Không kết nối được máy chủ để tìm cập nhật.',
    ),
    'key' => _t(
      'The server turned the group key down, or this phone has none yet. Set it in Settings > Advanced > Server.',
      'Máy chủ từ chối khoá nhóm, hoặc máy này chưa có khoá. Hãy đặt ở Cài đặt > Nâng cao > Máy chủ.',
    ),
    'download' => _t(
      'The download didn’t work. Try again.',
      'Tải không được. Hãy thử lại.',
    ),
    'signature' => _t(
      'This update is signed with a different key, so Android won’t install it over this app. Ask whoever set Sapoche up for you.',
      'Bản cập nhật này ký bằng khoá khác nên Android không cho cài đè lên app này. Hãy nhờ người đã cài Sapoche cho bạn.',
    ),
    'old' => _t(
      'That version is not newer than the one installed.',
      'Phiên bản đó không mới hơn bản đang cài.',
    ),
    'package' => _t(
      'That file is not an update of Sapoche.',
      'Tệp đó không phải bản cập nhật của Sapoche.',
    ),
    'aborted' => _t(
      'The installation was cancelled.',
      'Việc cài đã bị huỷ.',
    ),
    'blocked' => _t(
      'Android blocked the installation.',
      'Android đã chặn việc cài.',
    ),
    'storage' => _t(
      'There is not enough room on the phone to install it.',
      'Điện thoại không đủ dung lượng để cài.',
    ),
    _ => _t(
      'The update couldn’t be installed.',
      'Không cài được bản cập nhật.',
    ),
  };
}
