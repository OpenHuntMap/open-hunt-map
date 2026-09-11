import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/map/overlay_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// A controller that has read whatever the last one wrote, which is what a
  /// cold start is.
  Future<OverlayController> restart() async {
    final controller = OverlayController();
    await controller.loadPreferences();
    return controller;
  }

  test('a layer switched off stays off across a restart', () async {
    final first = await restart();
    await first.setVisible('parks', false);

    final second = await restart();
    expect(second.visibility['parks'], isFalse);
    expect(second.visibility['crown_land'], isTrue);
  });

  test('switching a layer back on forgets it', () async {
    final first = await restart();
    await first.setVisible('parks', false);
    await first.setVisible('parks', true);

    expect((await restart()).visibility['parks'], isTrue);
  });

  test('only the hidden layers are stored, so a layer added in a later build '
      'arrives visible', () async {
    final controller = await restart();
    await controller.setVisible('parks', false);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('overlay.hidden'), ['parks']);
  });

  test('a layer that no longer exists is ignored rather than fatal', () async {
    SharedPreferences.setMockInitialValues({
      'overlay.hidden': ['parks', 'a_layer_we_dropped'],
    });

    final controller = await restart();
    expect(controller.visibility['parks'], isFalse);
    expect(controller.visibility.containsKey('a_layer_we_dropped'), isFalse);
  });

  test('a colour survives on its own, with nothing hidden', () async {
    final first = await restart();
    await first.setColor('parks', '#D50000');

    final second = await restart();
    expect(second.colorFor('parks'), '#D50000');
    expect(second.visibility['parks'], isTrue);
  });

  test('a hidden layer and a custom colour do not overwrite each other',
      () async {
    final first = await restart();
    await first.setVisible('parks', false);
    await first.setColor('parks', '#D50000');

    final second = await restart();
    expect(second.visibility['parks'], isFalse);
    expect(second.colorFor('parks'), '#D50000');
  });
}
