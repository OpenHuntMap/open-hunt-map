/// See `style_server_io.dart`. Offline regions do not exist on web, so nothing
/// ever asks this to serve a style.
class StyleServer {
  Future<String> serve(String documentJson) async {
    throw UnsupportedError('Offline basemap areas are not available on web.');
  }

  Future<void> close() async {}
}
