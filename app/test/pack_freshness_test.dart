import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/offline/pack_freshness.dart';
import 'package:open_woods_map/offline/pack_index.dart';

PackIndexEntry published({DateTime? built, String? contentId}) =>
    PackIndexEntry(built: built, contentId: contentId, bytes: 1, version: '1');

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

  group('once the published index has been read', () {
    test('different contents is the one case that says Update', () {
      final described = describeInstalledPack(
        installed: true,
        built: DateTime.utc(2026, 9, 10),
        contentId: 'aaaaaaaaaaaaaaaa',
        check: PackCheck.checked,
        published: published(
          built: DateTime.utc(2026, 9, 13),
          contentId: 'bbbbbbbbbbbbbbbb',
        ),
      );
      expect(described.status, 'Update available, published 13 Sep 2026');
      expect(described.action, 'Update');
      expect(described.isUpdate, isTrue);
    });

    // The case that made the old label a lie, and the reason the comparison is
    // on contents rather than dates: a rebuild of unchanged sources publishes a
    // later date and the same data, and calling that an update is the same false
    // promise wearing a timestamp.
    test('a later publish date with identical contents is not an update', () {
      final described = describeInstalledPack(
        installed: true,
        built: DateTime.utc(2026, 9, 10),
        contentId: 'aaaaaaaaaaaaaaaa',
        check: PackCheck.checked,
        published: published(
          built: DateTime.utc(2026, 9, 13),
          contentId: 'aaaaaaaaaaaaaaaa',
        ),
      );
      expect(described.status, 'Up to date, built 10 Sep 2026');
      expect(described.action, 'Re-download');
      expect(described.isUpdate, isFalse);
    });

    // Digests were added at a point in time, so a pack without one was built
    // before any pack with one. The absence is itself dated, which is what makes
    // this the one conclusion drawn from missing information.
    test('an unstamped pack is older than a stamped published one', () {
      final described = describeInstalledPack(
        installed: true,
        built: null,
        check: PackCheck.checked,
        published: published(
          built: DateTime.utc(2026, 9, 13),
          contentId: 'bbbbbbbbbbbbbbbb',
        ),
      );
      expect(described.action, 'Update');
    });

    // Reading the index is not the same as the index knowing about this
    // province, and a pack published before the index existed would look exactly
    // like this. Claiming either answer would be inventing one.
    test('a province the index does not list gets no claim either way', () {
      final described = describeInstalledPack(
        installed: true,
        built: DateTime.utc(2026, 9, 10),
        contentId: 'aaaaaaaaaaaaaaaa',
        check: PackCheck.checked,
      );
      expect(described.status, 'Downloaded, built 10 Sep 2026');
      expect(described.action, 'Re-download');
    });

    test('a published pack with no digest cannot be compared', () {
      final described = describeInstalledPack(
        installed: true,
        built: DateTime.utc(2026, 9, 10),
        contentId: 'aaaaaaaaaaaaaaaa',
        check: PackCheck.checked,
        published: published(built: DateTime.utc(2026, 9, 13)),
      );
      expect(described.action, 'Re-download');
      expect(described.isUpdate, isFalse);
    });
  });

  // Being offline is the normal state for this app, so it gets wording of its
  // own rather than being folded into "nothing checked yet". The difference the
  // user needs is between "we looked" and "we could not look".
  group('when the check could not be made', () {
    test('says so, and still names what is on disk', () {
      final described = describeInstalledPack(
        installed: true,
        built: DateTime.utc(2026, 9, 10),
        contentId: 'aaaaaaaaaaaaaaaa',
        check: PackCheck.failed,
      );
      expect(
        described.status,
        'Downloaded, built 10 Sep 2026. Could not check for newer data.',
      );
      expect(described.action, 'Re-download');
      expect(described.isUpdate, isFalse);
    });

    test('a failed check on a province with no pack still offers one', () {
      final described = describeInstalledPack(
        installed: false,
        built: null,
        check: PackCheck.failed,
      );
      expect(described.status, 'Not downloaded');
      expect(described.action, 'Download');
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
