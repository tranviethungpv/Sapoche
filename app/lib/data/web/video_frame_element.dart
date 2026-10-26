import 'package:web/web.dart' as web;

web.HTMLElement? _element;

/// The element that holds the frame of the YouTube player. It stays `empty` (not shown, so that the cover under it
/// is) until the player has a song loaded in it. The page shows it through a view of the app
/// (`ui/widgets/video_frame_web.dart`); the player puts its frame inside.
web.HTMLElement videoFrameElement() => _element ??= (web.document.createElement('div') as web.HTMLElement)
  ..className = 'sapoche-frame hidden empty'
  // Flutter wants the size said on the element itself
  ..style.width = '100%'
  ..style.height = '100%';
