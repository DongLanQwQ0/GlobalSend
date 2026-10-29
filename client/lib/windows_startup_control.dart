import 'dart:async';

import 'package:flutter/material.dart';

import 'system_bridge.dart';

class WindowsStartupControl extends StatefulWidget {
  const WindowsStartupControl({super.key});

  @override
  State<WindowsStartupControl> createState() => _WindowsStartupControlState();
}

class _WindowsStartupControlState extends State<WindowsStartupControl> {
  bool? enabled;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await SystemBridge.autoStartEnabled();
      if (mounted) setState(() => enabled = value);
    } catch (_) {
      if (mounted) setState(() => error = '无法读取开机启动设置');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> change(bool value) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final actual = await SystemBridge.setAutoStart(value);
      if (mounted) setState(() => enabled = actual);
    } catch (_) {
      if (mounted) setState(() => error = '无法更改开机启动设置');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SwitchListTile.adaptive(
        key: const ValueKey('startup-toggle'),
        contentPadding: EdgeInsets.zero,
        title: const Text('开机自启动'),
        subtitle: const Text('后台运行'),
        value: enabled ?? false,
        onChanged: busy || enabled == null ? null : change,
      ),
      if (error != null)
        Row(
          children: [
            Expanded(
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton(onPressed: busy ? null : load, child: const Text('重试')),
          ],
        ),
    ],
  );
}
