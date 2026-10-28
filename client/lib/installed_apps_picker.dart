import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'dock_platform.dart';
import 'ui_tokens.dart';

Future<String?> pickInstalledApp(BuildContext context) => showDialog<String>(
  context: context,
  builder: (_) => const Dialog(child: InstalledAppsPicker()),
);

class InstalledAppsPicker extends StatefulWidget {
  const InstalledAppsPicker({super.key});
  @override
  State<InstalledAppsPicker> createState() => _InstalledAppsPickerState();
}

class _InstalledAppsPickerState extends State<InstalledAppsPicker> {
  late Future<List<Map<String, dynamic>>> apps = DockPlatform.installedApps();
  String query = '';
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 480,
    height: MediaQuery.sizeOf(context).height * .7,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '发送应用',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: '关闭',
                icon: const AppIcon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(hintText: '搜索名称或包名'),
            onChanged: (value) =>
                setState(() => query = value.trim().toLowerCase()),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: apps,
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return Center(
                    child: TextButton(
                      onPressed: () =>
                          setState(() => apps = DockPlatform.installedApps()),
                      child: const Text('重试'),
                    ),
                  );
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                final visible = snapshot.data!
                    .where(
                      (app) => '${app['name']} ${app['package']}'
                          .toLowerCase()
                          .contains(query),
                    )
                    .toList();
                if (visible.isEmpty)
                  return const Center(child: Text('没有匹配的应用'));
                return ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final app = visible[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: app['icon'] is Uint8List
                          ? Image.memory(
                              app['icon'] as Uint8List,
                              width: 40,
                              height: 40,
                            )
                          : const AppIcon(Icons.apps),
                      title: Text(
                        app['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${app['version']}${(app['apkCount'] as int) > 1 ? ' · ${app['apkCount']} 个 APK' : ''}',
                        style: TextStyle(color: Ui.colors(context).muted),
                      ),
                      onTap: () =>
                          Navigator.pop(context, app['package'] as String),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
