import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/settings/display_settings.dart';
import 'package:open_woods_map/settings/marker_style.dart';
import 'package:open_woods_map/settings/settings_page.dart';
import 'package:open_woods_map/waypoints/waypoint_colour.dart';
import 'package:open_woods_map/waypoints/waypoint_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<DisplaySettings> pumpSettings(WidgetTester tester) async {
    // Tall on purpose. The page scrolls itself, and on a phone-sized surface
    // the size chips sit below the fold, where a tap silently misses.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = DisplaySettings();
    await settings.loadPreferences();
    await tester.pumpWidget(MaterialApp(home: SettingsPage(settings: settings)));
    return settings;
  }

  ChoiceChip chip(WidgetTester tester, String label) => tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(ChoiceChip),
        ),
      );

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('offers only the settings that exist', (tester) async {
    await pumpSettings(tester);

    expect(find.text('Waypoints on the map'), findsOneWidget);
    expect(find.text('Marker style'), findsOneWidget);
    expect(find.text('Marker size'), findsOneWidget);
    for (final style in WaypointMarkerStyle.values) {
      expect(find.text(style.label), findsOneWidget, reason: style.id);
    }
    for (final size in WaypointMarkerSize.values) {
      expect(find.text(size.label), findsOneWidget, reason: size.id);
    }
  });

  testWidgets('opens on what the map is actually drawing', (tester) async {
    SharedPreferences.setMockInitialValues({
      'waypoint.marker_style': 'pin',
      'waypoint.marker_size': 'large',
    });
    await pumpSettings(tester);

    expect(chip(tester, 'Icon in a pin').selected, isTrue);
    expect(chip(tester, 'Icon only').selected, isFalse);
    expect(chip(tester, 'Large').selected, isTrue);
    expect(chip(tester, 'Standard').selected, isFalse);
  });

  testWidgets('picking the pin style sets it and writes it down',
      (tester) async {
    final settings = await pumpSettings(tester);

    await tap(tester, 'Icon in a pin');

    expect(settings.markerStyle, WaypointMarkerStyle.pin);
    expect(chip(tester, 'Icon in a pin').selected, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('waypoint.marker_style'), 'pin');
  });

  testWidgets('picking a size sets it and writes it down', (tester) async {
    final settings = await pumpSettings(tester);

    await tap(tester, 'Extra large');

    expect(settings.markerSize, WaypointMarkerSize.extraLarge);
    expect(chip(tester, 'Extra large').selected, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('waypoint.marker_size'), 'extra-large');
  });

  testWidgets('the two choices are independent', (tester) async {
    final settings = await pumpSettings(tester);

    await tap(tester, 'Icon in a pin');
    await tap(tester, 'Small');

    expect(settings.markerStyle, WaypointMarkerStyle.pin);
    expect(settings.markerSize, WaypointMarkerSize.small);
    expect(chip(tester, 'Icon in a pin').selected, isTrue);
    expect(chip(tester, 'Small').selected, isTrue);
  });

  // The page sits over the map being complained about, so the preview is the
  // only thing the user can judge the choice by without leaving.
  group('the preview shows what was chosen', () {
    /// The preview's sample markers, found by the glyphs it draws.
    Iterable<Icon> glyphs(WidgetTester tester, WaypointIcon icon) =>
        tester.widgetList<Icon>(find.byIcon(icon.icon));

    testWidgets('a bare glyph is drawn in the waypoint\'s own colour',
        (tester) async {
      await pumpSettings(tester);

      final sample = glyphs(tester, WaypointIcon.stand).first;
      expect(sample.color, WaypointIcon.stand.colour);
      expect(find.byIcon(Icons.place), findsNothing);
    });

    testWidgets('the pin takes the colour and the glyph gives it up',
        (tester) async {
      await pumpSettings(tester);
      await tap(tester, 'Icon in a pin');

      // Three samples, so three pins.
      final pins = tester.widgetList<Icon>(find.byIcon(Icons.place));
      expect(pins, hasLength(3));
      expect(
        pins.map((pin) => pin.color),
        containsAll(<Color>[
          WaypointIcon.stand.colour,
          WaypointIcon.water.colour,
          WaypointColour.yellow.value,
        ]),
      );

      expect(
        glyphs(tester, WaypointIcon.stand).first.color,
        pinGlyphColour(WaypointIcon.stand.colour),
      );
    });

    // The dark-on-light case is on screen from the start rather than being a
    // surprise the first time somebody colours a waypoint yellow.
    testWidgets('a light pin gets a dark glyph, in the same preview',
        (tester) async {
      await pumpSettings(tester);
      await tap(tester, 'Icon in a pin');

      final onDark = glyphs(tester, WaypointIcon.water).first.color;
      final onLight = glyphs(tester, WaypointIcon.hazard).first.color;
      expect(onDark, Colors.white);
      expect(onLight, isNot(Colors.white));
    });

    testWidgets('grows with the size step', (tester) async {
      await pumpSettings(tester);
      final before = glyphs(tester, WaypointIcon.stand).first.size!;

      await tap(tester, 'Extra large');
      final after = glyphs(tester, WaypointIcon.stand).first.size!;

      expect(after, greaterThan(before));
      expect(
        after / before,
        closeTo(
          WaypointMarkerSize.extraLarge.multiplier /
              WaypointMarkerSize.standard.multiplier,
          1e-9,
        ),
      );
    });
  });

  // Three things the user would otherwise find out by being surprised on a
  // hillside: what else the size reaches, what happens when markers crowd, and
  // that neither style moves the coordinate.
  testWidgets('says what the settings do beyond the obvious', (tester) async {
    await pumpSettings(tester);

    expect(find.textContaining('direction arrows'), findsOneWidget);
    expect(find.textContaining('never dropped'), findsOneWidget);
    expect(find.textContaining('does not move a waypoint'), findsOneWidget);
  });
}
