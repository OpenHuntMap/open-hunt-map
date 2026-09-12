import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/search/coordinate_parser.dart';
import 'package:open_woods_map/search/coordinate_search_sheet.dart';

/// Holds whatever the panel handed back, so a test can look at it after tapping.
class _Harness {
  Coordinate? accepted;
}

Future<_Harness> _pump(WidgetTester tester, {PlaceSearchContext? places}) async {
  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CoordinateSearchPanel(
          places: places,
          onAccept: (coordinate) => harness.accepted = coordinate,
        ),
      ),
    ),
  );
  return harness;
}

void main() {
  testWidgets('Go stays disabled until something parses', (tester) async {
    await _pump(tester);

    FilledButton go() => tester.widget<FilledButton>(find.byType(FilledButton));
    expect(go().onPressed, isNull, reason: 'nothing typed yet');

    await tester.enterText(find.byType(TextField), 'Algonquin Park');
    await tester.pump();
    expect(go().onPressed, isNull, reason: 'a place name is not a coordinate');

    await tester.enterText(find.byType(TextField), '45.086428, -75.786970');
    await tester.pump();
    expect(go().onPressed, isNotNull);
  });

  // The read-back is the safety feature: it is how someone notices that the
  // coordinate they pasted lost its minus sign on the way.
  testWidgets('reads the coordinate back as plain decimal degrees', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), '45°05\'11.1"N 75°47\'13.1"W');
    await tester.pump();

    expect(find.text('45.086417, -75.786972'), findsOneWidget);
    expect(
      find.textContaining('Read as degrees, minutes and seconds'),
      findsOneWidget,
    );
  });

  testWidgets('shows the refusal rather than failing silently', (tester) async {
    await _pump(tester);

    await tester.enterText(
      find.byType(TextField),
      'https://maps.app.goo.gl/aBcDeF123',
    );
    await tester.pump();

    expect(find.textContaining('short link'), findsOneWidget);
  });

  testWidgets('says what it assumed about a UTM grid reference', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), '18T 439000 4991000');
    await tester.pump();

    expect(find.textContaining('Read as UTM zone 18'), findsOneWidget);
    expect(find.textContaining('MGRS latitude band'), findsOneWidget);
  });

  testWidgets('hands the parsed coordinate over on Go', (tester) async {
    final harness = await _pump(tester);

    await tester.enterText(find.byType(TextField), '45.086428, -75.786970');
    await tester.pump();
    await tester.tap(find.text('Go'));
    await tester.pump();

    final coordinate = harness.accepted;
    expect(coordinate, isNotNull);
    expect(coordinate!.latitude, closeTo(45.086428, 1e-9));
    expect(coordinate.longitude, closeTo(-75.786970, 1e-9));
  });

  testWidgets('the keyboard Go key submits too', (tester) async {
    final harness = await _pump(tester);

    await tester.enterText(find.byType(TextField), '18N 500000 5000000');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();

    expect(harness.accepted, isNotNull);
  });
}
