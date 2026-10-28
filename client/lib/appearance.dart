import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

enum AppearanceMode { light, dark, neutral, system }

enum AccentColor { green, blue, purple, rose, amber, slate }

@immutable
class Appearance {
  const Appearance({
    this.mode = AppearanceMode.light,
    this.accent = AccentColor.green,
  });
  final AppearanceMode mode;
  final AccentColor accent;
  Appearance resolve(Brightness systemBrightness) =>
      mode == AppearanceMode.system
      ? copyWith(
          mode: systemBrightness == Brightness.dark
              ? AppearanceMode.dark
              : AppearanceMode.light,
        )
      : this;
  Map<String, String> toJson() => {'mode': mode.name, 'accent': accent.name};
  factory Appearance.fromJson(Map value) => Appearance(
    mode:
        AppearanceMode.values
            .where((v) => v.name == value['mode'])
            .firstOrNull ??
        AppearanceMode.light,
    accent:
        AccentColor.values
            .where((v) => v.name == value['accent'])
            .firstOrNull ??
        AccentColor.green,
  );
  Appearance copyWith({AppearanceMode? mode, AccentColor? accent}) =>
      Appearance(mode: mode ?? this.mode, accent: accent ?? this.accent);
}

/// Local appearance belongs to the installation, not the current group.
class AppearanceSettings extends ChangeNotifier {
  Appearance value = const Appearance();
  File? _file;
  Future<void> _writes = Future.value();
  Future<void> load(File file) async {
    _file = file;
    if (await file.exists()) {
      value = Appearance.fromJson(jsonDecode(await file.readAsString()) as Map);
      notifyListeners();
    }
  }

  Future<void> set({AppearanceMode? mode, AccentColor? accent}) {
    final next = value.copyWith(mode: mode, accent: accent);
    if (next.mode == value.mode && next.accent == value.accent) return _writes;
    value = next;
    notifyListeners();
    final file = _file, encoded = jsonEncode(next.toJson());
    if (file == null) return Future.value();
    // Serialize rapid clicks without allowing a previous failed save to block a retry.
    return _writes = _writes
        .catchError((Object _) {})
        .then((_) => file.writeAsString(encoded, flush: true))
        .then((_) {});
  }
}

class AppearanceScope extends InheritedNotifier<AppearanceSettings> {
  const AppearanceScope({
    super.key,
    required AppearanceSettings settings,
    required super.child,
  }) : super(notifier: settings);
  static AppearanceSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
