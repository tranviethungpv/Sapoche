{{flutter_js}}
{{flutter_build_config}}

// Flutter's own service worker is not used: it only deletes itself, and in the same place sw.js lives (the pushes of the
// chat), so loading it would take that one away together with the subscriptions that belong to it.
_flutter.loader.load();
