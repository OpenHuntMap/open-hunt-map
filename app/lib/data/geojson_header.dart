import 'dart:convert';

/// Extracts the top-level `metadata` object from the beginning of a GeoJSON
/// document.
///
/// Overlay files write `metadata` ahead of `features`, so [header] only needs
/// to be the first few kilobytes of the file. That matters for layers like
/// Ontario Crown land, where decoding the whole document to reach a 1 KB
/// object would mean parsing tens of megabytes of parcel geometry.
///
/// Returns an empty map when the object is absent, malformed, or runs past the
/// end of [header].
Map<String, dynamic> geoJsonMetadata(String? header) {
  const key = '"metadata"';
  if (header == null) return const {};
  final keyIndex = header.indexOf(key);
  if (keyIndex < 0) return const {};
  final start = header.indexOf('{', keyIndex + key.length);
  if (start < 0) return const {};

  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < header.length; i++) {
    final char = header[i];
    if (escaped) {
      escaped = false;
    } else if (inString) {
      if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
    } else if (char == '"') {
      inString = true;
    } else if (char == '{') {
      depth++;
    } else if (char == '}') {
      if (--depth == 0) {
        try {
          final value = jsonDecode(header.substring(start, i + 1));
          return value is Map<String, dynamic> ? value : const {};
        } catch (_) {
          return const {};
        }
      }
    }
  }
  return const {};
}
