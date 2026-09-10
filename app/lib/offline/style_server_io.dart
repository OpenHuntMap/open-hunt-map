import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Serves a style document over loopback so MapLibre's offline downloader can
/// read it.
///
/// The downloader resolves a region's style through the *network* file source,
/// which refuses `asset://` and `file://` outright
/// (maplibre/maplibre-native#609). The satellite and hybrid styles are bundled
/// assets, and the copy the downloader needs is pruned per area anyway, so
/// there is nothing to point it at on the public internet.
///
/// Publishing the styles to a web host would work, but it would put a network
/// dependency and a second copy in front of a file we already ship, and the two
/// would drift. A socket on 127.0.0.1 keeps the bundled asset as the only
/// source of truth. It is bound to loopback, holds only style JSON, and is shut
/// down as soon as the download finishes.
class StyleServer {
  HttpServer? _server;
  final Map<String, String> _documents = {};
  final Random _random = Random.secure();

  /// Publishes [documentJson] and returns the URL to fetch it from.
  Future<String> serve(String documentJson) async {
    final server = await _ensureServer();
    final token = List.generate(
      16,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    _documents[token] = documentJson;
    return 'http://${server.address.address}:${server.port}/$token.json';
  }

  Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    _server = server;
    unawaited(_listen(server));
    return server;
  }

  Future<void> _listen(HttpServer server) async {
    try {
      await for (final request in server) {
        final segments = request.uri.pathSegments;
        final token = segments.isEmpty
            ? ''
            : segments.first.replaceAll('.json', '');
        final document = _documents[token];
        if (document == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('application', 'json')
            // The downloader must not reuse a style from an earlier area; the
            // pruned source list differs between them.
            ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
            ..add(utf8.encode(document));
        }
        await request.response.close();
      }
    } on Object {
      // close(force: true) tears the socket down mid-request. Nothing is
      // waiting on this loop, so an error here must not surface as an
      // unhandled exception.
    }
  }

  Future<void> close() async {
    _documents.clear();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
