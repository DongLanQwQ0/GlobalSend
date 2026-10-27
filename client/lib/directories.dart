import 'dart:io';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';

Future<Directory> appDataDirectory() async {
  return await _configuredDataDirectory() ??
      await getApplicationSupportDirectory();
}

Future<Directory> receivedDirectory() async {
  final configured = await _configuredDataDirectory();
  return configured == null
      ? getApplicationDocumentsDirectory()
      : Directory('${configured.path}/received');
}

Future<Directory?> _configuredDataDirectory() async {
  final override = Platform.environment['GLOBALSEND_DATA_DIR'];
  if (override != null && override.isNotEmpty) return Directory(override);
  if (!Platform.isWindows) return null;
  return readInstalledDataDirectory(
    File(
      '${File(Platform.resolvedExecutable).parent.path}/globalsend-data.json',
    ),
  );
}

/// A local installation pointer keeps double-click/SendTo/tray launches on the
/// same state as the local publisher. It is not included in distributable ZIPs.
Future<Directory?> readInstalledDataDirectory(File configuration) async {
  if (!await configuration.exists()) return null;
  final value = jsonDecode(await configuration.readAsString()) as Map;
  final path = value['dataDirectory'] as String;
  if (path.isEmpty) throw const FormatException('本地数据目录未设置');
  return Directory(path);
}
