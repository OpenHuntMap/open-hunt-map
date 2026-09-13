import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/data/models.dart';

ProvinceManifest manifestFrom(Map<String, dynamic> extra) =>
    ProvinceManifest.fromJson({
      'id': 'on',
      'name': 'Ontario',
      'version': '0.12.0',
      'policy_atlas_url': 'https://example.gov/CLUPA/index.html'
          '?viewer=CLUPA.CLUPA&locale=en-CA',
      ...extra,
    });

void main() {
  group('policy atlas deep link', () {
    // The Ontario viewer reads center as an ArcGIS x,y pair with a trailing
    // WKID, so longitude leads. Getting this backwards would drop the user in
    // the Indian Ocean, and the viewer would not complain.
    test('centres on the point, longitude first', () {
      final manifest = manifestFrom({'policy_atlas_accepts_centre': true});
      final url = manifest.policyAtlasAt(44.60123, -80.05456)!;
      expect(url.queryParameters['center'], '-80.05456,44.60123,4326');
      expect(url.queryParameters['scale'], isNotNull);
    });

    test('keeps the parameters the viewer needs to load at all', () {
      final manifest = manifestFrom({'policy_atlas_accepts_centre': true});
      final url = manifest.policyAtlasAt(44.6, -80.0)!;
      expect(url.queryParameters['viewer'], 'CLUPA.CLUPA');
      expect(url.queryParameters['locale'], 'en-CA');
      expect(url.path, '/CLUPA/index.html');
    });

    // A viewer that ignores the parameter opens at the province and says
    // nothing, so provinces are opted in one at a time rather than by default.
    test('an unchecked province gets the plain atlas URL', () {
      final manifest = manifestFrom(const {});
      final url = manifest.policyAtlasAt(46.8, -71.2)!;
      expect(url.queryParameters.containsKey('center'), isFalse);
      expect(url, manifest.policyAtlasUrl);
    });

    test('no atlas at all stays null', () {
      final manifest = ProvinceManifest.fromJson({
        'id': 'qc',
        'name': 'Quebec',
        'policy_atlas_accepts_centre': true,
      });
      expect(manifest.policyAtlasAt(46.8, -71.2), isNull);
    });
  });

  group('build stamp', () {
    test('reads the pair build_pack.py writes', () {
      final manifest = manifestFrom({
        'built': '2026-09-13T01:51:55Z',
        'content_id': '67665dcf783e5c00',
      });
      expect(manifest.built, DateTime.utc(2026, 9, 13, 1, 51, 55));
      expect(manifest.contentId, '67665dcf783e5c00');
    });

    test('an offset stamp is normalised to UTC', () {
      final manifest = manifestFrom({'built': '2026-09-13T02:00:00+05:00'});
      expect(manifest.built, DateTime.utc(2026, 9, 12, 21));
      expect(manifest.built!.isUtc, isTrue);
    });

    // A pack from before the stamp existed. The province still has to load, so
    // these stay null rather than throwing; the Offline packs screen has wording
    // for not knowing.
    test('an older pack without a stamp loads with both null', () {
      final manifest = manifestFrom(const {});
      expect(manifest.built, isNull);
      expect(manifest.contentId, isNull);
    });

    test('an unparseable date does not take the province down', () {
      final manifest = manifestFrom({'built': 'last Tuesday', 'content_id': '  '});
      expect(manifest.built, isNull);
      expect(manifest.contentId, isNull);
      expect(manifest.name, 'Ontario');
    });
  });
}
