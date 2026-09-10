import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/data/seasons.dart';

/// Mirrors the shape emitted by tools/gis/scrape_seasons_on.py.
Map<String, dynamic> _pack() => {
      'province': 'on',
      'year': 2026,
      'schema': 2,
      'season_year_label': '2026–27',
      'season_year_start': '2026-04-01',
      'season_year_end': '2027-03-31',
      'generated': '2026-09-08',
      'source': {'title': 'Ontario Hunting Regulations Summary'},
      'species_labels': {
        'white_tailed_deer': 'White-tailed deer',
        'snowshoe_varying_hare': 'Snowshoe (varying) hare',
      },
      'species_groups': {
        'white_tailed_deer': 'big_game',
        'snowshoe_varying_hare': 'small_game',
      },
      'group_labels': {'big_game': 'Big game', 'small_game': 'Small game'},
      'seasons': [
        {
          'species': 'white_tailed_deer',
          'label': 'Bows only',
          'residency': 'resident',
          'start': '2026-10-01',
          'end': '2026-11-01',
        },
        {
          'species': 'white_tailed_deer',
          'label': 'Bows only',
          'residency': 'non_resident',
          'start': '2026-10-01',
          'end': '2026-11-01',
        },
        {
          'species': 'snowshoe_varying_hare',
          'residency': 'any',
          'start': '2026-09-15',
          'end': '2027-03-31',
          'limits': 'Daily limit of five',
        },
      ],
      'units': {
        '65': [2, 0, 1],
        '69A-1': [2],
      },
    };

void main() {
  final pack = ProvinceSeasons.fromJson(_pack());

  test('resolves per-unit indexes into season rows', () {
    final seasons = pack.forUnit('65');
    expect(seasons, hasLength(3));
    expect(
      seasons.map((season) => season.species).toSet(),
      {'white_tailed_deer', 'snowshoe_varying_hare'},
    );
    expect(seasons.first.speciesName, 'Snowshoe (varying) hare');
    expect(seasons.first.group, 'small_game');
  });

  test('matches units whose ids differ only in separators', () {
    expect(pack.forUnit('69A1'), hasLength(1));
    expect(pack.forUnit('69A-1'), hasLength(1));
  });

  test('returns nothing for an unmapped or missing unit', () {
    expect(pack.forUnit('999'), isEmpty);
    expect(pack.forUnit(null), isEmpty);
    expect(pack.forUnit(''), isEmpty);
  });

  test('classifies a season as upcoming, open, then closed', () {
    final deer = pack.forUnit('65').firstWhere(
          (season) => season.species == 'white_tailed_deer',
        );
    expect(deer.statusOn(DateTime(2026, 9, 20)), SeasonStatus.upcoming);
    expect(deer.statusOn(DateTime(2026, 10, 1)), SeasonStatus.open);
    expect(deer.statusOn(DateTime(2026, 10, 15)), SeasonStatus.open);
    expect(deer.statusOn(DateTime(2026, 11, 1)), SeasonStatus.open);
    expect(deer.statusOn(DateTime(2026, 11, 2)), SeasonStatus.closed);
  });

  test('counts whole days to the next opening and closing', () {
    final deer = pack.forUnit('65').firstWhere(
          (season) => season.species == 'white_tailed_deer',
        );
    expect(deer.daysUntilOpen(DateTime(2026, 9, 24)), 7);
    expect(deer.daysUntilClose(DateTime(2026, 10, 25)), 7);
  });

  test('flags a pack that no longer covers today', () {
    expect(pack.coversDate(DateTime(2026, 10, 1)), isTrue);
    expect(pack.coversDate(DateTime(2027, 3, 31)), isTrue);
    expect(pack.coversDate(DateTime(2027, 4, 1)), isFalse);
    expect(pack.coversDate(DateTime(2026, 3, 31)), isFalse);
  });

  test('keeps residency and limits from the regulation table', () {
    final seasons = pack.forUnit('65');
    final hare = seasons.firstWhere((s) => s.species == 'snowshoe_varying_hare');
    expect(hare.residency, Residency.any);
    expect(hare.limits, 'Daily limit of five');
    expect(
      seasons.where((s) => s.residency == Residency.nonResident),
      hasLength(1),
    );
  });
}
