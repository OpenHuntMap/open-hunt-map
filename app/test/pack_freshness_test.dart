import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/offline/pack_freshness.dart';

void main() {
  group('what the screen says about an installed pack', () {
    test('offers a download when there is no pack', () {
      final described = describeInstalledPack(installed: false, built: null);
      expect(described.status, 'Not downloaded');
      expect(described.action, 'Download');
    });

    // The bug this whole module exists for: the button said Update whenever a
    // pack was present, so it promised newer data on every visit and people
    // re-downloaded identical bytes looking for the change it implied.
    test('never says Update when nothing has been compared', () {
      final described = describeInstalledPack(
        installed: true,
        built: DateTime.utc(2026, 9, 13),
      );
      expect(described.action, isNot(contains('Update')));
      expect(described.action, 'Re-download');
    });

    test('names the build date it has', () {
      final described = describeInstalledPack(
        installed: true,
        built: DateTime.utc(2026, 9, 13, 1, 51, 55),
      );
      expect(described.status, 'Downloaded, built 13 Sep 2026');
    });

    // A pack installed before build_pack.py stamped one. "Downloaded" on its own
    // is what left people unable to tell fresh from stale, and inventing a date
    // would be worse than admitting there is none.
    test('admits when the pack carries no build date', () {
      final described = describeInstalledPack(installed: true, built: null);
      expect(described.status, 'Downloaded, build date unknown');
      expect(described.action, 'Re-download');
    });
  });

  group('build dates read as UTC', () {
    // Written with an explicit offset rather than a local DateTime so the
    // expectation does not depend on where the test happens to run. Formatting
    // in local time would move the printed day for anyone west of Greenwich.
    test('an offset timestamp prints its UTC day', () {
      final built = DateTime.parse('2026-09-13T02:00:00+05:00');
      expect(formatPackDate(built), '12 Sep 2026');
    });

    test('a single-digit day is not padded', () {
      expect(formatPackDate(DateTime.utc(2026, 1, 3)), '3 Jan 2026');
    });

    test('December is not off by one', () {
      expect(formatPackDate(DateTime.utc(2025, 12, 31)), '31 Dec 2025');
    });
  });
}
