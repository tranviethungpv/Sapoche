import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'update_info.dart';

/// What the person sees of updating the app. The checking, downloading and installing are done natively.
class UpdateController extends ChangeNotifier {
  UpdateController(this._backend) {
    _subscription = _backend.events.listen((event) {
      if (event is UpdateEvent) {
        _info = event.info;
        notifyListeners();
      }
    });
  }

  final Backend _backend;
  late final StreamSubscription<BackendEvent> _subscription;
  UpdateInfo _info = const UpdateInfo();

  UpdateInfo get info => _info;

  Future<void> check() => _backend.updateCheck();

  /// False when mobile data is in use and the person has not agreed to it yet.
  Future<bool> download({bool allowMetered = false}) =>
      _backend.updateDownload(allowMetered: allowMetered);

  /// False when Android has to be told to allow this app to install first.
  Future<bool> install() => _backend.updateInstall();

  Future<void> allowInstalls() => _backend.updateAllowInstalls();

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
