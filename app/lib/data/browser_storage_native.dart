/// What the browser keeps for this page: the bytes in use, the most it will give, and whether it promised not to clear them.
/// Only a browser has this; an app owns its storage.
typedef BrowserStorage = ({int usage, int quota, bool persistent});

Future<BrowserStorage?> browserStorage() async => null;

Future<bool> keepBrowserStorage() async => false;
