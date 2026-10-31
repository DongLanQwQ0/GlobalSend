import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/directories.dart';
import 'package:globalsend/main.dart';

/// Synthetic app identity; all behavior below the initial enrollment is the
/// actual production controller, Android service and cached-engine host.
class BackgroundProbeController extends SendController {
  bool initialized = false;
  Timer? observation;
  @override
  Future<void> init() async {
    if (initialized) return;
    initialized = true;
    await super.init();
    if (const bool.fromEnvironment('GLOBALSEND_PUBLICATION_FIXTURE')) {
      final folder = Directory(
        '/storage/emulated/0/Download/GlobalSend-publication77-receive',
      );
      await folder.create(recursive: true);
      await changeReceiveDirectory(folder.path, folder.path);
    }
    if (api?.token.isNotEmpty != true) {
      await connect(
        const String.fromEnvironment('GLOBALSEND_BACKGROUND_FIXTURE_CENTER'),
        development: true,
      );
      await enrollGroup('后台接收验收手机', 'background-ui-fixture');
    }
    observation = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(snapshot()),
    );
    await snapshot();
  }

  Future<void> snapshot() async {
    final directory = await appDataDirectory();
    final data = {
      'pid': pid,
      'connected': connected,
      'deviceId': profile?.deviceId,
      'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
      'backgroundEnabled': backgroundReceive.enabled,
      'backgroundRunning': backgroundReceive.running,
      'backgroundStatus': backgroundReceive.status,
      'batteryUnrestricted': backgroundReceive.batteryUnrestricted,
      'engineId': backgroundReceive.engineId,
      'engineCreatedAt': backgroundReceive.engineCreatedAt,
      'dock': dock
          .map(
            (entry) => {
              'id': entry.id,
              'kind': entry.kind,
              'title': entry.title,
              'text': entry.text,
              'status': entry.status,
              'localPath': entry.localPath,
              'size': entry.size,
            },
          )
          .toList(),
    };
    final temporary = File('${directory.path}/background-fixture-state.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename('${directory.path}/background-fixture-state.json');
  }

  @override
  void dispose() {
    observation?.cancel();
    super.dispose();
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(GlobalSendApp(controller: BackgroundProbeController()));
}
