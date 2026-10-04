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
    'Cùng nghe nhạc, đồng bộ từng nhịp.',
  );

  // Welcome
  static String get yourName => _t('Your name', 'Tên của bạn');
  static String get createRoom => _t('Create a room', 'Tạo phòng');
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
  static String get nowPlaying => _t('Now Playing', 'Đang phát');
  static String get upNext => _t('Up Next', 'Tiếp theo');
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
  static String get upNextShuffled =>
      _t('Up Next shuffled', 'Đã trộn các bài tiếp theo');
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
  static String get clearQueue => _t('Clear queue', 'Xóa hàng đợi');
  static String get clearQueueQuestion =>
      _t('Remove every song from the queue?', 'Xóa mọi bài khỏi hàng đợi?');
  static String get clear => _t('Clear', 'Xóa');
  static String get cancel => _t('Cancel', 'Hủy');
  static String get close => _t('Close', 'Đóng');
  static String addedBy(String name) => _t('Added by $name', '$name đã thêm');
  static String get you => _t('You', 'Bạn');
  static String get copyCode => _t('Copy code', 'Sao chép mã');
  static String get codeCopied =>
      _t('Room code copied', 'Đã sao chép mã phòng');
  static String get removed => _t('Removed from queue', 'Đã xóa khỏi hàng đợi');
  static String get invite => _t('Invite friends', 'Mời bạn bè');
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
    'This build is not allowed on the server',
    'Bản cài này không được phép dùng máy chủ',
  );

  // Search
  static String get searchHint => _t(
    'Videos, songs, or a YouTube link',
    'Video, bài hát hoặc liên kết YouTube',
  );
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
  static String get searchFailed => _t(
    'Search failed. Check your connection.',
    'Tìm kiếm không được. Hãy kiểm tra kết nối.',
  );
  static String get playlistAdded =>
      _t('Playlist added', 'Đã thêm danh sách phát');
  static String get playNext => _t('Play next', 'Phát tiếp theo');
  static String get addToQueue => _t('Add to queue', 'Thêm vào hàng đợi');
  static String get addedToQueue =>
      _t('Added to queue', 'Đã thêm vào hàng đợi');
  static String get willPlayNext => _t('Playing next', 'Sẽ phát tiếp theo');
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
  static String get removeDownload => _t('Remove download', 'Xóa bản tải');
  static String get downloading => _t('Downloading…', 'Đang tải…');
  static String get downloadAll => _t('Download all', 'Tải tất cả');
  static String get downloadedSongs => _t('Downloaded', 'Đã tải');
  static String downloadStarted(int n) => _t(
    n == 1 ? 'Downloading 1 song' : 'Downloading $n songs',
    'Đang tải $n bài',
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
  static String get deleteAll => _t('Delete all', 'Xóa tất cả');
  static String get deleteDownloadsQuestion => _t(
    'Remove every downloaded song from this phone?',
    'Xóa mọi bài đã tải khỏi điện thoại này?',
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
  static String get cacheLimit =>
      _t('Size for played songs', 'Dung lượng cho bài đã nghe');
  static String get cacheLimitHelp => _t(
    'Songs you listened to are kept so that they play again without using data. The oldest go first when it is full. A new size counts from the next time the app starts.',
    'Bài đã nghe được giữ lại để phát lại mà không tốn dữ liệu. Khi đầy thì bài cũ nhất bị xóa trước. Dung lượng mới có hiệu lực từ lần mở app sau.',
  );
  static String get autoDownload =>
      _t('Download liked songs', 'Tải bài đã thích');
  static String get autoDownloadHelp => _t(
    'Saves your liked songs by itself on Wi-Fi while the phone is charging.',
    'Tự lưu các bài đã thích khi có Wi-Fi và điện thoại đang sạc.',
  );
  static String get clearCache => _t('Clear', 'Xóa');

  // Suggestions
  static String get forYou => _t('For you', 'Dành cho bạn');
  static String get recentSearches => _t('Recent searches', 'Tìm kiếm gần đây');
  static String get autoplay => _t('Autoplay', 'Tự động phát');
  static String get autoplayHelp => _t(
    'When your queue runs out, keep playing songs like the last one.',
    'Khi hàng đợi hết, tiếp tục phát những bài giống bài vừa rồi.',
  );

  // Library
  static String get likedSongs => _t('Liked songs', 'Bài đã thích');
  static String get recentlyPlayed => _t('Recently played', 'Nghe gần đây');
  static String songCount(int n) =>
      _t(n == 1 ? '1 song' : '$n songs', '$n bài');
  static String get like => _t('Like', 'Thích');
  static String get unlike => _t('Unlike', 'Bỏ thích');
  static String get play => _t('Play', 'Phát');
  static String get clearHistory => _t('Clear history', 'Xóa lịch sử');
  static String get clearHistoryQuestion => _t(
    'Remove everything from your listening history? Liked songs are kept.',
    'Xóa toàn bộ lịch sử nghe? Các bài đã thích vẫn được giữ.',
  );
  static String get playlists => _t('Playlists', 'Danh sách phát');
  static String get newPlaylist => _t('New playlist', 'Danh sách phát mới');
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
      _t('Delete playlist', 'Xóa danh sách phát');
  static String deletePlaylistQuestion(String name) => _t(
    'Delete “$name”? This cannot be undone.',
    'Xóa “$name”? Không thể hoàn tác.',
  );
  static String get delete => _t('Delete', 'Xóa');
  static String get emptyPlaylistTitle =>
      _t('This playlist is empty', 'Danh sách phát này trống');
  static String get emptyPlaylistBody => _t(
    'Choose “Add to playlist” on any song to put it here.',
    'Chọn “Thêm vào danh sách phát” ở bất kỳ bài nào để đưa vào đây.',
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
  static String get backupSave =>
      _t('Save your library to a file', 'Lưu thư viện của bạn vào một tệp');
  static String get backupAdd =>
      _t('Add from a backup file', 'Thêm từ tệp sao lưu');
  static String get backupHelp => _t(
    'A backup keeps your liked songs, playlists and listening history in one file you can put anywhere. '
        'Adding one never removes anything. Downloaded songs are not in it.',
    'Bản sao lưu giữ bài đã thích, danh sách phát và lịch sử nghe trong một tệp, bạn cất ở đâu cũng được. '
        'Thêm từ tệp sao lưu không bao giờ xóa gì. Bài đã tải không nằm trong đó.',
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
    'Others in a room see your photo too. A room that runs an older server only shows your initial.',
    'Người trong phòng cũng thấy ảnh của bạn. Phòng chạy server cũ thì chỉ thấy chữ cái đầu.',
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
  static String get blockedHeading => _t('Not interested', 'Không quan tâm');
  static String get blockedHelp => _t(
    'Songs and artists you asked not to be offered. Tap one to offer it again.',
    'Những bài và nghệ sĩ bạn đã chọn không gợi ý. Chạm vào để được gợi ý lại.',
  );
  static String get blockedNone => _t(
    'Nothing here. Press and hold a song, or use its menu, to say you are not interested.',
    'Chưa có gì. Nhấn giữ một bài, hoặc dùng menu của bài, để chọn không quan tâm.',
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
  static String get thisPhone => _t('This phone', 'Điện thoại này');

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
  static String get sleepOff => _t('Turn off timer', 'Tắt hẹn giờ');
  static String get sleepInRoom => _t(
    'In a room only this phone stops; the room plays on without you.',
    'Trong phòng thì chỉ điện thoại này dừng; phòng vẫn phát tiếp mà không có bạn.',
  );
  static String sleepStopsAt(String time) =>
      _t('Stops at $time', 'Dừng lúc $time');
  static String get sleepStopsAfterSong =>
      _t('Stops after this song', 'Dừng sau bài này');

  // Player
  static String get buffering => _t('Loading…', 'Đang tải…');
  static String get inSync => _t('In sync', 'Đã đồng bộ');
  static String get syncing => _t('Syncing…', 'Đang đồng bộ…');
  static String get catchingUp => _t('Catching up', 'Đang bắt kịp');
  static String get soloOut => _t('Waiting for others', 'Đang đợi người khác');
  static String get onYourOwn => _t('On your own', 'Nghe riêng');
  static String get rejoin => _t('Rejoin', 'Nghe cùng lại');
  static String get soloBanner =>
      _t('You are listening on your own', 'Bạn đang nghe riêng');
  static String get keepPlaying => _t('Keep playing', 'Tiếp tục phát');
  static String get someone => _t('Someone', 'Ai đó');
  static String pausedBy(String name) =>
      _t('$name paused the room', '$name đã tạm dừng phòng');
  static String skippedBy(String name, String title) => _t(
    title.isEmpty ? '$name skipped ahead' : '$name switched to $title',
    title.isEmpty ? '$name đã chuyển bài' : '$name đã chuyển sang $title',
  );

  // Picture
  static String get modeAudio => _t('Audio', 'Âm thanh');
  static String get modeVideo => _t('Video', 'Video');
  static String get videoSection => _t('Video', 'Video');
  static String get videoQuality => _t('Picture quality', 'Chất lượng hình');
  static String get videoQualityHelp => _t(
    'Applies from the next song. Higher quality uses more data. Music keeps playing when the screen is off; the picture does not.',
    'Áp dụng từ bài sau. Chất lượng cao hơn tốn nhiều dữ liệu hơn. Nhạc vẫn phát khi tắt màn hình; hình thì không.',
  );

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
  static String get statusLoading => _t('Loading…', 'Đang tải…');
  static String awayCount(int n) => _t('$n away', '$n mất kết nối');
  static String unplayable(String title) => _t(
    'Nobody could play “$title”. Skipped.',
    'Không ai phát được “$title”. Đã bỏ qua.',
  );

  // Settings
  static String get settingsTitle => _t('Settings', 'Cài đặt');
  static String get appearance => _t('Appearance', 'Giao diện');
  static String get playback => _t('Playback', 'Phát nhạc');
  static String get noRoom => _t('Not in a room', 'Chưa vào phòng');
  static String get themeSystem => _t('System', 'Theo hệ thống');
  static String get themeLight => _t('Light', 'Sáng');
  static String get themeDark => _t('Dark', 'Tối');
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
  static String get sync => _t('Sync', 'Đồng bộ');
  static String get latencyTrim => _t('Latency trim', 'Chỉnh độ trễ');
  static String get latencyTrimHelp => _t(
    'If this phone is always a little early or late compared with the others, nudge it here.',
    'Nếu điện thoại này luôn nhanh hoặc chậm hơn các máy khác một chút, hãy chỉnh ở đây.',
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
    'Recent events, useful when something goes wrong.',
    'Các sự kiện gần đây, hữu ích khi có gì đó trục trặc.',
  );
  static String get copyLog => _t('Copy log', 'Sao chép nhật ký');
  static String get logCopied => _t('Log copied', 'Đã sao chép nhật ký');

  // Full player: lyrics, queue, related songs, song and artist pages
  static String get lyrics => _t('Lyrics', 'Lời bài hát');
  static String get related => _t('Related', 'Liên quan');
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
  static String get autoplayNote => _t(
    'Similar songs keep playing when the queue runs out.',
    'Những bài tương tự sẽ tiếp tục phát khi hàng đợi hết.',
  );
  static String get nothingAfter =>
      _t('Nothing is queued after this song.', 'Không có bài nào sau bài này.');
  static String get youMightAlsoLike =>
      _t('You might also like', 'Có thể bạn cũng thích');
  static String get otherPerformances =>
      _t('Other performances', 'Các bản trình diễn khác');
  static String get similarArtists => _t('Similar artists', 'Nghệ sĩ tương tự');
  static String get aboutArtist => _t('About the artist', 'Về nghệ sĩ');
  static String get nothingRelated => _t(
    'Nothing related to this song was found',
    'Không tìm thấy gì liên quan đến bài này',
  );
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
  static String get kindSong => _t('Song', 'Bài hát');
  static String get kindVideo => _t('Video', 'Video');
  static String get goToAlbum => _t('Go to album', 'Đến trang album');
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
  static String get mixFailed =>
      _t('Couldn’t start the mix', 'Không bắt đầu được mix');

  // Updates of the app
  static String get updates => _t('Updates', 'Cập nhật');
  static String get serverSection => _t('Server', 'Máy chủ');
  static String get serverAddress => _t('Address', 'Địa chỉ');
  static String get serverKey => _t('Room key', 'Khoá phòng');
  static String get serverKeySet => _t('Set', 'Đã đặt');
  static String get serverKeyNotSet => _t('Not set', 'Chưa đặt');
  static String get serverHelp => _t(
    'Where your Sapoche server is and the key it asks for. They stay on this phone and are not part of the app. Easiest: on a phone that already works, open Settings > Set up another phone, and point this phone’s camera at the code.',
    'Địa chỉ máy chủ Sapoche của bạn và khoá nó yêu cầu. Chúng chỉ nằm trên máy này, không nằm trong ứng dụng. Dễ nhất: trên máy đã dùng được, mở Cài đặt > Cài đặt cho máy khác, rồi đưa camera của máy này vào mã.',
  );
  static String get setupAnother =>
      _t('Set up another phone', 'Cài đặt cho máy khác');
  static String get setupAnotherHelp => _t(
    'Open the camera on the other phone and point it at this code, or copy the link and send it to yourself. It holds the server address and the room key: show it to nobody else.',
    'Mở camera trên máy kia và đưa vào mã này, hoặc sao chép liên kết rồi gửi cho chính bạn. Mã chứa địa chỉ máy chủ và khoá phòng: đừng cho ai khác xem.',
  );
  static String get setupCopy => _t('Copy link', 'Sao chép liên kết');
  static String get setupCopied => _t('Link copied', 'Đã sao chép liên kết');
  static String get setupNone => _t(
    'This phone has no server to share',
    'Máy này chưa có máy chủ để chia sẻ',
  );
  static String get setupPaste =>
      _t('Paste setup link', 'Dán liên kết cài đặt');
  static String get setupUseTitle =>
      _t('Use this server?', 'Dùng máy chủ này?');
  static String setupUseBody(String host) => _t(
    'Rooms will be made on $host, with the key from the link.',
    'Phòng sẽ được tạo trên $host, với khoá trong liên kết.',
  );
  static String get setupUse => _t('Use', 'Dùng');
  static String get setupBad => _t(
    'That is not a Sapoche setup link.',
    'Đó không phải liên kết cài đặt của Sapoche.',
  );
  static String get setupDone => _t('Server set', 'Đã đặt máy chủ');
  static String get serverNotSet => _t(
    'Enter the server address and key first (Settings > Server).',
    'Hãy nhập địa chỉ máy chủ và khoá trước (Cài đặt > Máy chủ).',
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
  static String get updateInstall => _t('Install', 'Cài đặt');
  static String get updateInstalling => _t('Installing…', 'Đang cài…');
  static String get updateRestartTitle =>
      _t('Install the update?', 'Cài bản cập nhật?');
  static String get updateRestartBody => _t(
    'Sapoche closes to install it and opens again afterwards. Music stops, and a room is joined again when the app is back.',
    'Sapoche sẽ đóng để cài và mở lại sau đó. Nhạc sẽ dừng, và nếu đang trong phòng thì app tự vào lại khi mở.',
  );
  static String get updatePermission => _t(
    'Android asks you to allow Sapoche to install updates, once. Allow it on the page that opens, then come back and press Install.',
    'Android yêu cầu bạn cho phép Sapoche cài cập nhật, chỉ một lần. Hãy bật ở trang sắp mở, rồi quay lại và bấm Cài đặt.',
  );
  static String get updatePermissionTitle =>
      _t('Allow installing updates', 'Cho phép cài bản cập nhật');
  static String get updatePermissionBody => _t(
    'To install an update, Android needs you to allow Sapoche to install apps. It asks once: turn on “Allow from this source” on the next page, then come back and press Install again.',
    'Để cài bản cập nhật, Android cần bạn cho phép Sapoche cài ứng dụng. Chỉ hỏi một lần: hãy bật “Cho phép từ nguồn này” ở trang sắp mở, rồi quay lại và bấm Cài đặt lần nữa.',
  );
  static String get updateOpenSettings => _t('Open settings', 'Mở cài đặt');
  static String get updateWhatsNew => _t('What’s new', 'Có gì mới');
  static String get updateTryAgain => _t('Try again', 'Thử lại');
  static String updateError(String? code) => switch (code) {
    'unreachable' => _t(
      'Couldn’t reach the server to look for updates.',
      'Không kết nối được máy chủ để tìm cập nhật.',
    ),
    'download' => _t(
      'The download didn’t work. Try again.',
      'Tải không được. Hãy thử lại.',
    ),
    'signature' => _t(
      'This update is signed with a different key, so Android won’t install it over this app.',
      'Bản cập nhật này ký bằng khóa khác nên Android không cho cài đè lên app này.',
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
      'Việc cài đặt đã bị hủy.',
    ),
    'blocked' => _t(
      'Android blocked the installation.',
      'Android đã chặn việc cài đặt.',
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
