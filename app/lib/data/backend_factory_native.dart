import 'backend.dart';

/// The apps: the player, the room and the library live in Kotlin or Swift behind the platform channels.
Future<Backend> createBackend() async => NativeBackend();
