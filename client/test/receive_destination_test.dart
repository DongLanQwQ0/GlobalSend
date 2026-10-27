import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/receive_destination.dart';

class FolderPicker extends FilePickerPlatform {
  String? result;
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    final parent = Directory('build/test-tmp');
    await parent.create(recursive: true);
    root = await parent.createTemp('receive-destination-');
    ReceiveDestination.registryDirectoryForTesting = () async =>
        Directory('${root.path}/registry');
  });
  tearDown(() async {
    ReceiveDestination.registryDirectoryForTesting = null;
    await root.delete(recursive: true);
  });

  test(
    'folder picker returns selection or null without changing a saved choice',
    () async {
      final original = FilePickerPlatform.instance;
      final picker = FolderPicker();
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = original);
      expect(await ReceiveDestination.pick(), isNull);
      picker.result = root.absolute.path;
      expect(await ReceiveDestination.pick(), {
        'location': root.absolute.path,
        'label': root.absolute.path,
      });
    },
    skip: !Platform.isWindows,
  );

  test('direct local receives reserve unique names and only mutate registered files', () async {
    final folder = Directory('${root.path}/selected');
    await folder.create();
    final original = File('${folder.path}/报告.txt');
    await original.writeAsBytes([9, 9]);
    final handles = await Future.wait([
      ReceiveDestination.create(
        destinationLocation: folder.absolute.path,
        name: '报告.txt',
      ),
      ReceiveDestination.create(
        destinationLocation: folder.absolute.path,
        name: '报告.txt',
      ),
    ]);
    expect(handles.map((item) => item.name), ['报告 (1).txt', '报告 (2).txt']);
    expect(
      handles.every(
        (item) => item.location == item.ioPath && item.handle.isEmpty,
      ),
      isTrue,
    );
    await File(handles[0].ioPath).writeAsBytes([1, 2, 3]);
    await ReceiveDestination.closeHandle(handles[0].handle);
    expect(await ReceiveDestination.isOwned(handles[0].location), isTrue);
    expect(
      await ReceiveDestination.isOwned(await original.resolveSymbolicLinks()),
      isFalse,
    );
    await expectLater(
      ReceiveDestination.openHandle(
        await original.resolveSymbolicLinks(),
        writable: true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      ReceiveDestination.delete(await original.resolveSymbolicLinks()),
      throwsA(isA<FileSystemException>()),
    );
    final reopened = await ReceiveDestination.openHandle(
      handles[0].location,
      writable: true,
    );
    expect(reopened.size, 3);
    final renamed = await ReceiveDestination.rename(
      reopened.location,
      '报告.txt',
    );
    expect(renamed.name, '报告 (3).txt');
    expect(renamed.size, 3);
    expect(await File(renamed.location).readAsBytes(), [1, 2, 3]);
    expect(await ReceiveDestination.isOwned(reopened.location), isFalse);
    expect(await ReceiveDestination.isOwned(renamed.location), isTrue);
    expect(await ReceiveDestination.delete(renamed.location), isTrue);
    expect(await ReceiveDestination.delete(handles[1].location), isTrue);
    expect(await original.readAsBytes(), [9, 9]);
    expect(await folder.list().length, 1);
  }, skip: !Platform.isWindows);
}
