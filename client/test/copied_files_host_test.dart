import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';

import 'receive_dock_host_test.dart';

class CopiedHost extends DockHostController {
  final requests = <Map<String, dynamic>>[];
  @override
  Future<void> pullCopiedFileSelection(Map<String, dynamic> selection) async {
    requests.add(selection);
  }
}

Map<String, dynamic> get copiedOffer => {
  'offerId': 'batch',
  'sourceDeviceId': 'source',
  'sourceName': 'DongLan',
  'items': [
    {'id': 'folder', 'name': 'Course files', 'kind': 'directory'},
  ],
};

void main() {
  testWidgets(
    'copied references route through primary engine without creating receipts',
    (tester) async {
      final c = CopiedHost();
      c.stagedTexts.add('keep this draft');
      final calls = <Map>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'windowVisible') return true;
        if (call.method == 'presentReceiveDock') {
          calls.add(call.arguments as Map);
          return {
            'presentation': 'dock',
            'shown': true,
            'arrivalGeneration': 1,
          };
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      c.copiedFiles.offers = [copiedOffer];
      c.changed();
      await tester.pumpAndSettle();
      expect(calls.last['items'], isEmpty);
      expect(calls.last['referenceRevision'], 1);
      expect(calls.last['serial'], 0);
      expect(c.pendingReceipts, isEmpty);
      c.copiedFiles.pulls['pull'] = {
        'offerId': 'batch',
        'itemIds': ['folder'],
        'state': 'pending',
      };
      c.changed();
      await tester.pumpAndSettle();
      expect(calls.last['referenceRevision'], 1);
      final refs = calls.last['copiedFiles'] as List;
      expect(refs.single['state'], 'pending');
      await messenger.handlePlatformMessage(
        SystemBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('receiveDockAction', {
            'action': 'pullCopiedFile',
            'id': 'copied:source:batch:folder',
            'serverKey': 'center',
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(c.requests.single['id'], 'copied:source:batch:folder');
      expect(c.requests.single['serverKey'], 'center');
      expect(c.stagedTexts, ['keep this draft']);
      expect(c.receiptSerial, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
