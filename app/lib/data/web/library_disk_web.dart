import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'library_store.dart';

/// The library in the IndexedDB of the browser: one record in one store. Unlike the `localStorage` that holds the small
/// settings it has no limit of a few megabytes, and its writes do not stop the page.
class IndexedDbDisk implements LibraryDisk {
  IndexedDbDisk({this.name = 'sapoche', this.key = 'library'});

  final String name;
  final String key;
  static const _store = 'documents';

  Future<web.IDBDatabase> _open() {
    final done = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(name, 1);
    request.onupgradeneeded = ((web.Event _) {
      (request.result as web.IDBDatabase).createObjectStore(_store);
    }).toJS;
    request.onsuccess = ((web.Event _) => done.complete(request.result as web.IDBDatabase)).toJS;
    request.onerror = ((web.Event _) => done.completeError(StateError('IndexedDB would not open: ${request.error?.message}'))).toJS;
    return done.future;
  }

  Future<T> _run<T>(String mode, web.IDBRequest Function(web.IDBObjectStore store) ask, T Function(JSAny? result) read) async {
    final db = await _open();
    try {
      final done = Completer<T>();
      final request = ask(db.transaction(_store.toJS, mode).objectStore(_store));
      request.onsuccess = ((web.Event _) => done.complete(read(request.result))).toJS;
      request.onerror = ((web.Event _) => done.completeError(StateError('IndexedDB failed: ${request.error?.message}'))).toJS;
      return await done.future;
    } finally {
      db.close();
    }
  }

  @override
  Future<String?> read() => _run('readonly', (s) => s.get(key.toJS), (r) => (r as JSString?)?.toDart);

  @override
  Future<void> write(String json) => _run('readwrite', (s) => s.put(json.toJS, key.toJS), (_) {});
}
