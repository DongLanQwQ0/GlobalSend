import 'app_icon.dart';

import 'package:flutter/material.dart';

import 'credential_recovery.dart';
import 'ui_tokens.dart';
import 'models.dart';
import 'text_viewer.dart';

class CredentialRecoveryScreen extends StatelessWidget {
  const CredentialRecoveryScreen({
    super.key,
    required this.records,
    required this.onOpenFile,
  });
  final List<CredentialRecoveryRecord> records;
  final Future<void> Function(DockEntry) onOpenFile;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('旧身份记录')),
    body: ListView(
      padding: Ui.insetPanel,
      children: [
        Card(
          color: Ui.colors(context).accentSoft,
          child: Padding(
            padding: Ui.insetField,
            child: Text('旧记录只读。转发本机文件请使用文件库。'),
          ),
        ),
        const SizedBox(height: Ui.space3),
        for (final record in records)
          ListTile(
            shape: const RoundedRectangleBorder(borderRadius: Ui.cardRadius),
            tileColor: Ui.colors(context).surface,
            minTileHeight: Ui.touch,
            leading: const AppIcon(Icons.history_outlined),
            title: Text('${record.profile['name'] ?? '原设备'} · 只读'),
            subtitle: Text(
              DateTime.parse(record.createdAt)
                  .toLocal()
                  .toString()
                  .split('.')
                  .first,
            ),
            trailing: const AppIcon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    _CredentialHistory(record: record, onOpenFile: onOpenFile),
              ),
            ),
          ),
      ],
    ),
  );
}

class _CredentialHistory extends StatefulWidget {
  const _CredentialHistory({required this.record, required this.onOpenFile});
  final CredentialRecoveryRecord record;
  final Future<void> Function(DockEntry) onOpenFile;
  @override
  State<_CredentialHistory> createState() => _CredentialHistoryState();
}

class _CredentialHistoryState extends State<_CredentialHistory> {
  late final history = widget.record.history();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('旧记录 · 只读')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: history,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const UiEmpty(
            icon: Icons.error_outline,
            title: '记录暂时无法读取，原备份已保留',
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = (snapshot.data!['dock'] as List? ?? [])
            .map(
              (value) => DockEntry.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList();
        final sources = Map<String, String>.from(
          snapshot.data!['sources'] ?? {},
        );
        for (final entry in entries) {
          if (entry.kind == 'file' && entry.localPath.isEmpty) {
            entry.localPath = sources[entry.fileId] ?? entry.sourceReference;
          }
        }
        final staged = List<String>.from(snapshot.data!['stagedTexts'] ?? []);
        return ListView(
          padding: Ui.insetPanel,
          children: [
            if (entries.isEmpty && staged.isEmpty)
              const UiEmpty(icon: Icons.history_outlined, title: '暂无旧记录'),
            for (final entry in entries)
              ListTile(
                shape: const RoundedRectangleBorder(
                  borderRadius: Ui.cardRadius,
                ),
                tileColor: Ui.colors(context).surface,
                minTileHeight: Ui.touch,
                leading: AppIcon(
                  entry.kind == 'text'
                      ? Icons.notes_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(
                  entry.kind == 'text' ? entry.text : entry.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${entry.outgoing ? '发出' : '接收'} · 只读'),
                onTap: entry.kind == 'text'
                    ? () => showTextViewer(
                        context,
                        title: '旧消息 · 只读',
                        text: entry.text,
                      )
                    : entry.localPath.isEmpty
                    ? null
                    : () async {
                        try {
                          await widget.onOpenFile(entry);
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('原文件暂时无法打开，记录仍已保留')),
                            );
                          }
                        }
                      },
              ),
            if (staged.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: Ui.space2),
                child: Text('原待发送文本'),
              ),
            for (final text in staged)
              ListTile(
                shape: const RoundedRectangleBorder(
                  borderRadius: Ui.cardRadius,
                ),
                tileColor: Ui.colors(context).surface,
                minTileHeight: Ui.touch,
                title: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
                onTap: () =>
                    showTextViewer(context, title: '原待发送 · 只读', text: text),
              ),
          ],
        );
      },
    ),
  );
}
