import 'dart:js_interop';

import 'package:web/web.dart' as web;

typedef BrowserStorage = ({int usage, int quota, bool persistent});

/// Null when the browser has no storage manager, or will not say.
Future<BrowserStorage?> browserStorage() async {
  try {
    final manager = web.window.navigator.storage;
    final estimate = await manager.estimate().toDart;
    final persistent = (await manager.persisted().toDart).toDart;
    return (
      usage: estimate.usage,
      quota: estimate.quota,
      persistent: persistent,
    );
  } catch (_) {
    return null;
  }
}

/// Asks the browser not to clear the library when the device runs short of space. Whether it agrees is its choice.
Future<bool> keepBrowserStorage() async {
  try {
    return (await web.window.navigator.storage.persist().toDart).toDart;
  } catch (_) {
    return false;
  }
}
