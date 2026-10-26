import 'dart:ui_web' as ui_web;

import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/widgets.dart';

import '../../data/web/video_frame_element.dart';

const _viewType = 'sapoche-video-frame';
bool _registered = false;

/// The one view of the page that holds the player of YouTube, built once and never taken out of the tree again: a frame
/// that is moved in the DOM loads again, and the player would lose it.
Widget buildVideoFrame() {
  if (!_registered) {
    _registered = true;
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => videoFrameElement());
  }
  return const HtmlElementView(
    viewType: _viewType,
    hitTestBehavior: PlatformViewHitTestBehavior.transparent,
  );
}

void lookOfVideoFrame({required bool hidden, required bool crop}) {
  videoFrameElement().classList
    ..toggle('hidden', hidden)
    ..toggle('crop', crop);
}
