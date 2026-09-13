import 'dart:convert';

import 'package:http/http.dart' as http;

/// What one province's published pack says about itself.
class PackIndexEntry {
  const PackIndexEntry({
    required this.built,
    required this.contentId,
    required this.bytes,
    required this.version,
  });

  final DateTime? built;
  final String? contentId;
  final int? bytes;
  final String? version;

  static PackIndexEntry? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    return PackIndexEntry(
      built: switch (value['built']) {
        final String text => DateTime.tryParse(text)?.toUtc(),
        _ => null,
      },
      contentId: switch (value['content_id']) {
        final String text when text.trim().isNotEmpty => text.trim(),
        _ => null,
      },
      bytes: switch (value['bytes']) {
        final num size when size > 0 => size.toInt(),
        _ => null,
      },
      version: value['version'] as String?,
    );
  }
}

/// The published packs, keyed by province id.
class PackIndex {
  const PackIndex(this.packs);

  final Map<String, PackIndexEntry> packs;

  PackIndexEntry? operator [](String provinceId) =>
      packs[provinceId.toLowerCase()];

  static PackIndex? tryParse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final packs = decoded['packs'];
      if (packs is! Map<String, dynamic>) return null;
      final entries = <String, PackIndexEntry>{};
      for (final MapEntry(:key, :value) in packs.entries) {
        final entry = PackIndexEntry.tryParse(value);
        if (entry != null) entries[key.toLowerCase()] = entry;
      }
      return PackIndex(entries);
    } on FormatException {
      return null;
    }
  }
}

/// Fetches the published pack index, or null if it cannot be had.
///
/// Every failure is null rather than an exception, because the caller is a
/// screen that must work with no signal. Not knowing what is published is a
/// normal state for this app, not an error to report.
///
/// The timeout is short on purpose: this file is a few hundred bytes and the
/// screen it informs is usable without it, so a slow network should leave the
/// page saying "could not check" rather than holding a spinner.
Future<PackIndex?> fetchPackIndex(
  String url, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final ownsClient = client == null;
  final http.Client active = client ?? http.Client();
  try {
    final response = await active.get(Uri.parse(url)).timeout(timeout);
    if (response.statusCode != 200) return null;
    return PackIndex.tryParse(utf8.decode(response.bodyBytes));
  } on Object {
    // Offline, DNS failure, timeout, TLS problem, a proxy serving a login page.
    // None of them are worth distinguishing here: the screen says the same
    // thing for all of them.
    return null;
  } finally {
    if (ownsClient) active.close();
  }
}
