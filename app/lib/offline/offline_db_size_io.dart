import 'dart:io';

import 'package:maplibre_gl/maplibre_gl.dart';

/// How much space the offline tile store actually occupies.
///
/// Worth measuring rather than adding up the per-area figures: MapLibre stores
/// each tile once and reference-counts it, so two overlapping areas each report
/// the full weight of the tiles they share. The parts genuinely do sum to more
/// than the whole, and only the file knows the truth.
Future<int?> offlineDatabaseBytes() async {
  try {
    final path = await getOfflineDatabasePath();
    if (path == null) return null;
    var total = 0;
    // The write-ahead log holds committed pages that have not been folded back
    // into the main file yet, and right after a download it can be the larger
    // of the two.
    for (final candidate in [path, '$path-wal']) {
      final file = File(candidate);
      if (file.existsSync()) total += await file.length();
    }
    return total;
  } on Object {
    return null;
  }
}
