import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/offline/style_server.dart';

/// The offline downloader reaches the pruned style over this socket and nothing
/// else does, so if it stops answering, saving a satellite or hybrid area fails
/// with a network error that looks like a server problem somewhere else.

Future<HttpClientResponse> get(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    return await request.close();
  } finally {
    client.close();
  }
}

Future<String> getBody(String url) async {
  final response = await get(url);
  return response.transform(utf8.decoder).join();
}

void main() {
  late StyleServer server;

  setUp(() => server = StyleServer());
  tearDown(() => server.close());

  test('serves the document it was given', () async {
    final document = json.encode({'version': 8, 'name': 'test'});
    final url = await server.serve(document);
    expect(await getBody(url), document);
  });

  test('stays on loopback', () async {
    final url = await server.serve('{}');
    expect(Uri.parse(url).host, '127.0.0.1');
  });

  test('answers as JSON, since MapLibre parses the body by content type',
      () async {
    final url = await server.serve('{}');
    final response = await get(url);
    expect(response.headers.contentType?.mimeType, 'application/json');
  });

  test('keeps two areas apart rather than serving the last one twice',
      () async {
    final ontario = await server.serve('{"name":"ontario"}');
    final quebec = await server.serve('{"name":"quebec"}');
    expect(ontario, isNot(quebec));
    expect(await getBody(ontario), '{"name":"ontario"}');
    expect(await getBody(quebec), '{"name":"quebec"}');
  });

  test('a URL that was never published is not found', () async {
    final url = await server.serve('{}');
    final base = Uri.parse(url);
    final response = await get(
      base.replace(path: '/deadbeefdeadbeef.json').toString(),
    );
    expect(response.statusCode, HttpStatus.notFound);
    await response.drain<void>();
  });

  test('closing releases the port and forgets the documents', () async {
    final url = await server.serve('{}');
    await server.close();
    await expectLater(get(url), throwsA(isA<SocketException>()));
  });

  test('can be used again after closing', () async {
    await server.serve('{"first":true}');
    await server.close();
    final url = await server.serve('{"second":true}');
    expect(await getBody(url), '{"second":true}');
  });
}
