import 'dart:io';

import 'package:flutter/services.dart';

/// The renderer uses the machine's own fonts for visual tests; none are assets.
Future<void> loadSystemTestFonts() async {
  if (!Platform.isWindows) return;
  final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
  for (final entry in {
    'Segoe UI': 'segoeui.ttf',
    // Flutter's test host otherwise substitutes Ahem for Android's default.
    'Roboto': 'segoeui.ttf',
    'Microsoft YaHei': 'msyh.ttc',
  }.entries) {
    final file = File('$windows/Fonts/${entry.value}');
    if (!await file.exists()) continue;
    final loader = FontLoader(entry.key)
      ..addFont(Future.value(ByteData.sublistView(await file.readAsBytes())));
    await loader.load();
  }
}
