import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/map/layer_panel.dart';
import 'package:open_woods_map/map/overlay_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpPanel(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayerPanel(controller: OverlayController()),
        ),
      ),
    );
    await tester.pumpAndSettle();
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
}
