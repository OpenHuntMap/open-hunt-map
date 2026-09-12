import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/settings/display_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Settings that have read whatever the last ones wrote, which is what a cold
  /// start is.
  Future<DisplaySettings> restart() async {
    final settings = DisplaySettings();
    await settings.loadPreferences();
    return settings;
  }

  test('a fresh install draws what the map has always drawn', () async {
    final settings = await restart();
    expect(settings.markerStyle, WaypointMarkerStyle.iconOnly);
    expect(settings.markerSize, WaypointMarkerSize.standard);
  });

  test('the pin style survives a cold start', () async {
    await (await restart()).setMarkerStyle(WaypointMarkerStyle.pin);
    expect((await restart()).markerStyle, WaypointMarkerStyle.pin);
  });

  test('the size survives a cold start', () async {
    await (await restart()).setMarkerSize(WaypointMarkerSize.extraLarge);
    expect((await restart()).markerSize, WaypointMarkerSize.extraLarge);
  });

  test('the two are stored apart, so one does not reset the other', () async {
    final first = await restart();
    await first.setMarkerStyle(WaypointMarkerStyle.pin);
    await first.setMarkerSize(WaypointMarkerSize.large);

    final second = await restart();
    expect(second.markerStyle, WaypointMarkerStyle.pin);
    expect(second.markerSize, WaypointMarkerSize.large);
  });

  // Same reason the overlay controller stores only the layers that are off: a
  // preference written by this build must not pin a later build's default.
  // Somebody who never chose a marker style follows the app rather than being
  // frozen on whatever was default the day they installed it.
  group('only a non-default choice is written down', () {
    test('the default writes nothing at all', () async {
      await restart();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('waypoint.marker_style'), isNull);
      expect(prefs.getString('waypoint.marker_size'), isNull);
    });

    test('a choice writes its id', () async {
      final settings = await restart();
      await settings.setMarkerStyle(WaypointMarkerStyle.pin);
      await settings.setMarkerSize(WaypointMarkerSize.small);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('waypoint.marker_style'), 'pin');
      expect(prefs.getString('waypoint.marker_size'), 'small');
    });

    test('going back to the default forgets it', () async {
      final settings = await restart();
      await settings.setMarkerStyle(WaypointMarkerStyle.pin);
      await settings.setMarkerStyle(WaypointMarkerStyle.iconOnly);
      await settings.setMarkerSize(WaypointMarkerSize.large);
      await settings.setMarkerSize(WaypointMarkerSize.standard);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('waypoint.marker_style'), isNull);
      expect(prefs.getString('waypoint.marker_size'), isNull);
    });
  });

  test('a stored id this build does not know falls back', () async {
    SharedPreferences.setMockInitialValues({
      'waypoint.marker_style': 'hexagon',
      'waypoint.marker_size': 'enormous',
    });
    final settings = await restart();
    expect(settings.markerStyle, WaypointMarkerStyle.iconOnly);
    expect(settings.markerSize, WaypointMarkerSize.standard);
  });

  // The map listens to this, and it is the only thing that redraws the markers
  // without a restart.
  group('listeners, which is how the map redraws', () {
    test('a change notifies', () async {
      final settings = await restart();
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setMarkerStyle(WaypointMarkerStyle.pin);
      await settings.setMarkerSize(WaypointMarkerSize.large);
      expect(notifications, 2);
    });

    // Re-picking what is already chosen would otherwise rebuild every waypoint
    // layer on the map for nothing.
    test('choosing what is already chosen does not', () async {
      final settings = await restart();
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.setMarkerStyle(settings.markerStyle);
      await settings.setMarkerSize(settings.markerSize);
      expect(notifications, 0);
    });

    test('loading notifies, because it can change what is drawn', () async {
      SharedPreferences.setMockInitialValues({
        'waypoint.marker_style': 'pin',
      });
      final settings = DisplaySettings();
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.loadPreferences();
      expect(notifications, 1);
      expect(settings.markerStyle, WaypointMarkerStyle.pin);
    });
  });
}
