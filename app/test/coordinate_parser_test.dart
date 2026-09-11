import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/search/coordinate_parser.dart';

/// The coordinate the Land Info card shows for a point near Ottawa, used
/// throughout so every notation below is the same place written differently.
const lat = 45.086428;
const lon = -75.786970;

Coordinate hit(String input) {
  final result = parseCoordinate(input);
  if (result is! Coordinate) {
    fail('Expected a coordinate from "$input", got ${_describe(result)}');
  }
  return result;
}

String miss(String input) {
  final result = parseCoordinate(input);
  if (result is! CoordinateError) {
    fail('Expected a refusal for "$input", got ${_describe(result)}');
  }
  return result.message;
}

String _describe(CoordinateResult? result) => switch (result) {
  null => 'null',
  Coordinate(:final latitude, :final longitude) => '$latitude, $longitude',
  CoordinateError(:final message) => 'error: $message',
};

void main() {
  group('decimal degrees', () {
    test('a comma-separated pair, the shape the app itself copies out', () {
      final c = hit('45.086428, -75.786970');
      expect(c.latitude, closeTo(lat, 1e-9));
      expect(c.longitude, closeTo(lon, 1e-9));
      expect(c.format, 'decimal degrees');
    });

    test('no space after the comma', () {
      expect(hit('45.086428,-75.786970').longitude, closeTo(lon, 1e-9));
    });

    test('separated by a single space rather than a comma', () {
      final c = hit('45.086428 -75.786970');
      expect(c.latitude, closeTo(lat, 1e-9));
      expect(c.longitude, closeTo(lon, 1e-9));
    });

    test('hemisphere letters instead of a minus sign', () {
      final c = hit('45.086428N 75.786970W');
      expect(c.latitude, closeTo(lat, 1e-9));
      expect(c.longitude, closeTo(lon, 1e-9));
      // Letters state the axis outright, so nothing had to be assumed.
      expect(c.note, isNull);
    });

    test('hemisphere letters leading rather than trailing', () {
      final c = hit('N45.086428 W75.786970');
      expect(c.latitude, closeTo(lat, 1e-9));
      expect(c.longitude, closeTo(lon, 1e-9));
    });

    // Longitude-first happens on aviation and UTM-minded sources. The letters
    // make it unambiguous, so it is read as written rather than refused.
    test('longitude first, when the letters say so', () {
      final c = hit('75.786970W 45.086428N');
      expect(c.latitude, closeTo(lat, 1e-9));
      expect(c.longitude, closeTo(lon, 1e-9));
      expect(c.note, contains('longitude first'));
    });

    test('with no letters the latitude-first assumption is reported', () {
      expect(hit('45.086428, -75.786970').note, contains('Assumed latitude'));
    });
  });

  group('degrees and decimal minutes', () {
    test('spaced, with letters and a zero-padded longitude', () {
      final c = hit('45 05.186 N, 075 47.218 W');
      expect(c.latitude, closeTo(45 + 5.186 / 60, 1e-9));
      expect(c.longitude, closeTo(-(75 + 47.218 / 60), 1e-9));
      expect(c.format, 'degrees and decimal minutes');
    });

    test('with degree and minute marks', () {
      final c = hit("45°05.186'N 075°47.218'W");
      expect(c.latitude, closeTo(45 + 5.186 / 60, 1e-9));
      expect(c.longitude, closeTo(-(75 + 47.218 / 60), 1e-9));
    });
  });

  group('degrees, minutes and seconds', () {
    test('with degree, minute and second marks', () {
      final c = hit('45°05\'11.1"N 75°47\'13.1"W');
      expect(c.latitude, closeTo(45 + 5 / 60 + 11.1 / 3600, 1e-9));
      expect(c.longitude, closeTo(-(75 + 47 / 60 + 13.1 / 3600), 1e-9));
      expect(c.format, 'degrees, minutes and seconds');
    });

    test('bare numbers, no marks at all', () {
      final c = hit('45 5 11.1 N 75 47 13.1 W');
      expect(c.latitude, closeTo(45 + 5 / 60 + 11.1 / 3600, 1e-9));
      expect(c.longitude, closeTo(-(75 + 47 / 60 + 13.1 / 3600), 1e-9));
    });

    // Word processors and PDFs substitute primes and curly quotes for the
    // ASCII marks, and a regulations PDF is a likely source for these.
    test('typographic primes rather than ASCII quotes', () {
      final c = hit('45°05′11.1″N 75°47′13.1″W');
      expect(c.latitude, closeTo(45 + 5 / 60 + 11.1 / 3600, 1e-9));
      expect(c.longitude, closeTo(-(75 + 47 / 60 + 13.1 / 3600), 1e-9));
    });
  });

  group('links', () {
    test('a maps camera URL', () {
      final c = hit('https://www.google.com/maps/@45.086428,-75.786970,15z');
      expect(c.latitude, closeTo(lat, 1e-9));
      expect(c.longitude, closeTo(lon, 1e-9));
    });

    test('a q= query URL', () {
      expect(
        hit('https://maps.google.com/?q=45.086428,-75.786970').latitude,
        closeTo(lat, 1e-9),
      );
    });

    // A place URL carries both the camera position and the place itself. The
    // place is what the user shared, so the camera must not win.
    test('a place URL prefers the place over the camera position', () {
      final c = hit(
        'https://www.google.com/maps/place/Somewhere/@45.8,-78.3,12z/'
        'data=!4m6!3m5!1s0x0!8m2!3d45.086428!4d-75.786970',
      );
      expect(c.latitude, closeTo(lat, 1e-9));
      expect(c.longitude, closeTo(lon, 1e-9));
    });

    test('a geo: URI', () {
      expect(hit('geo:45.086428,-75.786970').longitude, closeTo(lon, 1e-9));
    });

    // The location behind a short link lives on Google's servers, so an
    // offline app cannot resolve one. Saying which link it is beats failing
    // vaguely, and beats guessing far more.
    test('a short link is named and refused rather than mis-parsed', () {
      expect(miss('https://maps.app.goo.gl/aBcDeF123'), contains('short link'));
    });

    test('a link with no coordinate in it says so', () {
      expect(miss('https://example.com/some/page'), contains('no coordinate'));
    });
  });

  group('refusals', () {
    test('blank input is not an error, just nothing', () {
      expect(parseCoordinate(''), isNull);
      expect(parseCoordinate('   '), isNull);
    });

    // Points at the next phase rather than leaving the user guessing why a
    // perfectly reasonable search did nothing.
    test('a place name explains that place search does not exist yet', () {
      expect(miss('Algonquin Park'), contains('place name'));
    });

    test('a minus sign fighting a hemisphere letter', () {
      expect(miss('-45.086428N, 75.786970W'), contains('disagree'));
    });

    test('both halves marked as the same axis', () {
      expect(miss('45.086428N, 75.786970N'), contains('same axis'));
    });

    test('minutes of sixty or more', () {
      expect(miss('45 70.5 N, 75 30.0 W'), contains('under 60'));
    });

    test('seconds of sixty or more', () {
      expect(miss('45 5 61.0 N, 75 47 13.1 W'), contains('under 60'));
    });

    test('a latitude beyond the poles', () {
      expect(miss('95.0, -75.0'), contains('between -90 and 90'));
    });

    test('a longitude beyond the antimeridian', () {
      expect(miss('45.0, -275.0'), contains('between -180 and 180'));
    });
  });

  group('normalisation', () {
    test('a Unicode minus sign, as pasted from a PDF', () {
      expect(
        hit('45.086428, \u221275.786970').longitude,
        closeTo(lon, 1e-9),
      );
    });

    test('non-breaking spaces and collapsed runs of whitespace', () {
      expect(
        hit('45.086428,\u00A0\u00A0 -75.786970').longitude,
        closeTo(lon, 1e-9),
      );
    });
  });

  // These expected values come from PROJ via pyproj, not from the same
  // arithmetic under test; tools/gis/build_utm_fixtures.py regenerates them.
  // A metre is about 9e-6 degrees of latitude, so 1e-6 is comfortably tighter
  // than any grid reference typed off a paper NTS sheet.
  group('UTM', () {
    const tolerance = 1e-6;

    test('zone 18 with an MGRS band letter', () {
      final c = hit('18T 439000 4991000');
      expect(c.latitude, closeTo(45.06983250215938, tolerance));
      expect(c.longitude, closeTo(-75.77490332018807, tolerance));
      expect(c.format, 'UTM zone 18');
    });

    // On the central meridian the easting is exactly the false easting, so the
    // longitude must come out exactly on the zone's centre. A sign or scaling
    // error in the series would show up here first.
    test('on the central meridian the longitude is exact', () {
      final c = hit('18N 500000 5000000');
      expect(c.latitude, closeTo(45.153477183356024, tolerance));
      expect(c.longitude, closeTo(-75.0, 1e-9));
    });

    test('zone 17', () {
      final c = hit('17T 612345 5432109');
      expect(c.latitude, closeTo(49.031622374401444, tolerance));
      expect(c.longitude, closeTo(-79.46302734428295, tolerance));
    });

    test('zone 16', () {
      final c = hit('16U 400000 5600000');
      expect(c.latitude, closeTo(50.54337955474289, tolerance));
      expect(c.longitude, closeTo(-88.41133877037352, tolerance));
    });

    test('zone 15, near the western edge of Ontario', () {
      final c = hit('15U 700000 5800000');
      expect(c.latitude, closeTo(52.31384366410326, tolerance));
      expect(c.longitude, closeTo(-90.06581011324353, tolerance));
    });

    test('zone 19, eastern Quebec', () {
      final c = hit('19T 300000 5200000');
      expect(c.latitude, closeTo(46.92338121976912, tolerance));
      expect(c.longitude, closeTo(-71.6270013976238, tolerance));
    });

    // The southern hemisphere subtracts a 10,000,000 m false northing. Nobody
    // in Canada needs it, but getting it wrong would be a silent sign flip.
    test('a southern-hemisphere reference applies the false northing', () {
      final c = hit('18S 500000 9000000');
      expect(c.latitude, closeTo(-9.046562463768952, tolerance));
      expect(c.longitude, closeTo(-75.0, 1e-9));
    });

    test('metre suffixes on the easting and northing', () {
      final c = hit('18 439000mE 4991000mN');
      expect(c.latitude, closeTo(45.06983250215938, tolerance));
      expect(c.longitude, closeTo(-75.77490332018807, tolerance));
    });

    test('a comma between easting and northing', () {
      expect(
        hit('17T 612345, 5432109').latitude,
        closeTo(49.031622374401444, tolerance),
      );
    });

    group('what it says it assumed', () {
      test('N is read as a hemisphere, not the MGRS band', () {
        expect(hit('18N 500000 5000000').note, contains('northern hemisphere'));
      });

      test('S is read as a hemisphere, not the MGRS band', () {
        expect(hit('18S 500000 9000000').note, contains('southern hemisphere'));
      });

      test('a band letter says it was read as a band', () {
        expect(hit('18T 439000 4991000').note, contains('MGRS latitude band'));
      });

      test('no letter at all says the hemisphere was assumed', () {
        expect(hit('18 439000 4991000').note, contains('Assumed the northern'));
      });
    });

    test('a zone outside 1 to 60 is refused', () {
      expect(miss('61T 439000 4991000'), contains('1 to 60'));
    });

    test('I and O are not latitude bands', () {
      expect(miss('18I 439000 4991000'), contains('not an MGRS latitude band'));
    });

    // Degrees-and-minutes has to keep working: the numbers there are short, and
    // that width difference is the whole basis for telling the two apart.
    test('does not swallow degrees and decimal minutes', () {
      expect(hit('45 05.186 N, 075 47.218 W').format, contains('minutes'));
    });
  });

  // The failure this whole file exists to prevent. "N45.08 W75.78" used to cut
  // after the first letter, leaving "N45.08 W" and "75.78", and a half with a
  // letter at both ends produced a zero rather than a refusal — so the search
  // landed on latitude zero, in the Gulf of Guinea, without complaint.
  group('never silently wrong', () {
    test('a leading-letter pair does not collapse to latitude zero', () {
      final c = hit('N45.086428 W75.786970');
      expect(c.latitude, isNot(closeTo(0, 0.001)));
      expect(c.latitude, closeTo(lat, 1e-9));
    });

    test('a half with letters at both ends is refused, not zeroed', () {
      final result = parseCoordinate('N45.086428W, 75.0');
      expect(result, isA<CoordinateError>());
    });
  });
}
