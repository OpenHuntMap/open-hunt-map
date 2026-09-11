/// Reads a coordinate out of whatever the user pasted.
///
/// The app already hands people a coordinate to copy out of the Land Info card
/// and, until this existed, gave them no way to type one back in. So the input
/// here is mostly other people's notation: a screenshot of a GPS, a line out of
/// a regulations PDF, a Google Maps link, a UTM grid reference off an NTS sheet.
///
/// The rule the rest of this app lives by applies to parsing too. Where the
/// input is ambiguous this reports what it assumed instead of quietly picking,
/// and where it cannot know it refuses instead of guessing. A search box that
/// silently drops you 3,000 km away is worse than one that says no.
library;

import 'dart:math' as math;

/// Latitude and longitude, plus how they were read.
sealed class CoordinateResult {
  const CoordinateResult();
}

final class Coordinate extends CoordinateResult {
  const Coordinate({
    required this.latitude,
    required this.longitude,
    required this.format,
    this.note,
  });

  final double latitude;
  final double longitude;

  /// The notation recognised, so the confirmation can say it back. Reading your
  /// own input back is the cheapest way to catch a paste that lost a minus sign.
  final String format;

  /// What was assumed rather than read, or null when nothing was.
  final String? note;
}

final class CoordinateError extends CoordinateResult {
  const CoordinateError(this.message);

  /// Written to be shown as-is. The caller has no better idea why this failed.
  final String message;
}

/// Google's own share sheet produces these, and they carry no coordinate at all
/// — the location lives on Google's servers behind the redirect. An offline app
/// cannot follow one, and pretending otherwise would end in a wrong place or a
/// confusing failure, so they are named and refused.
final _shortLink = RegExp(
  r'(maps\.app\.goo\.gl|goo\.gl/maps)',
  caseSensitive: false,
);

/// One half of a coordinate: an optional sign, one to three numbers, and a
/// hemisphere letter that may lead or trail. Covers decimal degrees, degrees
/// with decimal minutes, and degrees-minutes-seconds in one shape, because the
/// only thing separating them is how many numbers turned up.
final _half = RegExp(
  r'^([NSEW])?\s*([-+]?)\s*(\d+(?:\.\d+)?)\s*(?:°|d|deg)?'
  r'(?:[\s,]*(\d+(?:\.\d+)?)\s*(?:′|\x27|m|min)?'
  r'(?:[\s,]*(\d+(?:\.\d+)?)\s*(?:″|\x27\x27|"|s|sec)?)?)?'
  r'\s*([NSEW])?$',
  caseSensitive: false,
);

/// A bare pair of signed decimal numbers, used only to recognise that a string
/// is coordinate-shaped before the halves are parsed properly.
final _looksNumeric = RegExp(r'^[-+\d\s.,°′″\x27"NSEWnsew/;:]+$');

/// Reads [input] as a coordinate.
///
/// Returns a [Coordinate] on success or a [CoordinateError] carrying a sentence
/// fit to show the user. Blank input yields null, so a caller can ignore an
/// empty field without treating it as a mistake.
CoordinateResult? parseCoordinate(String input) {
  final normalised = _normalise(input);
  if (normalised.isEmpty) return null;

  if (_shortLink.hasMatch(normalised)) {
    return const CoordinateError(
      'That is a Google Maps short link, which holds no coordinate — the '
      'location is on their servers. Open it in a browser, then copy the '
      'numbers out of the address bar.',
    );
  }

  // Before the degree notations, because a grid reference is three plain
  // numbers and would otherwise be mistaken for degrees and minutes.
  final utm = _fromUtm(normalised);
  if (utm != null) return utm;

  final isLink = normalised.contains('://') || normalised.startsWith('geo:');
  final extracted = _fromUrl(normalised);
  if (isLink && extracted == null) {
    return const CoordinateError(
      'That link carries no coordinate this build can read. Opening it and '
      'copying the numbers out of the address bar will work.',
    );
  }
  if (!_looksNumeric.hasMatch(extracted ?? normalised)) {
    return const CoordinateError(
      'That does not look like a coordinate. Searching by place name is not in '
      'this build yet, so for now paste coordinates or a Google Maps link.',
    );
  }

  final halves = _split(extracted ?? normalised);
  if (halves == null) {
    return const CoordinateError(
      'Could not tell where the latitude ends and the longitude begins. A '
      'comma between them is the surest way, as in 45.0864, -75.7870.',
    );
  }

  final first = _parseHalf(halves.$1);
  final second = _parseHalf(halves.$2);
  if (first == null || second == null) {
    return const CoordinateError(
      'Could not read that as a coordinate. Decimal degrees, degrees and '
      'minutes, and degrees-minutes-seconds all work.',
    );
  }
  if (first.conflicted || second.conflicted) {
    return const CoordinateError(
      'That coordinate has a minus sign and a hemisphere letter that disagree. '
      'Remove one of them.',
    );
  }
  if (first.outOfRange || second.outOfRange) {
    return const CoordinateError(
      'Minutes and seconds have to be under 60.',
    );
  }

  return _assemble(first, second);
}

/// Decides which half is the latitude and hands back the finished coordinate.
///
/// Hemisphere letters settle it outright and even permit the halves reversed,
/// which is how a UTM-minded or aviation-minded source often writes them. With
/// no letters the order is assumed to be latitude first, per the convention the
/// app's own card uses — and that assumption is reported rather than buried,
/// because it is the one that silently sends people to the wrong continent.
CoordinateResult _assemble(_Half first, _Half second) {
  final (lat, lon, note) = switch ((first.axis, second.axis)) {
    (_Axis.latitude, _Axis.longitude) => (first, second, null),
    (_Axis.longitude, _Axis.latitude) => (
      second,
      first,
      'Read the longitude first, as written.',
    ),
    (_Axis.latitude, _Axis.latitude) ||
    (_Axis.longitude, _Axis.longitude) => (
      first,
      second,
      'both-same-axis',
    ),
    _ => (first, second, 'Assumed latitude first.'),
  };
  if (note == 'both-same-axis') {
    return const CoordinateError(
      'Both halves are marked as the same axis, so one of the N/S/E/W letters '
      'is wrong.',
    );
  }

  if (lat.value.abs() > 90) {
    return CoordinateError(
      'A latitude has to be between -90 and 90, and this one is '
      '${_trim(lat.value)}.',
    );
  }
  if (lon.value.abs() > 180) {
    return CoordinateError(
      'A longitude has to be between -180 and 180, and this one is '
      '${_trim(lon.value)}.',
    );
  }

  return Coordinate(
    latitude: lat.value,
    longitude: lon.value,
    format: _formatName(first.parts > second.parts ? first.parts : second.parts),
    note: note,
  );
}

String _formatName(int parts) => switch (parts) {
  3 => 'degrees, minutes and seconds',
  2 => 'degrees and decimal minutes',
  _ => 'decimal degrees',
};

String _trim(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'\.?0+$'), '');

/// Folds the many ways a coordinate arrives into one spelling: the Unicode
/// minus and the various dashes and quote marks that word processors and PDFs
/// substitute all mean the ASCII characters the patterns above expect.
String _normalise(String input) {
  var text = input.trim();
  for (final (from, to) in const [
    ('\u2212', '-'), // minus sign
    ('\u2013', '-'), // en dash
    ('\u2014', '-'), // em dash
    ('\u2018', "'"),
    ('\u2019', "'"),
    ('\u201C', '"'),
    ('\u201D', '"'),
    ('\u00BA', '°'), // masculine ordinal, a common stand-in for degrees
    ('\u00A0', ' '), // non-breaking space
  ]) {
    text = text.replaceAll(from, to);
  }
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Pulls the coordinate out of the link formats people actually paste.
///
/// Returns null when [text] is not a URL, leaving it to be parsed as-is.
String? _fromUrl(String text) {
  if (!text.contains('://') && !text.startsWith('geo:')) return null;

  // geo:45.08,-75.78 and geo:0,0?q=45.08,-75.78 both occur; the q wins because
  // the leading pair is a placeholder when it is present.
  final query = RegExp(
    r'[?&](?:q|ll|daddr|center|mlat)=([^&]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (query != null) return Uri.decodeComponent(query.group(1)!);

  // Google's place URLs bury the true point in !3d<lat>!4d<lon> and the camera
  // position in @<lat>,<lon>,<zoom>z. The former is the place, so prefer it.
  final place = RegExp(r'!3d([-+]?[\d.]+)!4d([-+]?[\d.]+)').firstMatch(text);
  if (place != null) return '${place.group(1)},${place.group(2)}';

  final camera = RegExp(r'@([-+]?[\d.]+),([-+]?[\d.]+)').firstMatch(text);
  if (camera != null) return '${camera.group(1)},${camera.group(2)}';

  if (text.startsWith('geo:')) {
    return text.substring(4).split('?').first;
  }
  return null;
}

/// Cuts the input into a latitude part and a longitude part.
///
/// Three strategies, in descending order of how sure they are: an explicit
/// separator, a hemisphere letter that ends the first half, and finally an even
/// run of numbers cut down the middle.
(String, String)? _split(String text) {
  final separator = RegExp(r'\s*[,;/]\s*|\s{2,}');
  final bySeparator = text.split(separator).where((p) => p.isNotEmpty).toList();
  if (bySeparator.length == 2) return (bySeparator[0], bySeparator[1]);

  // Hemisphere letters lead in some notations and trail in others, and the cut
  // goes on opposite sides of the letter in each. Splitting after the first
  // letter regardless would turn "N45.08 W75.78" into "N45.08 W" and "75.78",
  // which parses as latitude zero rather than failing.
  final letters = RegExp(
    r'[NSEW]',
    caseSensitive: false,
  ).allMatches(text).toList();
  if (letters.length == 2) {
    final cut = letters.first.start == 0 ? letters[1].start : letters.first.end;
    final head = text.substring(0, cut).trim();
    final tail = text.substring(cut).trim();
    if (head.isNotEmpty && tail.isNotEmpty) return (head, tail);
  }

  final numbers = RegExp(r'[-+]?\d+(?:\.\d+)?').allMatches(text).toList();
  if (numbers.isEmpty || numbers.length.isOdd) return null;
  final middle = numbers[numbers.length ~/ 2].start;
  return (text.substring(0, middle).trim(), text.substring(middle).trim());
}

/// A UTM grid reference: zone, an optional letter, then easting and northing.
///
/// Both distances are required to be six or seven digits, which is what keeps
/// this from swallowing "45 5 11" — a real grid reference is never that short,
/// and demanding the width is cheaper than guessing from context.
final _utm = RegExp(
  r'^(\d{1,2})\s*([A-Z])?\s*[,\s]*(\d{6,7})\s*(?:m\s*)?(?:E)?\s*[,\s]+'
  r'(\d{6,7})\s*(?:m\s*)?(?:N)?\s*$',
  caseSensitive: false,
);

/// MGRS latitude bands, south to north, with I and O left out because they read
/// as one and zero. C to M lie south of the equator, N to X north of it.
const _southernBands = 'CDEFGHJKLM';
const _northernBands = 'NPQRSTUVWX';

/// Reads a UTM grid reference, or returns null if [text] is not one.
CoordinateResult? _fromUtm(String text) {
  final match = _utm.firstMatch(text);
  if (match == null) return null;

  final zone = int.parse(match.group(1)!);
  if (zone < 1 || zone > 60) {
    return CoordinateError('UTM zones run from 1 to 60, and this one is $zone.');
  }

  final letter = match.group(2)?.toUpperCase();
  final bool northern;
  String? note;
  switch (letter) {
    // N and S are ambiguous by convention: both are MGRS bands and both are
    // used as bare hemisphere markers. Hemisphere wins, because that is what
    // EPSG and PROJ mean by "UTM zone 18N", and because reading them as bands
    // would put a Canadian grid reference in the tropics or the mid-Atlantic,
    // where nobody typing into this app is standing.
    case 'N':
      northern = true;
      note = 'Read N as the northern hemisphere, not the MGRS band.';
    case 'S':
      northern = false;
      note = 'Read S as the southern hemisphere, not the MGRS band.';
    case null:
      northern = true;
      note = 'Assumed the northern hemisphere.';
    default:
      if (_northernBands.contains(letter)) {
        northern = true;
      } else if (_southernBands.contains(letter)) {
        northern = false;
      } else {
        return CoordinateError('$letter is not an MGRS latitude band.');
      }
      note = 'Read $letter as an MGRS latitude band.';
  }

  return _utmToLatLon(
    zone: zone,
    northern: northern,
    easting: double.parse(match.group(3)!),
    northing: double.parse(match.group(4)!),
    note: note,
  );
}

/// Inverse transverse Mercator on WGS84, the standard UTM series expansion.
///
/// Accurate to well under a metre inside a zone, which is far tighter than any
/// grid reference a person types by hand. The Dart is checked against values
/// PROJ produced rather than against itself, so a mistake in this series cannot
/// agree with the test that guards it. `tools/gis/build_utm_fixtures.py`
/// regenerates them and `coordinate_parser_test.dart` asserts against them.
CoordinateResult _utmToLatLon({
  required int zone,
  required bool northern,
  required double easting,
  required double northing,
  String? note,
}) {
  const a = 6378137.0; // WGS84 semi-major axis
  const inverseFlattening = 298.257223563;
  const k0 = 0.9996; // UTM scale factor on the central meridian
  const falseEasting = 500000.0;
  const falseNorthing = 10000000.0;

  final f = 1 / inverseFlattening;
  final e2 = 2 * f - f * f;
  final ePrime2 = e2 / (1 - e2);

  final x = easting - falseEasting;
  final y = northern ? northing : northing - falseNorthing;

  final m = y / k0;
  final mu =
      m / (a * (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256));
  final e1 = (1 - math.sqrt(1 - e2)) / (1 + math.sqrt(1 - e2));
  final e1_2 = e1 * e1;
  final e1_3 = e1_2 * e1;
  final e1_4 = e1_3 * e1;

  final footprint =
      mu +
      (3 * e1 / 2 - 27 * e1_3 / 32) * math.sin(2 * mu) +
      (21 * e1_2 / 16 - 55 * e1_4 / 32) * math.sin(4 * mu) +
      (151 * e1_3 / 96) * math.sin(6 * mu) +
      (1097 * e1_4 / 512) * math.sin(8 * mu);

  final sinFoot = math.sin(footprint);
  final cosFoot = math.cos(footprint);
  final tanFoot = math.tan(footprint);
  final c1 = ePrime2 * cosFoot * cosFoot;
  final t1 = tanFoot * tanFoot;
  final oneMinus = 1 - e2 * sinFoot * sinFoot;
  final n1 = a / math.sqrt(oneMinus);
  final r1 = a * (1 - e2) / (oneMinus * math.sqrt(oneMinus));
  final d = x / (n1 * k0);
  final d2 = d * d;
  final d3 = d2 * d;
  final d4 = d3 * d;
  final d5 = d4 * d;
  final d6 = d5 * d;

  final latitude =
      footprint -
      (n1 * tanFoot / r1) *
          (d2 / 2 -
              (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ePrime2) * d4 / 24 +
              (61 +
                      90 * t1 +
                      298 * c1 +
                      45 * t1 * t1 -
                      252 * ePrime2 -
                      3 * c1 * c1) *
                  d6 /
                  720);

  final centralMeridian = (zone - 1) * 6 - 180 + 3;
  final longitude =
      centralMeridian * math.pi / 180 +
      (d -
              (1 + 2 * t1 + c1) * d3 / 6 +
              (5 -
                      2 * c1 +
                      28 * t1 -
                      3 * c1 * c1 +
                      8 * ePrime2 +
                      24 * t1 * t1) *
                  d5 /
                  120) /
          cosFoot;

  return Coordinate(
    latitude: latitude * 180 / math.pi,
    longitude: longitude * 180 / math.pi,
    format: 'UTM zone $zone',
    note: note,
  );
}

enum _Axis { latitude, longitude, unknown }

class _Half {
  const _Half({required this.value, required this.axis, required this.parts})
    : conflicted = false,
      outOfRange = false;

  const _Half.invalid({this.conflicted = false, this.outOfRange = false})
    : value = 0,
      axis = _Axis.unknown,
      parts = 0;

  final double value;
  final _Axis axis;

  /// How many numbers this half carried, which is what names the notation.
  final int parts;
  final bool conflicted;
  final bool outOfRange;
}

_Half? _parseHalf(String text) {
  final match = _half.firstMatch(text.trim());
  if (match == null) return null;

  final leading = match.group(1)?.toUpperCase();
  final sign = match.group(2) ?? '';
  final degrees = double.parse(match.group(3)!);
  final minutes = double.tryParse(match.group(4) ?? '');
  final seconds = double.tryParse(match.group(5) ?? '');
  final trailing = match.group(6)?.toUpperCase();

  // Null, not an invalid _Half: a half with a letter at both ends is not a
  // coordinate at all, and returning a zero-valued _Half here would let the
  // caller build a latitude of zero out of it.
  if (leading != null && trailing != null) return null;
  if ((minutes != null && minutes >= 60) || (seconds != null && seconds >= 60)) {
    return const _Half.invalid(outOfRange: true);
  }

  final hemisphere = leading ?? trailing;
  final negative = sign == '-';
  // A minus and a hemisphere letter are two ways of saying the same thing, and
  // when they say opposite things there is no honest way to pick a winner.
  if (negative && (hemisphere == 'N' || hemisphere == 'E')) {
    return const _Half.invalid(conflicted: true);
  }

  var value = degrees + (minutes ?? 0) / 60 + (seconds ?? 0) / 3600;
  if (negative || hemisphere == 'S' || hemisphere == 'W') value = -value;

  return _Half(
    value: value,
    axis: switch (hemisphere) {
      'N' || 'S' => _Axis.latitude,
      'E' || 'W' => _Axis.longitude,
      _ => _Axis.unknown,
    },
    parts: seconds != null ? 3 : (minutes != null ? 2 : 1),
  );
}
