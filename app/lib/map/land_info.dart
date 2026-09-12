import 'package:collection/collection.dart';

import '../data/models.dart';

class LandInfo {
  const LandInfo({
    required this.latitude,
    required this.longitude,
    required this.hits,
    required this.attribution,
  });

  final double latitude;
  final double longitude;
  final List<LandFeature> hits;
  final String attribution;

  /// Lower/single-tier municipality used for local bylaw lookup.
  LandFeature? get municipality =>
      hits.firstWhereOrNull((feature) => feature.layerId == 'municipalities');

  /// Prefer municipality name; many Ontario municipalities are titled
  /// "Township of …" even though they are municipal governments.
  String? get localGovernmentLabel {
    final feature = municipality;
    if (feature == null) return null;
    final name = feature.name?.trim();
    if (name == null || name.isEmpty) return null;
    final upper = feature.properties['upper_tier']?.toString().trim();
    if (upper != null && upper.isNotEmpty && !name.contains(upper)) {
      return '$name ($upper)';
    }
    return name;
  }

  /// A Crown game preserve closes ground that the tenure layers underneath it
  /// still describe as ordinary Crown land, so it is reported first.
  LandFeature? get gamePreserve =>
      hits.firstWhereOrNull((feature) => feature.layerId == 'game_preserve');

  /// A National Wildlife Area or Migratory Bird Sanctuary. Closes ground for the
  /// same reason a game preserve does, under federal rather than provincial law.
  LandFeature? get federalClosure =>
      hits.firstWhereOrNull((feature) => feature.layerId == 'federal_closure');

  /// Conservation authority land, which is neither open nor closed: it needs the
  /// authority's own permit. Note that a null here means only that CPCAD has no
  /// polygon at this point, not that the land is free of a conservation
  /// authority — the source is incomplete and the card says so.
  LandFeature? get conservationAuthority => hits.firstWhereOrNull(
      (feature) => feature.layerId == 'conservation_authority');

  /// National Defence property, closed to public hunting.
  LandFeature? get defenceLand =>
      hits.firstWhereOrNull((feature) => feature.layerId == 'defence_land');

  /// True north of the Far North boundary, where the Crown Land Use Policy
  /// Atlas thins out to nothing. A parcel with no policy report up here has
  /// almost certainly not been reached by the atlas, which is not the same
  /// thing as no policy applying to it.
  bool get inFarNorth => hits.any((feature) =>
      feature.layerId == 'land_use_plan' &&
      feature.properties['plan_scope'] == 'far_north');

  /// The community based land use plan covering this point, if any. Direction
  /// for how Crown land is managed, never a hunting regulation.
  LandFeature? get communityLandUsePlan => hits.firstWhereOrNull((feature) =>
      feature.layerId == 'land_use_plan' &&
      feature.properties['plan_scope'] == 'community');

  /// Every layer at this point that closes it outright, in the order the card
  /// should lead with. A federal wildlife area that authorises waterfowl stays
  /// out, because it is `conditional` rather than a no: it belongs in the
  /// land-use list with its conditions, not behind a banner that says no.
  ///
  /// Read off the land-use list rather than a hand-kept set of layer ids,
  /// because that set left `parks` out. Inside Bonnechere Provincial Park, which
  /// O. Reg. 663/98 never opened, the card led with a green Sunday-gun tick,
  /// then "General rules apply, no local policy", then "Occupied", and reached
  /// "No hunting — park not opened" four screens down. Any layer that says not
  /// permitted now leads, and a layer added later cannot be forgotten here.
  List<LandFeature> get closures =>
      landUse.where((feature) => feature.huntingAllowed == false).toList();

  /// Set only where Sunday gun hunting is permitted. Its absence is meaningful
  /// rather than missing: south of the French and Mattawa rivers an unlisted
  /// municipality is a prohibition, which is why the UI cannot simply stay quiet
  /// when this is null.
  ///
  /// Several features can cover one point, so the most certain one has to win.
  /// A municipality straddling the French River is both listed in the schedule
  /// and inside the north polygon, and the uncertainty band along the divide
  /// overlaps municipalities on both banks. Being named in the schedule settles
  /// the question whichever bank you are on, so it outranks geography, and
  /// geography outranks the band that only says we cannot tell.
  LandFeature? get sundayGun {
    final covering =
        hits.where((feature) => feature.layerId == 'sunday_gun').toList();
    if (covering.isEmpty) return null;
    covering.sort((a, b) => _sundayCertainty(a).compareTo(_sundayCertainty(b)));
    return covering.first;
  }

  static int _sundayCertainty(LandFeature feature) => switch (feature) {
        _ when feature.basis == 'reg663_part7' => 0,
        _ when feature.properties['near_divide'] != true => 1,
        _ => 2,
      };

  /// Ontario states a provincial park's hunting rule twice and the two records
  /// disagree. `crown_land` carries the Crown Land Use Policy Atlas policy for
  /// the park, which reads as a flat prohibition, while `parks` carries
  /// O. Reg. 663/98 Part 3 — the regulation that actually opens a park, and which
  /// opens several of them in only a described part. Algonquin is the live case:
  /// the atlas says hunting is not permitted, Schedule 42 opens the "McRae
  /// Addition" in Eyre Township, and the card showed one park name twice with two
  /// different certainties and nothing to say which governed. The regulation
  /// governs, so the atlas copy of the same park steps aside.
  bool _supersededByParkRegulation(LandFeature feature) =>
      feature.layerId == 'crown_land' &&
      feature.basis == 'protected_area' &&
      hits.any((other) => other.layerId == 'parks');

  /// Layers the card reports as land use, in place of the ones that have a
  /// section of their own (`sunday_gun`, `municipalities`, `land_use_plan`).
  ///
  /// Public because it is an allowlist, and an allowlist silently drops a layer
  /// it has never heard of. `crown_disposition` was added to the map, the panel
  /// and the pack and still could not appear here, which looked for all the
  /// world like the geometry being wrong. See `land_info_test.dart`, which makes
  /// leaving a layer out a decision rather than an oversight.
  static const landUseLayers = {
    'game_preserve',
    'federal_closure',
    'defence_land',
    'crown_land',
    'crown_disposition',
    'conservation_authority',
    'first_nations',
    'parks',
    'conservation_reserve',
    'wmu',
    'municipal_forest',
  };

  List<LandFeature> get landUse {
    final matches = hits
        .where((feature) => landUseLayers.contains(feature.layerId))
        .where((feature) => !_supersededByParkRegulation(feature));
    // Partitioned rather than sorted: List.sort is not stable, and the rest of
    // the order comes from the draw order the map already resolved. Anything
    // that says not permitted leads, because it overrules the tenure under it.
    return [
      ...matches.where((f) => f.huntingAllowed == false),
      ...matches.where((f) => f.huntingAllowed != false),
    ];
  }

  /// Notes for layers whose source is known to be incomplete and which drew
  /// nothing here. Only the silent ones qualify: once a polygon is on the card
  /// the user is already being told to ask permission, and repeating the caveat
  /// there would bury the part that matters.
  List<String> incompleteCoverage(Map<String, LoadedLayer> layers) => [
        for (final entry in layers.entries)
          if (entry.value.coverageIncomplete &&
              !hits.any((feature) => feature.layerId == entry.key))
            if (entry.value.coverageNote case final note?) note,
      ];

  LandFeature? get wmu =>
      hits.firstWhereOrNull((feature) => feature.layerId == 'wmu');

  String? get wmuId {
    final feature = wmu;
    if (feature == null) return null;
    final id = feature.properties['wmu_id']?.toString().trim();
    if (id != null && id.isNotEmpty) return id;
    final name = feature.name?.trim();
    return (name == null || name.isEmpty) ? null : name;
  }
}
