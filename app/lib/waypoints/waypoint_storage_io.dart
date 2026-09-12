import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

Future<File> _file() async {
  final directory = await getApplicationDocumentsDirectory();
  return File(path.join(directory.path, 'open_woods_map_waypoints.json'));
}

Future<File> _tagStyleFile() async {
  final directory = await getApplicationDocumentsDirectory();
  return File(path.join(directory.path, 'open_woods_map_tag_styles.json'));
}

Future<String?> readWaypointJson() async {
  final file = await _file();
  return file.existsSync() ? file.readAsString() : null;
}

Future<void> writeWaypointJson(String json) async {
  final file = await _file();
  // Write beside the real file and rename onto it. `writeAsString` truncates
  // first, so a process killed mid-write leaves a short file where the user's
  // waypoints were, and rename is the only step the platform gives us that a
  // reader cannot observe halfway through.
  final staging = File('${file.path}.writing');
  await staging.writeAsString(json, flush: true);
  await staging.rename(file.path);
}

Future<String?> readTagStyleJson() async {
  final file = await _tagStyleFile();
  return file.existsSync() ? file.readAsString() : null;
}

Future<void> writeTagStyleJson(String json) async {
  final file = await _tagStyleFile();
  // Staged and renamed like the waypoints file. Losing tag styling is a small
  // loss, but a half-written file would be unparseable, and this costs nothing.
  final staging = File('${file.path}.writing');
  await staging.writeAsString(json, flush: true);
  await staging.rename(file.path);
}

/// Moves an unparseable waypoint file aside so the next save cannot bury it.
///
/// Returns the path it was moved to, for the message that tells the user their
/// file is still there. One slot only: a second failure is overwhelmingly the
/// same file failing again, and keeping a growing pile of them in the documents
/// directory helps nobody.
Future<String?> setAsideWaypointJson() async {
  final file = await _file();
  if (!file.existsSync()) return null;
  final aside = '${file.path}.unreadable';
  await file.rename(aside);
  return aside;
}
