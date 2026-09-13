import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_woods_map/offline/pack_index.dart';

/// The index as `tools/gis/build_pack.py` writes it, copied from a real build.
/// Kept verbatim so a change to the writer that this parser cannot read shows up
/// here rather than on someone's phone.
const _published = '''
{
  "packs": {
    "on": {
      "built": "2026-09-13T01:59:56Z",
      "bytes": 16596407,
      "content_id": "67665dcf783e5c00",
      "file": "on-overlays.zip",
      "version": "0.13.0"
    },
    "qc": {
      "built": "2026-09-13T01:59:54Z",
      "bytes": 3825688,
      "content_id": "c132d76fc510eaa9",
      "file": "qc-overlays.zip",
      "version": "0.1.0"
    }
  }
}
''';

void main() {
  group('reading the published index', () {
    test('parses what build_pack.py writes', () {
      final index = PackIndex.tryParse(_published)!;
      expect(index['on']!.contentId, '67665dcf783e5c00');
      expect(index['on']!.built, DateTime.utc(2026, 9, 13, 1, 59, 56));
      expect(index['on']!.bytes, 16596407);
      expect(index['on']!.version, '0.13.0');
      expect(index['qc']!.contentId, 'c132d76fc510eaa9');
    });

    test('province ids match however they are cased', () {
      final index = PackIndex.tryParse(_published)!;
      expect(index['ON'], isNotNull);
    });

    test('a province with no published pack is absent, not empty', () {
      expect(PackIndex.tryParse(_published)!['bc'], isNull);
    });

    // A captive portal or a misconfigured release serves HTML with a 200. The
    // screen has honest wording for not knowing, so refusing to parse is better
    // than reading a date out of a login page.
    test('anything that is not an index is refused', () {
      expect(PackIndex.tryParse('<html>Sign in</html>'), isNull);
      expect(PackIndex.tryParse('{"packs": "soon"}'), isNull);
      expect(PackIndex.tryParse('[]'), isNull);
      expect(PackIndex.tryParse(''), isNull);
    });

    // One malformed entry must not cost the other province its answer, because
    // the two are published independently and one is a preview.
    test('a bad entry is dropped and the rest survive', () {
      final index = PackIndex.tryParse(
        '{"packs": {"on": {"content_id": "abc"}, "qc": "broken"}}',
      )!;
      expect(index['on']!.contentId, 'abc');
      expect(index['on']!.built, isNull);
      expect(index['qc'], isNull);
    });
  });

  group('fetching it', () {
    test('reads a 200', () async {
      final index = await fetchPackIndex(
        'https://example.invalid/packs.json',
        client: MockClient((_) async => http.Response(_published, 200)),
      );
      expect(index!['on']!.contentId, '67665dcf783e5c00');
    });

    // Every failure below is the same answer to the caller. The screen says
    // "could not check", which is true of all of them, rather than reporting a
    // network error the user cannot act on while standing in the bush.
    test('a missing index is not an error, just no answer', () async {
      final index = await fetchPackIndex(
        'https://example.invalid/packs.json',
        client: MockClient((_) async => http.Response('Not Found', 404)),
      );
      expect(index, isNull);
    });

    test('no signal returns null rather than throwing', () async {
      final index = await fetchPackIndex(
        'https://example.invalid/packs.json',
        client: MockClient(
          (_) async => throw const SocketException('Network is unreachable'),
        ),
      );
      expect(index, isNull);
    });

    test('a slow network gives up instead of holding the screen', () async {
      final index = await fetchPackIndex(
        'https://example.invalid/packs.json',
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.Response(_published, 200);
        }),
        timeout: const Duration(milliseconds: 20),
      );
      expect(index, isNull);
    });

    test('accented text in a future index survives the decode', () async {
      final body = jsonEncode({
        'packs': {
          'qc': {'content_id': 'abc', 'note': 'Forêt publique québécoise'},
        },
      });
      final index = await fetchPackIndex(
        'https://example.invalid/packs.json',
        client: MockClient(
          (_) async => http.Response.bytes(utf8.encode(body), 200),
        ),
      );
      expect(index!['qc']!.contentId, 'abc');
    });
  });
}
