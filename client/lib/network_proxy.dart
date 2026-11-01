import 'dart:convert';
import 'dart:io';

/// One installation-wide policy, shared by center, peer and update clients.
/// The callback is evaluated for each request, including already-created clients.
class NetworkProxy {
  static bool bypassSystemProxy = true;

  static String findProxy(Uri uri) =>
      bypassSystemProxy ? 'DIRECT' : HttpClient.findProxyFromEnvironment(uri);

  static HttpClient client({SecurityContext? context}) =>
      HttpClient(context: context)..findProxy = findProxy;
}

class NetworkSettings {
  bool get bypassSystemProxy => NetworkProxy.bypassSystemProxy;
  File? _file;
  Future<void> _writes = Future.value();

  Future<void> load(File file) async {
    _file = file;
    final data = await file.exists()
        ? jsonDecode(await file.readAsString()) as Map
        : const {};
    NetworkProxy.bypassSystemProxy = data['bypassSystemProxy'] != false;
  }

  Future<void> setBypassSystemProxy(bool value) {
    NetworkProxy.bypassSystemProxy = value;
    final file = _file;
    if (file == null) return Future.value();
    final encoded = jsonEncode({'bypassSystemProxy': value});
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      await file.writeAsString(encoded, flush: true);
    });
  }
}
