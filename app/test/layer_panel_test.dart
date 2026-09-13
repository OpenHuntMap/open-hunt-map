import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/data/models.dart';
import 'package:open_woods_map/map/layer_panel.dart';
import 'package:open_woods_map/map/overlay_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

LoadedLayer _layer(String id, int featureCount) => LoadedLayer(
      manifest: LayerManifest(
        id: id,
        label: id,
        path: 'overlays/$id.geojson',
        featureCount: featureCount,
      ),
      metadata: const {},
      sourceUri: 'file:///nowhere/$id.geojson',
    );

/// A controller holding the layers a pack carries, keyed to their feature count.
///
/// `replaceLayers` with no map attached just records them, which is the state the
/// panel reads: it describes the installed pack, not what is drawn.
Future<OverlayController> _controllerWith(Map<String, int> layers) async {
  final controller = OverlayController();
  await controller.replaceLayers({
    for (final MapEntry(:key, :value) in layers.entries) key: _layer(key, value),
  });
  return controller;
}

/// Ontario: everything this app can draw, all of it populated.
Future<OverlayController> _fullPack() => _controllerWith({
      for (final id in OverlayController.layerOrder) id: 1,
    });

/// Quebec as published: four layers, one of them a declared but empty one.
Future<OverlayController> _quebecPack() => _controllerWith({
      'crown_land': 41988,
      'municipal_forest': 0,
      'parks': 2977,
      'municipalities': 1347,
    });

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpPanel(
    WidgetTester tester,
    Size size,
    OverlayController controller,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LayerPanel(controller: controller))),
    );
    await tester.pumpAndSettle();
  }

  // The panel is shown in a bottom sheet, so anything past the bottom edge is
  // unreachable unless the list scrolls. This is the case that broke: a
  // landscape tablet where the layer list is taller than the screen.
  testWidgets('every layer is reachable on a short landscape screen',
      (tester) async {
    await pumpPanel(tester, const Size(1024, 575), await _fullPack());

    final last = LayerPanel.labels[OverlayController.layerOrder.last]!;
    await tester.scrollUntilVisible(find.text(last), 120);
    expect(find.text(last), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the header stays put while the list scrolls', (tester) async {
    await pumpPanel(tester, const Size(1024, 575), await _fullPack());

    final headerBefore = tester.getTopLeft(find.text('Map layers'));
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Map layers')), headerBefore);
  });

  testWidgets('a tall screen does not force a full-height sheet',
      (tester) async {
    await pumpPanel(tester, const Size(1080, 2400), await _fullPack());

    final panel = tester.getSize(find.byType(LayerPanel));
    expect(panel.height, lessThan(2400 * 0.85),
        reason: 'content should size the sheet when it fits');
  });

  // How a track looks is a property of that track, so it is set in the track's
  // own editor rather than here. This panel is the tenure overlays and nothing
  // else.
  testWidgets('offers no per-track styling', (tester) async {
    await pumpPanel(tester, const Size(1080, 2400), await _fullPack());

    expect(find.text('Your tracks'), findsNothing);
    expect(find.text('Direction arrows'), findsNothing);
  });

  group('only what the pack carries', () {
    // The bug: the panel listed every layer this app can draw, so a Quebec pack
    // of four offered fourteen toggles. Ten of them controlled nothing, and
    // switching on "Sunday gun hunting" and seeing no change reads as Quebec
    // having no such rule rather than the app having no such data.
    testWidgets('a province is not offered layers its pack lacks',
        (tester) async {
      await pumpPanel(tester, const Size(1080, 2400), await _quebecPack());

      expect(find.text(LayerPanel.labels['crown_land']!), findsOneWidget);
      expect(find.text(LayerPanel.labels['parks']!), findsOneWidget);
      expect(find.text(LayerPanel.labels['sunday_gun']!), findsNothing);
      expect(find.text(LayerPanel.labels['game_preserve']!), findsNothing);
      expect(find.text(LayerPanel.labels['wmu']!), findsNothing);
    });

    // A pack may carry a layer this app has no styling for, which is how
    // Ontario's township grid shipped for a while. It cannot be drawn, so
    // offering a toggle for it would be the same empty promise from the other
    // direction.
    testWidgets('a layer this app cannot draw is not offered', (tester) async {
      final controller = await _controllerWith({
        'crown_land': 1,
        'townships': 3300,
      });
      await pumpPanel(tester, const Size(1080, 2400), controller);

      expect(find.text(LayerPanel.labels['crown_land']!), findsOneWidget);
      expect(find.text('townships'), findsNothing);
      expect(find.text('Geographic townships'), findsNothing);
    });

    // Declared with zero features, which is a gap in the data rather than an
    // answer about the ground. Hiding it would say Quebec has no municipal
    // forests; a working toggle would imply we know where they are.
    testWidgets('a declared but empty layer is shown as unavailable',
        (tester) async {
      await pumpPanel(tester, const Size(1080, 2400), await _quebecPack());

      expect(
        find.text(LayerPanel.labels['municipal_forest']!),
        findsOneWidget,
      );
      expect(
        find.text(
          'No data in this pack yet, which is not the same as none existing.',
        ),
        findsOneWidget,
      );
      // The three populated layers get a checkbox; the empty one does not.
      expect(find.byType(CheckboxListTile), findsNWidgets(3));
    });

    testWidgets('an empty layer cannot be switched on', (tester) async {
      final controller = await _quebecPack();
      await pumpPanel(tester, const Size(1080, 2400), controller);

      await tester.tap(find.text(LayerPanel.labels['municipal_forest']!));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    // Reachable before anything is downloaded, and an empty sheet would look
    // broken rather than explaining itself.
    testWidgets('no pack means no toggles and an explanation', (tester) async {
      await pumpPanel(tester, const Size(1080, 2400), OverlayController());

      expect(find.byType(CheckboxListTile), findsNothing);
      expect(
        find.textContaining('No province pack is installed'),
        findsOneWidget,
      );
    });
  });
}
