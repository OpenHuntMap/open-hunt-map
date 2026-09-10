import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/map/basemap.dart';
import 'package:open_woods_map/map/basemap_panel.dart';

void main() {
  Future<BasemapKind?> pumpPanel(WidgetTester tester, Size size) async {
    BasemapKind? picked;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BasemapPanel(
            selected: BasemapKind.streets,
            onPick: (kind) => picked = kind,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return picked;
  }

  // The panel is shown in a bottom sheet, so anything past the bottom edge is
  // unreachable unless the list scrolls. This is the case that broke: on a
  // landscape tablet Hybrid was in the list but below the fold, which reads as
  // the basemap simply not existing.
  testWidgets('every basemap is reachable on a short landscape screen',
      (tester) async {
    await pumpPanel(tester, const Size(1024, 575));

    for (final kind in BasemapKind.values) {
      await tester.scrollUntilVisible(find.text(kind.label), 120);
      expect(find.text(kind.label), findsOneWidget,
          reason: '${kind.label} should be reachable');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the last basemap can be tapped on a short screen',
      (tester) async {
    BasemapKind? picked;
    tester.view.physicalSize = const Size(1024, 575);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BasemapPanel(
            selected: BasemapKind.streets,
            onPick: (kind) => picked = kind,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final last = BasemapKind.values.last;
    await tester.scrollUntilVisible(find.text(last.label), 120);
    await tester.tap(find.text(last.label));
    await tester.pumpAndSettle();
    expect(picked, last);
  });

  testWidgets('the header stays put while the list scrolls', (tester) async {
    await pumpPanel(tester, const Size(1024, 575));

    final headerBefore = tester.getTopLeft(find.text('Basemap'));
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Basemap')), headerBefore);
  });

  testWidgets('a tall screen does not force a full-height sheet',
      (tester) async {
    await pumpPanel(tester, const Size(1080, 2400));

    final panel = tester.getSize(find.byType(BasemapPanel));
    expect(panel.height, lessThan(2400 * 0.85),
        reason: 'content should size the sheet when it fits');
  });
}
