import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/copied_files.dart';
import 'package:globalsend/copied_files_view.dart';
import 'package:globalsend/text_selection_surface.dart';

void main() {
  testWidgets(
    'Android reference uses raw native drag while dismiss remains an excluded control',
    (tester) async {
      var exports = 0, pulls = 0;
      final client =
          CopiedFilesClient(
              newId: () => 'id',
              sendFiles: (_, _) async {},
              changed: () {},
            )
            ..offers = [
              {
                'sourceDeviceId': 'source',
                'sourceName': 'PC',
                'offerId': 'offer',
                'items': [
                  {
                    'id': 'file',
                    'name': 'photo.png',
                    'kind': 'file',
                    'size': 3,
                  },
                ],
              },
            ];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: CopiedFileOffers(
              client: client,
              onPull: (_, _) async {
                pulls++;
              },
              onExport: (_, _) async {
                exports++;
              },
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<ContentDragSurface>(find.byType(ContentDragSurface))
            .nativeOnly,
        isFalse,
      );
      final close = find.byTooltip('忽略此条目');
      expect(
        isContentDragControlPosition(
          tester.getCenter(close),
          tester.view.viewId,
        ),
        isTrue,
      );
      await tester.longPress(close);
      await tester.pump();
      expect(exports, 0);
      expect(pulls, 0);
      await tester.longPressAt(
        tester.getTopLeft(find.byType(ContentDragSurface)) +
            const Offset(35, 75),
      );
      await tester.pump();
      expect(exports, 1);
      expect(pulls, 0);
      await tester.tap(close);
      await tester.pump();
      expect(client.references, isEmpty);
    },
  );
}
