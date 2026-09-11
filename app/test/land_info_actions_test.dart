import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/data/models.dart';
import 'package:open_woods_map/data/province_loader.dart';
import 'package:open_woods_map/map/land_info.dart';
import 'package:open_woods_map/map/land_info_sheet.dart';

const _manifest = ProvinceManifest(
  id: 'on',
  name: 'Ontario',
  version: 'test',
  license: 'Open Government Licence – Ontario',
  licenseUrl: 'https://example.invalid/licence',
  layers: [],
);

void main() {
  /// Opens the sheet on an empty point, which is the ordinary case: most taps
  /// land on ground no bundled polygon covers.
  Future<int> pumpSheet(
    WidgetTester tester, {
    required bool offerSave,
  }) async {
    var saves = 0;
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    showLandInfoSheet(
      ctx,
      info: const LandInfo(
        latitude: 45.0,
        longitude: -79.0,
        hits: [],
        attribution: 'test',
      ),
      provinceId: 'on',
      loader: ProvinceLoader(),
      manifest: _manifest,
      onSaveWaypoint: offerSave ? () => saves++ : null,
    );
    await tester.pumpAndSettle();
    return saves;
  }

  testWidgets('offers to save a waypoint at the spot that was asked about',
      (tester) async {
    await pumpSheet(tester, offerSave: true);
    expect(find.text('Save a waypoint here'), findsOneWidget);
  });

  testWidgets('closes before saving, so the editor is not buried under it',
      (tester) async {
    // Two sheets deep is how the editor ends up unreachable behind Land Info's
    // 88%-height sheet, which is tall enough to hide a sheet opened over it.
    await pumpSheet(tester, offerSave: true);
    await tester.tap(find.text('Save a waypoint here'));
    await tester.pumpAndSettle();
    expect(find.text('LAND INFO'), findsNothing);
  });

  testWidgets('asks once', (tester) async {
    var saves = 0;
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    showLandInfoSheet(
      ctx,
      info: const LandInfo(
        latitude: 45.0,
        longitude: -79.0,
        hits: [],
        attribution: 'test',
      ),
      provinceId: 'on',
      loader: ProvinceLoader(),
      manifest: _manifest,
      onSaveWaypoint: () => saves++,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save a waypoint here'));
    await tester.pumpAndSettle();
    expect(saves, 1);
  });

  testWidgets('says nothing about waypoints when nobody can save one',
      (tester) async {
    // The sheet is also opened from places with no map to put a waypoint on, and
    // offering an action that cannot happen is worse than not offering it.
    await pumpSheet(tester, offerSave: false);
    expect(find.text('LAND INFO'), findsOneWidget);
    expect(find.text('Save a waypoint here'), findsNothing);
  });
}
