import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/map/layer_panel.dart';
import 'package:open_woods_map/map/overlay_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ValueNotifier<bool>> pumpPanel(
    WidgetTester tester,
    Size size, {
    bool arrows = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final trackArrows = ValueNotifier(arrows);
    addTearDown(trackArrows.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(
            controller: OverlayController(),
            trackArrows: trackArrows,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return trackArrows;
  }

  // The panel is shown in a bottom sheet, so anything past the bottom edge is
  // unreachable unless the list scrolls. This is the case that broke: a
  // landscape tablet where the layer list is taller than the screen.
  testWidgets('every layer is reachable on a short landscape screen',
      (tester) async {
    await pumpPanel(tester, const Size(1024, 575));

    final last = LayerPanel.labels[OverlayController.layerOrder.last]!;
    await tester.scrollUntilVisible(find.text(last), 120);
    expect(find.text(last), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the header stays put while the list scrolls', (tester) async {
    await pumpPanel(tester, const Size(1024, 575));

    final headerBefore = tester.getTopLeft(find.text('Map layers'));
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Map layers')), headerBefore);
  });

  testWidgets('a tall screen does not force a full-height sheet',
      (tester) async {
    await pumpPanel(tester, const Size(1080, 2400));

    final panel = tester.getSize(find.byType(LayerPanel));
    expect(panel.height, lessThan(2400 * 0.85),
        reason: 'content should size the sheet when it fits');
  });

  group('direction arrows', () {
    Finder arrowsTile() => find.ancestor(
          of: find.text('Direction arrows'),
          matching: find.byType(CheckboxListTile),
        );

    testWidgets('is offered below the layers and reflects the setting',
        (tester) async {
      await pumpPanel(tester, const Size(1080, 2400), arrows: false);

      expect(arrowsTile(), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(arrowsTile()).value,
        isFalse,
      );
    });

    testWidgets('turning it off reports the change and redraws the checkbox',
        (tester) async {
      final trackArrows = await pumpPanel(tester, const Size(1080, 2400));

      await tester.tap(find.text('Direction arrows'));
      await tester.pumpAndSettle();

      expect(trackArrows.value, isFalse);
      // The sheet is built once and does not rebuild with the map shell, so the
      // box has to follow the notifier or it reads as an ignored tap.
      expect(tester.widget<CheckboxListTile>(arrowsTile()).value, isFalse);
    });

    testWidgets('turning it back on returns to arrows', (tester) async {
      final trackArrows =
          await pumpPanel(tester, const Size(1080, 2400), arrows: false);

      await tester.tap(find.text('Direction arrows'));
      await tester.pumpAndSettle();

      expect(trackArrows.value, isTrue);
    });
  });
}
