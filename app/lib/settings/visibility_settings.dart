import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which waypoints, tracks, and tags are hidden from the map.
///
/// "Hidden" means not drawn on the map. The item stays in the saved list,
/// because the list is the only place to get it back. Persisted so someone who
/// hides a large tag expects it still hidden tomorrow.
///
/// View state only — never written into the waypoint or track records
/// themselves, and never affecting what export sees.
class VisibilitySettings extends ChangeNotifier {
  VisibilitySettings();

  static const _hiddenItemsKey = 'visibility.hidden_items';
  static const _hiddenTagsKey = 'visibility.hidden_tags';

  Set<String> _hiddenItemIds = {};
  Set<String> _hiddenTags = {};

  Set<String> get hiddenItemIds => Set.unmodifiable(_hiddenItemIds);
  Set<String> get hiddenTags => Set.unmodifiable(_hiddenTags);

  bool isItemHidden(String id) => _hiddenItemIds.contains(id);
  bool isTagHidden(String tag) => _hiddenTags.contains(tag);

  /// Whether the item should be left out of the map source.
  ///
  /// True when the item was individually hidden, or when any of its tags is
  /// hidden. One hidden tag is enough even when the item also carries a shown
  /// tag — the user's intent in hiding a tag was "everything under this tag
  /// disappears from the map".
  bool isHiddenOnMap(String id, List<String> tags) =>
      _hiddenItemIds.contains(id) || tags.any(_hiddenTags.contains);

  /// Which of the item's own tags are currently hidden.
  ///
  /// Empty when the item is only individually hidden or not hidden at all.
  /// The caller uses this to explain why a row's eye looks different when the
  /// item itself was never toggled but a tag is making it invisible on the map.
  List<String> hidingTagsFor(List<String> tags) =>
      tags.where(_hiddenTags.contains).toList();

  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _hiddenItemIds = (prefs.getStringList(_hiddenItemsKey) ?? []).toSet();
    _hiddenTags = (prefs.getStringList(_hiddenTagsKey) ?? []).toSet();
    notifyListeners();
  }

  Future<void> setItemHidden(String id, {required bool hidden}) async {
    final changed =
        hidden ? _hiddenItemIds.add(id) : _hiddenItemIds.remove(id);
    if (!changed) return;
    notifyListeners();
    await _persist();
  }

  Future<void> setTagHidden(String tag, {required bool hidden}) async {
    final changed = hidden ? _hiddenTags.add(tag) : _hiddenTags.remove(tag);
    if (!changed) return;
    notifyListeners();
    await _persist();
  }

  /// Written only when non-empty, removed when empty — same principle as
  /// [DisplaySettings]: a preference written by this build must not pin a
  /// later build's default.
  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_hiddenItemIds.isEmpty) {
      await prefs.remove(_hiddenItemsKey);
    } else {
      await prefs.setStringList(_hiddenItemsKey, _hiddenItemIds.toList());
    }
    if (_hiddenTags.isEmpty) {
      await prefs.remove(_hiddenTagsKey);
    } else {
      await prefs.setStringList(_hiddenTagsKey, _hiddenTags.toList());
    }
  }
}
