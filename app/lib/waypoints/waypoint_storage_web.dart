import 'package:shared_preferences/shared_preferences.dart';

const _key = 'open_woods_map_waypoints';
const _asideKey = 'open_woods_map_waypoints_unreadable';

Future<String?> readWaypointJson() async {
  final preferences = await SharedPreferences.getInstance();
  return preferences.getString(_key);
}

Future<void> writeWaypointJson(String json) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(_key, json);
}

Future<String?> setAsideWaypointJson() async {
  final preferences = await SharedPreferences.getInstance();
  final text = preferences.getString(_key);
  if (text == null) return null;
  await preferences.setString(_asideKey, text);
  await preferences.remove(_key);
  return _asideKey;
}
