import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/settings/visibility_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<VisibilitySettings> restart() async {
    final settings = VisibilitySettings();
    await settings.loadPreferences();
    return settings;
  }

  group('the resolution rule', () {
    test('an item with no hidden tags and not individually hidden is shown', () {
      final settings = VisibilitySettings();
      expect(settings.isHiddenOnMap('w1', ['ridge', 'creek']), isFalse);
    });

    test('an individually hidden item is hidden', () async {
      final settings = await restart();
      await settings.setItemHidden('w1', hidden: true);
      expect(settings.isHiddenOnMap('w1', ['ridge']), isTrue);
    });

    test('an item carrying one hidden and one shown tag is hidden', () async {
      final settings = await restart();
      await settings.setTagHidden('ridge', hidden: true);
      expect(settings.isHiddenOnMap('w1', ['ridge', 'creek']), isTrue);
    });

    // The inverse of the rule above: both tags shown, item is shown.
    test('an item whose tags are all shown is shown', () async {
      final settings = await restart();
      await settings.setTagHidden('ridge', hidden: true);
      await settings.setTagHidden('ridge', hidden: false);
      expect(settings.isHiddenOnMap('w1', ['ridge', 'creek']), isFalse);
    });

    test('an untagged item is hidden only when individually hidden', () async {
      final settings = await restart();
      expect(settings.isHiddenOnMap('w1', []), isFalse);
      await settings.setItemHidden('w1', hidden: true);
      expect(settings.isHiddenOnMap('w1', []), isTrue);
    });

    test('hiding a tag no item carries does nothing surprising', () async {
      final settings = await restart();
      await settings.setTagHidden('nonexistent', hidden: true);
      expect(settings.isHiddenOnMap('w1', ['ridge']), isFalse);
      expect(settings.isTagHidden('nonexistent'), isTrue);
    });
  });

  group('hidingTagsFor explains which tags are responsible', () {
    test('names the hidden tags an item carries', () async {
      final settings = await restart();
      await settings.setTagHidden('ridge', hidden: true);
      await settings.setTagHidden('creek', hidden: true);
      expect(settings.hidingTagsFor(['ridge', 'creek', 'other']),
          ['ridge', 'creek']);
    });

    test('returns nothing when the item is only individually hidden', () async {
      final settings = await restart();
      await settings.setItemHidden('w1', hidden: true);
      expect(settings.hidingTagsFor(['ridge']), isEmpty);
    });
  });

  group('persistence', () {
    test('hidden items survive a reload', () async {
      final first = await restart();
      await first.setItemHidden('w1', hidden: true);
      await first.setItemHidden('w2', hidden: true);

      final second = await restart();
      expect(second.isItemHidden('w1'), isTrue);
      expect(second.isItemHidden('w2'), isTrue);
    });

    test('hidden tags survive a reload', () async {
      final first = await restart();
      await first.setTagHidden('ridge', hidden: true);

      final second = await restart();
      expect(second.isTagHidden('ridge'), isTrue);
    });

    test('unhiding an item is persisted', () async {
      final first = await restart();
      await first.setItemHidden('w1', hidden: true);
      await first.setItemHidden('w1', hidden: false);

      final second = await restart();
      expect(second.isItemHidden('w1'), isFalse);
    });

    test('unhiding a tag is persisted', () async {
      final first = await restart();
      await first.setTagHidden('ridge', hidden: true);
      await first.setTagHidden('ridge', hidden: false);

      final second = await restart();
      expect(second.isTagHidden('ridge'), isFalse);
    });

    // Same principle as DisplaySettings: an empty set writes nothing, so a
    // fresh install is not pinned to whatever set of ids shipped.
    test('nothing written when everything is visible', () async {
      await restart();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('visibility.hidden_items'), isNull);
      expect(prefs.getStringList('visibility.hidden_tags'), isNull);
    });

    test('unhiding the last item clears the preference', () async {
      final settings = await restart();
      await settings.setItemHidden('w1', hidden: true);
      await settings.setItemHidden('w1', hidden: false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('visibility.hidden_items'), isNull);
    });
  });

  group('notifications', () {
    test('hiding and unhiding notifies', () async {
      final settings = await restart();
      var count = 0;
      settings.addListener(() => count++);

      await settings.setItemHidden('w1', hidden: true);
      await settings.setTagHidden('ridge', hidden: true);
      expect(count, 2);

      await settings.setItemHidden('w1', hidden: false);
      await settings.setTagHidden('ridge', hidden: false);
      expect(count, 4);
    });

    test('a no-op does not notify', () async {
      final settings = await restart();
      var count = 0;
      settings.addListener(() => count++);

      await settings.setItemHidden('w1', hidden: false);
      await settings.setTagHidden('ridge', hidden: false);
      expect(count, 0);
    });

    test('loading notifies', () async {
      SharedPreferences.setMockInitialValues({
        'visibility.hidden_items': ['w1'],
      });
      final settings = VisibilitySettings();
      var count = 0;
      settings.addListener(() => count++);

      await settings.loadPreferences();
      expect(count, 1);
      expect(settings.isItemHidden('w1'), isTrue);
    });
  });

  group('the map source', () {
    // Stand-in for the filtering the map shell does when building its
    // GeoJSON source: same predicate, no MapLibre dependency.
    List<String> visibleIds(
      VisibilitySettings settings,
      List<({String id, List<String> tags})> items,
    ) => [
      for (final item in items)
        if (!settings.isHiddenOnMap(item.id, item.tags)) item.id,
    ];

    test('excludes an individually hidden item', () async {
      final settings = await restart();
      await settings.setItemHidden('w2', hidden: true);

      expect(
        visibleIds(settings, [
          (id: 'w1', tags: ['ridge']),
          (id: 'w2', tags: ['ridge']),
          (id: 'w3', tags: ['creek']),
        ]),
        ['w1', 'w3'],
      );
    });

    test('excludes everything under a hidden tag', () async {
      final settings = await restart();
      await settings.setTagHidden('ridge', hidden: true);

      expect(
        visibleIds(settings, [
          (id: 'w1', tags: ['ridge', 'creek']),
          (id: 'w2', tags: ['ridge']),
          (id: 'w3', tags: ['creek']),
        ]),
        ['w3'],
      );
    });

    test('excludes nothing when nothing is hidden', () async {
      final settings = await restart();
      expect(
        visibleIds(settings, [
          (id: 'w1', tags: ['ridge']),
          (id: 'w2', tags: <String>[]),
        ]),
        ['w1', 'w2'],
      );
    });
  });
}
