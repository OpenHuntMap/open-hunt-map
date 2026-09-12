/// Offline place-name search over the index shipped in a province pack.
///
/// The records come from the Canadian Geographical Names Database, built by
/// `tools/gis/fetch_cgndb.py`. Two things about that source decide how this
/// file behaves.
///
/// It is a register of *approved* names, so it is knowingly incomplete: a lake
/// with only a local name is absent, and its absence is not evidence of
/// anything. And it is not a road network — the road class is dropped at build
/// time rather than half-shipped, so nothing in here can be presented as road
/// or trail search.
///
/// Duplicate names are the normal case, not the exception. Ontario has 75 Mud
/// Lakes and Quebec has 168 Lac Longs, so a result that shows only a name is
/// useless. Every match carries its feature type, the county it sits in, and
/// how far it is from where the user is looking.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Why place-name search is or is not available.
enum GazetteerAvailability {
  /// An index is loaded and searchable.
  ready,

  /// No pack is installed for this province. The normal first-run state.
  noPack,

  /// A pack is installed but declares no place-name index, which is what an
  /// older pack looks like.
  notInPack,

  /// The pack declares an index that could not be read or did not parse.
  unreadable,
}

class GazetteerResult {
  const GazetteerResult(this.availability, {this.index});

  final GazetteerAvailability availability;
  final GazetteerIndex? index;

  bool get isReady => availability == GazetteerAvailability.ready;
}

/// One place, with enough context to tell it from the others sharing its name.
class PlaceMatch {
  const PlaceMatch({
    required this.name,
    required this.featureType,
    required this.context,
    required this.latitude,
    required this.longitude,
    required this.distanceMetres,
    required this.isPrefixMatch,
  });

  final String name;

  /// CGNDB's own `Generic Term` — "Lake", "Geographic Township", "Shoal".
  final String featureType;

  /// The county or district, or the province where the source left it blank.
  final String context;

  final double latitude;
  final double longitude;

  /// Great-circle distance from the map centre the search was given.
  final double distanceMetres;

  /// True where the query matched from the first character of the name.
  final bool isPrefixMatch;
}

/// What a search found: the best few, and how many there were.
///
/// [total] is carried because a gazetteer answer is often "312 places match,
/// here are the 50 nearest", and a list that silently stops at 50 reads as
/// though those are all of them.
class PlaceResults {
  const PlaceResults({required this.matches, required this.total});

  static const empty = PlaceResults(matches: [], total: 0);

  final List<PlaceMatch> matches;
  final int total;

  bool get isCapped => total > matches.length;
  bool get isEmpty => matches.isEmpty;
  bool get isNotEmpty => matches.isNotEmpty;
}

/// Shortest query that is searched.
///
/// One character matches most of the index — "a" is in nearly every Quebec
/// name — so a single letter produces a list that is sorted noise rather than
/// an answer.
const gazetteerMinimumQueryLength = 2;

/// Folds a name or a query into the one form they are compared in.
///
/// Case and accents both have to go. A user types "riviere sainte-anne" on a
/// keyboard that makes accents awkward, and the source spells it "Rivière
/// Sainte-Anne". The substitutions are the full set of non-ASCII characters
/// that actually occur in the Ontario and Quebec name columns — 27 of them,
/// all Latin-1 or Latin Extended-A plus an en dash — rather than a general
/// Unicode normalisation, which Dart cannot do without a package.
///
/// Records and queries are folded by this same function, so what matters is
/// that they agree with each other. A character outside the table is lowercased
/// and left as it is, which still matches itself when typed.
///
/// Runs on every name in the index at load time, so it collapses runs of
/// whitespace in the same pass rather than with a regular expression: building
/// one per name cost more than the rest of the fold put together.
String foldForSearch(String input) {
  final buffer = StringBuffer();
  var pendingSpace = false;
  var written = false;
  for (var index = 0; index < input.length; index++) {
    final unit = input.codeUnitAt(index);
    if (unit == 0x20 || (unit >= 0x09 && unit <= 0x0D)) {
      pendingSpace = written;
      continue;
    }
    if (pendingSpace) {
      buffer.writeCharCode(0x20);
      pendingSpace = false;
    }
    if (unit >= 0x41 && unit <= 0x5A) {
      buffer.writeCharCode(unit + 0x20);
    } else if (unit < 0x80) {
      buffer.writeCharCode(unit);
    } else {
      buffer.write(_foldings[unit] ?? String.fromCharCode(unit).toLowerCase());
    }
    written = true;
  }
  return buffer.toString();
}

/// Both cases are listed so the fold never depends on Dart's case mapping for
/// characters outside ASCII.
const _foldings = <int, String>{
  0x00C0: 'a', 0x00E0: 'a', // À à
  0x00C1: 'a', 0x00E1: 'a', // Á á
  0x00C2: 'a', 0x00E2: 'a', // Â â
  0x00C7: 'c', 0x00E7: 'c', // Ç ç
  0x00C8: 'e', 0x00E8: 'e', // È è
  0x00C9: 'e', 0x00E9: 'e', // É é
  0x00CA: 'e', 0x00EA: 'e', // Ê ê
  0x00CB: 'e', 0x00EB: 'e', // Ë ë
  0x00CC: 'i', 0x00EC: 'i', // Ì ì
  0x00CE: 'i', 0x00EE: 'i', // Î î
  0x00CF: 'i', 0x00EF: 'i', // Ï ï
  0x00D2: 'o', 0x00F2: 'o', // Ò ò
  0x00D4: 'o', 0x00F4: 'o', // Ô ô
  0x00D6: 'o', 0x00F6: 'o', // Ö ö
  0x00D9: 'u', 0x00F9: 'u', // Ù ù
  0x00DB: 'u', 0x00FB: 'u', // Û û
  0x00DC: 'u', 0x00FC: 'u', // Ü ü
  0x0152: 'oe', 0x0153: 'oe', // Œ œ
  0x2013: '-', // en dash, which the source uses in some hyphenated names
};

/// The searchable index for one province.
///
/// Plain data with no closures, because it is parsed on a worker isolate and
/// sent back whole.
class GazetteerIndex {
  GazetteerIndex._({
    required this.provinceName,
    required this.attribution,
    required this.coverageNote,
    required List<String> names,
    required Uint8List folded,
    required Int32List starts,
    required Uint16List typeIds,
    required Uint16List contextIds,
    required Int32List latitudeE5,
    required Int32List longitudeE5,
    required List<String> types,
    required List<String> contexts,
    required this.coordinateScale,
  })  : _names = names,
        _folded = folded,
        _starts = starts,
        _typeIds = typeIds,
        _contextIds = contextIds,
        _latitudeE5 = latitudeE5,
        _longitudeE5 = longitudeE5,
        _types = types,
        _contexts = contexts;

  final String provinceName;

  /// The Open Government Licence – Canada credit, which the licence requires be
  /// shown wherever the data is. Carried with the records rather than written
  /// into the app, so it cannot drift from the data it covers.
  final String attribution;

  /// What the source does not hold, in the build script's own words.
  final String? coverageNote;

  final int coordinateScale;

  final List<String> _names;

  /// Every folded name run together as bytes, each followed by a newline.
  ///
  /// This shape is the whole performance story, and both halves of it were
  /// measured rather than assumed. Scanning each name with its own
  /// `String.indexOf` cost about 5.7 ms an Ontario keystroke. Concatenating
  /// them and making one `String.indexOf` call barely helped — about 8 ms —
  /// because the cost is per character position, not per call: Dart's
  /// `indexOf` re-enters a substring comparison at every offset. The hand
  /// written scan over bytes in [search] is what brought a keystroke inside a
  /// frame, and a keystroke has exactly one frame.
  ///
  /// Bytes rather than UTF-16 halves the memory as well. Folding leaves the
  /// real data pure ASCII, and anything above 0x7F is mapped to one sentinel
  /// byte by [_toBytes] — applied to the query too, so the two still agree.
  ///
  /// The newline is what keeps a match from straddling two names.
  /// [foldForSearch] collapses whitespace, so no folded query contains one.
  final Uint8List _folded;

  /// Where each name starts in [_folded], with a trailing sentinel holding its
  /// length, so record `i` is `_starts[i] ..< _starts[i + 1] - 1`.
  final Int32List _starts;

  final Uint16List _typeIds;
  final Uint16List _contextIds;
  final Int32List _latitudeE5;
  final Int32List _longitudeE5;
  final List<String> _types;
  final List<String> _contexts;

  int get recordCount => _names.length;

  /// Parses the index file.
  ///
  /// Throws [FormatException] on anything it cannot trust, so a pack carrying a
  /// damaged index reports itself unreadable rather than searching a fraction
  /// of the province and looking like it worked.
  static GazetteerIndex parse(String jsonText) {
    final Object? decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The place-name index is not an object.');
    }
    final metadata = decoded['metadata'];
    if (metadata is! Map<String, dynamic>) {
      throw const FormatException('The place-name index has no metadata.');
    }

    final names = _stringList(decoded['names'], 'names');
    final typeIds = _intList(decoded['type_ids'], 'type_ids');
    final contextIds = _intList(decoded['context_ids'], 'context_ids');
    final latitudeE5 = _intList(decoded['lat_e5'], 'lat_e5');
    final longitudeE5 = _intList(decoded['lon_e5'], 'lon_e5');
    final types = _stringList(metadata['types'], 'metadata.types');
    final contexts = _stringList(metadata['contexts'], 'metadata.contexts');

    final count = names.length;
    if (typeIds.length != count ||
        contextIds.length != count ||
        latitudeE5.length != count ||
        longitudeE5.length != count) {
      throw const FormatException(
        'The place-name index columns are different lengths.',
      );
    }
    final declared = metadata['record_count'];
    if (declared is int && declared != count) {
      throw FormatException(
        'The place-name index holds $count records but declares $declared.',
      );
    }

    // 16 bits per id, against 430 feature types and 1,397 counties in the
    // largest real province. A file that overran this would be a different
    // format, not a bigger province.
    final packedTypes = Uint16List(count);
    final packedContexts = Uint16List(count);
    for (var index = 0; index < count; index++) {
      final type = typeIds[index];
      final context = contextIds[index];
      if (type < 0 ||
          type >= types.length ||
          type > 0xFFFF ||
          context < 0 ||
          context >= contexts.length ||
          context > 0xFFFF) {
        throw FormatException(
          'The place-name index references a type or county it does not '
          'define, at record $index.',
        );
      }
      packedTypes[index] = type;
      packedContexts[index] = context;
    }

    final starts = Int32List(count + 1);
    final foldedNames = List<String>.generate(
      count,
      (index) {
        final folded = foldForSearch(names[index]);
        starts[index] = folded.length + 1;
        return folded;
      },
      growable: false,
    );
    var offset = 0;
    for (var index = 0; index < count; index++) {
      final length = starts[index];
      starts[index] = offset;
      offset += length;
    }
    starts[count] = offset;

    final folded = Uint8List(offset);
    for (var index = 0; index < count; index++) {
      _toBytes(foldedNames[index], folded, starts[index]);
      folded[starts[index + 1] - 1] = 0x0A;
    }

    return GazetteerIndex._(
      provinceName: metadata['province_name']?.toString() ?? '',
      attribution: metadata['attribution']?.toString() ?? '',
      coverageNote: metadata['coverage_note']?.toString(),
      names: names,
      folded: folded,
      starts: starts,
      typeIds: packedTypes,
      contextIds: packedContexts,
      latitudeE5: Int32List.fromList(latitudeE5),
      longitudeE5: Int32List.fromList(longitudeE5),
      types: types,
      contexts: contexts,
      coordinateScale:
          (metadata['coordinate_scale'] as num?)?.toInt() ?? 100000,
    );
  }

  /// Best matches for [query], nearest first within each match class.
  ///
  /// Ranking is the whole difference between this feeling useful and feeling
  /// broken, because the duplicate names are not near-misses — they are 75
  /// genuinely different lakes. So a name that *starts* with what was typed
  /// beats one that merely contains it, and inside each of those two classes
  /// the one nearest [latitude], [longitude] wins. That is the current map
  /// centre, which is the only thing the app knows about what the user means.
  PlaceResults search(
    String query, {
    required double latitude,
    required double longitude,
    int limit = 50,
  }) {
    final folded = foldForSearch(query);
    if (folded.length < gazetteerMinimumQueryLength) return PlaceResults.empty;
    final needle = _toBytes(folded, Uint8List(folded.length), 0);

    // Never more slots than there are records, so a caller asking for
    // everything cannot ask for an array bigger than the index.
    final capacity = math.min(limit, _names.length);
    if (capacity <= 0) return PlaceResults.empty;

    // Only the best [limit] are ever shown, and a common query matches tens of
    // thousands of records — "la" matches 31,712 Ontario names. Sorting all of
    // those to throw away all but fifty was costing 69 ms; keeping a bounded
    // best-so-far costs one comparison per match.
    final keys = Float64List(capacity);
    final records = Int32List(capacity);
    var kept = 0;
    var total = 0;
    var worst = double.infinity;

    final scale = coordinateScale;
    final blob = _folded;
    final starts = _starts;
    final latitudeE5 = _latitudeE5;
    final longitudeE5 = _longitudeE5;
    final centreLatitudeRadians = latitude * _toRadians;
    final cosCentreLatitude = math.cos(centreLatitudeRadians);
    final centreLongitudeRadians = longitude * _toRadians;

    // How far north or south a match can be and still be worth measuring, in
    // the index's own scaled integers. Nearness is at least sin²(Δlat/2), so a
    // record outside this band cannot beat what is already kept, and is
    // dropped on one integer comparison instead of three trigonometric calls.
    // On a two-letter Quebec query that skips most of the province.
    final centreLatitudeE5 = (latitude * scale).round();
    var latitudeBandE5 = 0x7fffffff;

    // Matches arrive in increasing offset, so the record they fall in only ever
    // moves forward. A binary search per match cost more than the whole scan on
    // a two-letter query, which matches 75,346 Quebec names.
    var record = 0;
    var at = 0;
    while (true) {
      at = _findBytes(blob, needle, at);
      if (at < 0) break;
      while (starts[record + 1] <= at) {
        record++;
      }
      total++;

      final isPrefix = at == starts[record];
      if (kept == capacity) {
        final keptAllPrefix = worst < 2;
        if (keptAllPrefix && !isPrefix) {
          // Nothing that merely contains the query can join a full list of
          // names that start with it, however close it is.
          at = starts[record + 1];
          continue;
        }
        // The band was derived from the match at the bottom of the list, so it
        // only speaks for its own class. A prefix match against a list still
        // holding interior ones always competes, whatever its distance.
        if (isPrefix == keptAllPrefix) {
          final offset = latitudeE5[record] - centreLatitudeE5;
          if (offset > latitudeBandE5 || -offset > latitudeBandE5) {
            at = starts[record + 1];
            continue;
          }
        }
      }

      // Haversine's `a` rather than the distance itself: it rises with distance,
      // so it ranks identically, and it skips the square root and arc sine on
      // every one of tens of thousands of matches. The metres are worked out
      // below, for the fifty that survive.
      final deltaLatitude =
          latitudeE5[record] / scale * _toRadians - centreLatitudeRadians;
      final deltaLongitude =
          longitudeE5[record] / scale * _toRadians - centreLongitudeRadians;
      final sinLatitude = math.sin(deltaLatitude / 2);
      final sinLongitude = math.sin(deltaLongitude / 2);
      final nearness = sinLatitude * sinLatitude +
          cosCentreLatitude *
              math.cos(latitudeE5[record] / scale * _toRadians) *
              sinLongitude *
              sinLongitude;
      // One sortable number for "prefix first, then nearest". `a` never exceeds
      // 1, so no interior match can undercut a prefix match on nearness alone.
      final key = isPrefix ? nearness : 2 + nearness;
      if (kept < capacity) {
        var slot = kept++;
        while (slot > 0 && keys[slot - 1] > key) {
          keys[slot] = keys[slot - 1];
          records[slot] = records[slot - 1];
          slot--;
        }
        keys[slot] = key;
        records[slot] = record;
      } else if (key < worst) {
        var slot = capacity - 1;
        while (slot > 0 && keys[slot - 1] > key) {
          keys[slot] = keys[slot - 1];
          records[slot] = records[slot - 1];
          slot--;
        }
        keys[slot] = key;
        records[slot] = record;
      } else {
        at = starts[record + 1];
        continue;
      }

      if (kept == capacity && keys[capacity - 1] != worst) {
        worst = keys[capacity - 1];
        final bound = worst < 2 ? worst : worst - 2;
        latitudeBandE5 = bound >= 1
            ? 0x7fffffff
            : (2 * math.asin(math.sqrt(bound)) / _toRadians * scale).ceil();
      }

      // Straight past the rest of this name: a second occurrence inside it is
      // the same place, and scanning for one would only find it again.
      at = starts[record + 1];
    }

    return PlaceResults(
      total: total,
      matches: List<PlaceMatch>.generate(kept, (slot) {
        final record = records[slot];
        final context = _contexts[_contextIds[record]];
        final key = keys[slot];
        final isPrefix = key < 2;
        final nearness = isPrefix ? key : key - 2;
        return PlaceMatch(
          name: _names[record],
          featureType: _types[_typeIds[record]],
          context: context.isEmpty ? provinceName : context,
          latitude: latitudeE5[record] / scale,
          longitude: longitudeE5[record] / scale,
          distanceMetres:
              2 * _earthRadius * math.asin(math.min(1, math.sqrt(nearness))),
          isPrefixMatch: isPrefix,
        );
      }, growable: false),
    );
  }

  /// Folds already-folded text down to one byte per character.
  ///
  /// Everything above ASCII becomes the same sentinel. The real data has none
  /// left after [foldForSearch] — the 27 characters that occur in the Ontario
  /// and Quebec name columns are all in its table — and applying this to the
  /// query as well as the records keeps the two agreeing whatever turns up.
  static Uint8List _toBytes(String folded, Uint8List into, int at) {
    for (var index = 0; index < folded.length; index++) {
      final unit = folded.codeUnitAt(index);
      into[at + index] = unit < 0x80 ? unit : 0xFF;
    }
    return into;
  }

  static List<String> _stringList(Object? value, String field) {
    if (value is! List) {
      throw FormatException('The place-name index field "$field" is missing.');
    }
    return List<String>.generate(
      value.length,
      (index) => value[index].toString(),
      growable: false,
    );
  }

  static List<int> _intList(Object? value, String field) {
    if (value is! List) {
      throw FormatException('The place-name index field "$field" is missing.');
    }
    return List<int>.generate(value.length, (index) {
      final entry = value[index];
      if (entry is! num) {
        throw FormatException(
          'The place-name index field "$field" holds a non-number.',
        );
      }
      return entry.toInt();
    }, growable: false);
  }
}

/// Offset of the first [needle] in [blob] at or after [from], or -1.
///
/// Deliberately its own small function. The same loop written inline inside
/// [GazetteerIndex.search], sharing a body with the distance and ranking work,
/// measured about three times slower on the real Ontario index — 6.5 ms a
/// keystroke against 2.2 ms — because that work is what stops the compiler
/// keeping this loop tight. It is the hottest code in the app: it runs over
/// every character of every name in the province on each keystroke.
///
/// `String.indexOf` over the same characters was measured at 6.8 ms, so this
/// is not reimplementing something the platform does better.
int _findBytes(Uint8List blob, Uint8List needle, int from) {
  final first = needle[0];
  final needleLength = needle.length;
  final last = blob.length - needleLength;
  var at = from;
  while (at <= last) {
    if (blob[at] != first) {
      at++;
      continue;
    }
    var step = 1;
    while (step < needleLength && blob[at + step] == needle[step]) {
      step++;
    }
    if (step == needleLength) return at;
    at++;
  }
  return -1;
}

/// Mean earth radius, IUGG. Distances here are haversine on a sphere, which is
/// good to a few metres per kilometre against the ellipsoid — far inside the
/// error of a gazetteer point that stands for a whole lake.
const _earthRadius = 6371008.8;

const _toRadians = math.pi / 180;
