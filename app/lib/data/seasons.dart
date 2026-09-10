/// Season pack model (schema 2).
///
/// The pack stores every scraped season row once in a shared list and gives
/// each WMU a list of indexes into it, because most rows cover dozens of units.
library;

enum SeasonStatus { open, upcoming, closed }

enum Residency { resident, nonResident, any }

extension ResidencyX on Residency {
  String get label => switch (this) {
        Residency.resident => 'Resident',
        Residency.nonResident => 'Non-resident',
        Residency.any => 'Resident & non-resident',
      };
}

class SeasonEntry {
  const SeasonEntry({
    required this.species,
    required this.speciesName,
    required this.group,
    required this.residency,
    required this.start,
    required this.end,
    this.label,
    this.limits,
    this.huntCode,
    this.notes,
    this.allYear = false,
  });

  final String species;
  final String speciesName;
  final String group;
  final Residency residency;
  final DateTime start;
  final DateTime end;

  /// Weapon class ("Bows only") or season name ("Spring"). Absent when the
  /// regulation table draws no such distinction.
  final String? label;
  final String? limits;
  final String? huntCode;
  final String? notes;
  final bool allYear;

  SeasonStatus statusOn(DateTime day) {
    if (day.isBefore(start)) return SeasonStatus.upcoming;
    if (day.isAfter(end)) return SeasonStatus.closed;
    return SeasonStatus.open;
  }

  /// Whole days until the season opens; negative once it has opened.
  int daysUntilOpen(DateTime day) => start.difference(day).inDays;

  int daysUntilClose(DateTime day) => end.difference(day).inDays;
}

class ProvinceSeasons {
  ProvinceSeasons({
    required this.province,
    required this.year,
    required this.yearLabel,
    required this.zoneKind,
    required this.disclaimer,
    required this.coverage,
    required this.sourceTitle,
    required this.sourceUrl,
    required this.regsUrl,
    required this.generated,
    required this.groupLabels,
    required this.seasons,
    required this.units,
    required this.validFrom,
    required this.validTo,
  }) : _byNormalizedUnit = {
          for (final entry in units.entries) _normalize(entry.key): entry.value,
        };

  final String province;
  final int year;
  final String yearLabel;
  final String zoneKind;
  final String disclaimer;
  final String coverage;
  final String sourceTitle;
  final String sourceUrl;
  final String regsUrl;
  final String generated;
  final Map<String, String> groupLabels;
  final List<SeasonEntry> seasons;
  final Map<String, List<int>> units;
  final DateTime? validFrom;
  final DateTime? validTo;

  /// The map layer and the regulation tables spell subunits differently
  /// ("69A-1" vs "69A1"), so units are also reachable by a stripped key.
  final Map<String, List<int>> _byNormalizedUnit;

  List<SeasonEntry> forUnit(String? unitId) {
    if (unitId == null || unitId.isEmpty) return const [];
    final indexes = units[unitId] ?? _byNormalizedUnit[_normalize(unitId)];
    if (indexes == null) return const [];
    return [
      for (final index in indexes)
        if (index >= 0 && index < seasons.length) seasons[index],
    ];
  }

  bool get hasUnits => units.isNotEmpty;

  /// False once the calendar has moved past the regulation year this pack
  /// covers, which means open/closed answers can no longer be trusted.
  bool coversDate(DateTime day) {
    if (validFrom == null || validTo == null) return true;
    return !day.isBefore(validFrom!) && !day.isAfter(validTo!);
  }

  String groupLabel(String id) =>
      groupLabels[id] ?? id.replaceAll('_', ' ');

  static String _normalize(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  factory ProvinceSeasons.fromJson(Map<String, dynamic> json) {
    final source = json['source'] as Map<String, dynamic>? ?? const {};
    final labels = _stringMap(json['species_labels']);
    final groups = _stringMap(json['species_groups']);

    final seasons = (json['seasons'] as List<dynamic>? ?? const [])
        .map((item) => _entry(item as Map<String, dynamic>, labels, groups))
        .toList();

    final units = <String, List<int>>{};
    for (final entry in (json['units'] as Map<String, dynamic>? ?? const {})
        .entries) {
      final value = entry.value;
      // Schema 2 stores indexes; tolerate the older inline-object shape.
      if (value is List) {
        units[entry.key] = value.whereType<num>().map((n) => n.toInt()).toList();
      }
    }

    return ProvinceSeasons(
      province: json['province'] as String? ?? '',
      year: json['year'] as int? ?? 0,
      yearLabel: json['season_year_label'] as String? ??
          (json['year'] as int? ?? 0).toString(),
      zoneKind: json['zone_kind'] as String? ?? 'wmu',
      disclaimer: json['disclaimer'] as String? ?? '',
      coverage: source['coverage'] as String? ?? '',
      sourceTitle: source['title'] as String? ?? 'Hunting seasons',
      sourceUrl: source['url'] as String? ?? '',
      regsUrl: source['regs_summary_url'] as String? ?? '',
      generated: json['generated'] as String? ?? '',
      groupLabels: _stringMap(json['group_labels']),
      seasons: seasons,
      units: units,
      validFrom: _date(json['season_year_start']),
      validTo: _date(json['season_year_end']),
    );
  }

  static SeasonEntry _entry(
    Map<String, dynamic> json,
    Map<String, String> labels,
    Map<String, String> groups,
  ) {
    final species = json['species'] as String? ?? '';
    return SeasonEntry(
      species: species,
      speciesName: labels[species] ?? species.replaceAll('_', ' '),
      group: groups[species] ?? 'other',
      residency: switch (json['residency']) {
        'non_resident' => Residency.nonResident,
        'any' => Residency.any,
        _ => Residency.resident,
      },
      start: _date(json['start']) ?? DateTime(1970),
      end: _date(json['end']) ?? DateTime(1970),
      label: json['label'] as String?,
      limits: json['limits'] as String?,
      huntCode: json['hunt_code'] as String?,
      notes: json['notes'] as String?,
      allYear: json['all_year'] == true,
    );
  }

  static Map<String, String> _stringMap(Object? value) => {
        if (value is Map)
          for (final entry in value.entries)
            entry.key.toString(): entry.value.toString(),
      };

  static DateTime? _date(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}
