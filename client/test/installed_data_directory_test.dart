import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/directories.dart';

void main() {
  test('installed state pointer is shared by ordinary and SendTo starts, never a copied state', () async {
    final parent = await Directory('build/test-tmp/installed-data').create(recursive: true);
    final root = await parent.createTemp('case-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/globalsend-data.json');
    expect(await readInstalledDataDirectory(file), isNull);
    await file.writeAsString(jsonEncode({'dataDirectory': '${root.path}/existing-state'}));
    expect((await readInstalledDataDirectory(file))!.path, '${root.path}/existing-state');
    expect(await Directory('${root.path}/existing-state').exists(), false);
    await file.writeAsString('{broken');
    await expectLater(readInstalledDataDirectory(file), throwsFormatException);
  });
}
