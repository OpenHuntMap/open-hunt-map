class Province {
  const Province({
    required this.id,
    required this.name,
    required this.enabled,
    required this.bbox,
    this.packUrl,
    this.status,
    this.statusNote,
  });

  final String id;
  final String name;
  final bool enabled;
  final List<double> bbox;
  final String? packUrl;

  /// `preview` where the province's data is knowingly partial. Kept in
  /// provinces.json so a province can be promoted without shipping an app
  /// update.
  final String? status;
  final String? statusNote;

  bool get isPreview => status == 'preview';

  String get code => id.toUpperCase();

  factory Province.fromJson(Map<String, dynamic> json) => Province(
        id: json['id'] as String,
        name: json['name'] as String,
        enabled: json['enabled'] as bool? ?? true,
        bbox: (json['bbox'] as List<dynamic>? ?? const [])
            .map((value) => (value as num).toDouble())
            .toList(),
        packUrl: (json['packUrl'] as String?)?.trim().isEmpty == true
            ? null
            : json['packUrl'] as String?,
        status: json['status'] as String?,
        statusNote: json['statusNote'] as String?,
      );
}

class LayerManifest {
  const LayerManifest({
    required this.id,
    required this.label,
    required this.path,
    required this.featureCount,
  });

  final String id;
  final String label;
  final String path;
  final int featureCount;

  factory LayerManifest.fromJson(Map<String, dynamic> json) => LayerManifest(
        id: json['id'] as String,
        label: json['label'] as String? ?? json['id'] as String,
        path: json['path'] as String,
        featureCount: json['feature_count'] as int? ?? 0,
      );
}

class ProvinceManifest {
  const ProvinceManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.license,
    required this.licenseUrl,
    required this.layers,
    this.policyReportUrlTemplate,
    this.policyAtlasUrlTemplate,
    this.policyAtlasAcceptsCentre = false,
  });

  final String id;
  final String name;
  final String version;
  final String license;
  final String licenseUrl;
  final List<LayerManifest> layers;

  /// Template for the province's authoritative policy report, with `{id}`
  /// standing in for the policy identifier. Lets the app link to the live
  /// document without bundling it, and without hardcoding a provincial URL.
  final String? policyReportUrlTemplate;

  /// The province's interactive policy atlas, for parcels no policy covers.
  final String? policyAtlasUrlTemplate;

  /// Whether that atlas honours a `center=lon,lat,wkid` launch parameter. Only
  /// set where the viewer has actually been checked, because the failure mode is
  /// silent: an atlas that ignores the parameter opens at the province while the
  /// app implies it went to the parcel. Absent means "send them the plain URL".
  final bool policyAtlasAcceptsCentre;

  Uri? get policyAtlasUrl {
    final url = policyAtlasUrlTemplate;
    return url == null || url.isEmpty ? null : Uri.tryParse(url);
  }

  /// The atlas centred on a point, where the viewer supports it. Falls back to
  /// the plain atlas URL rather than guessing at a parameter the province has
  /// not been confirmed to read.
  Uri? policyAtlasAt(double latitude, double longitude) {
    final atlas = policyAtlasUrl;
    if (atlas == null || !policyAtlasAcceptsCentre) return atlas;
    return atlas.replace(queryParameters: {
      ...atlas.queryParameters,
      // Longitude first: the viewer reads the pair as an ArcGIS x,y point and
      // the trailing WKID is the spatial reference it reprojects from.
      'center': '${longitude.toStringAsFixed(5)},'
          '${latitude.toStringAsFixed(5)},4326',
      // A denominator, snapped by the viewer to its nearest cached level. About
      // 1:9,000 puts a parcel on screen with enough context to place it.
      'scale': '9027.977411',
    });
  }

  /// Live URL for [policyId], or null if the province publishes no such link.
  Uri? policyReportUrl(String policyId) {
    final template = policyReportUrlTemplate;
    if (template == null || !template.contains('{id}')) return null;
    return Uri.tryParse(
      template.replaceAll('{id}', Uri.encodeComponent(policyId)),
    );
  }

  factory ProvinceManifest.fromJson(Map<String, dynamic> json) =>
      ProvinceManifest(
        id: json['id'] as String,
        name: json['name'] as String,
        version: json['version'] as String? ?? 'unknown',
        license: json['license'] as String? ?? 'See source metadata',
        licenseUrl: json['license_url'] as String? ?? '',
        policyReportUrlTemplate: json['policy_report_url'] as String?,
        policyAtlasUrlTemplate: json['policy_atlas_url'] as String?,
        policyAtlasAcceptsCentre:
            json['policy_atlas_accepts_centre'] as bool? ?? false,
        layers: (json['layers'] as List<dynamic>? ?? const [])
            .map((item) =>
                LayerManifest.fromJson(item as Map<String, dynamic>))
            .toList(),
      );
}

class LandFeature {
  const LandFeature({
    required this.layerId,
    required this.properties,
    required this.geometry,
  });

  final String layerId;
  final Map<String, dynamic> properties;
  final Map<String, dynamic> geometry;

  String? get name => properties['name']?.toString();
  String? get designation => properties['designation']?.toString();
  String? get policyId => properties['policy_id']?.toString();
  String? get summary => properties['summary']?.toString();
  Object? get huntingAllowed => properties['hunting_allowed'];

  /// Short code explaining where [huntingAllowed] came from. Long-form text
  /// lives once in the layer metadata rather than on every feature.
  String? get basis => properties['basis']?.toString();

  /// The custodian's own record for this feature. Preferred over anything we
  /// could bundle where the answer changes faster than a pack ships — a defence
  /// property's contact details, for instance.
  Uri? get recordUrl {
    final raw = properties['record_url']?.toString();
    return (raw == null || raw.isEmpty) ? null : Uri.tryParse(raw);
  }

  /// `mapped` for authoritative boundaries, `approximate` for sketched extents.
  String? get boundaryAccuracy => properties['boundary_accuracy']?.toString();

  /// True where almost all of this parcel is the bed of a lake or river. Not a
  /// closure and not an error in the tenure record: a lake bed genuinely is
  /// unpatented Crown land and hunting over Crown water is legal. What it fixes
  /// is the card, which described open water in exactly the words it uses for
  /// dry ground.
  bool get isOverWater => properties['over_water'] == true;

  bool get isApproximate => boundaryAccuracy == 'approximate';

  String? get within => properties['within']?.toString();

  /// `whole` if the whole area is open to hunting, `part` if a regulation opens
  /// only a described piece of it. A `part` extent is why [huntingAllowed] can
  /// be null on ground that is genuinely open somewhere inside this outline.
  String? get huntingExtent => properties['hunting_extent']?.toString();

  /// The regulation's own words about this area, carried verbatim so a carve-out
  /// such as "excepting those parts posted with signs" is never paraphrased.
  String? get regulationText => properties['reg_text']?.toString();

  /// An opening written into an Act rather than into the regulation the layer
  /// otherwise reads from. Ontario opens a provincial park to hunting by
  /// regulation, with one exception put in the statute itself: the Bruton and
  /// Clyde townships added to Algonquin. A card assembled only from
  /// O. Reg. 663/98 quotes Schedule 42 and stops, which tells a hunter standing
  /// in Bruton that the park is closed to them when the Act says it is not.
  String? get statuteText => properties['statute_text']?.toString();

  String? get statuteCitation => properties['statute_citation']?.toString();

  String? get statuteCurrencyDate =>
      properties['statute_currency_date']?.toString();

  Uri? get statuteUrl {
    final raw = properties['statute_url']?.toString();
    return (raw == null || raw.isEmpty) ? null : Uri.tryParse(raw);
  }

  /// Schedule of O. Reg. 663/98 Part 3 that opens this area, if any.
  int? get regulationSchedule {
    final value = properties['reg_schedule'];
    return value is num ? value.toInt() : null;
  }

  /// Legal lot-and-concession description, for public forest tracts.
  String? get lot => properties['lot']?.toString();

  /// `county`, `region`, `municipal` or `conservation_authority`.
  String? get ownerType => properties['owner_type']?.toString();

  String? get source => properties['source']?.toString();

  String? get notes => properties['hunting_notes']?.toString();

  double? get areaHa {
    final value = properties['area_ha'];
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  /// [defaults] come from the layer's own header, for properties a pack omits
  /// on every feature rather than repeating. See [LoadedLayer.featureDefaults].
  factory LandFeature.fromGeoJson(
    String layerId,
    Map<String, dynamic> json, {
    Map<String, dynamic> defaults = const {},
  }) {
    final properties =
        Map<String, dynamic>.from(json['properties'] as Map? ?? const {});
    for (final entry in defaults.entries) {
      // putIfAbsent, so a feature that carries the property keeps it — down to
      // an explicit null, which some layers use to mean something.
      properties.putIfAbsent(entry.key, () => entry.value);
    }
    return LandFeature(
      layerId: layerId,
      properties: properties,
      geometry:
          Map<String, dynamic>.from(json['geometry'] as Map? ?? const {}),
    );
  }
}

class LoadedLayer {
  const LoadedLayer({
    required this.manifest,
    required this.metadata,
    required this.sourceUri,
  });

  final LayerManifest manifest;

  /// Layer-wide facts (tenure, accuracy, basis notes) read from the overlay
  /// file header, so per-feature properties can stay small.
  final Map<String, dynamic> metadata;

  /// `file://` URI MapLibre loads the geometry from. The app never decodes
  /// overlay geometry itself; taps are resolved with `queryRenderedFeatures`.
  final String sourceUri;

  /// Name used when features omit a per-feature name to keep packs small.
  String? get defaultName => metadata['default_name']?.toString();

  String? get tenure => metadata['tenure']?.toString();

  String? get accuracyNote => metadata['accuracy_note']?.toString();

  /// Layers flagged `reference_only` are orientation aids, not land tenure.
  bool get isReferenceOnly => metadata['layer_role'] == 'reference_only';

  /// The regulation this layer's permissions come from, and where to read it.
  /// Present where legality is set by legal text rather than by a GIS source.
  String? get huntingSource => metadata['hunting_source']?.toString();

  Uri? get huntingSourceUrl {
    final raw = metadata['hunting_source_url']?.toString();
    return (raw == null || raw.isEmpty) ? null : Uri.tryParse(raw);
  }

  /// Date the legal text was consolidated to, so the card can say how current
  /// the permission is rather than implying it is live.
  String? get currencyDate => metadata['currency_date']?.toString() ??
      metadata['hunting_currency_date']?.toString();

  String? get citation => metadata['citation']?.toString();

  /// Why a partly-opened area's open portion is not drawable, in this layer's
  /// own terms. Ontario describes park openings in survey prose; a federal
  /// wildlife area's open areas are designated by the Minister and never
  /// published. Both are unmappable, for different reasons worth stating.
  String? get extentNote => metadata['extent_note']?.toString();

  /// True where the source is known not to hold every feature of its kind, so
  /// the absence of a polygon proves nothing and the card must not imply it does.
  bool get coverageIncomplete => metadata['coverage_incomplete'] == true;

  String? get coverageNote => metadata['coverage_note']?.toString();

  String? get note => metadata['note']?.toString();

  /// What this layer says about a parcel that is under water, in its own words,
  /// including how coarse the hydrography behind the flag is.
  String? get waterNote => metadata['water_note']?.toString();

  String? basisNote(String? code) {
    if (code == null) return null;
    final notes = metadata['basis_notes'];
    if (notes is Map) return notes[code]?.toString();
    return null;
  }

  /// Property values that stand in for every feature that omitted one.
  ///
  /// A pack leaves out the common case rather than repeating it: stating
  /// `hunting_allowed`, `basis` and `boundary_accuracy` on all 33,167 Crown
  /// dispositions costs 3 MB to say the same three words over and over. The
  /// layer says it once here instead.
  ///
  /// Only ever fills a gap, never overrides. A feature that states a value has
  /// its own reason for it, and `crown_land` depends on that: a null
  /// `hunting_allowed` there means "no policy covers this parcel", which is an
  /// answer and not a missing one.
  Map<String, dynamic> get featureDefaults => {
        if (metadata['default_hunting_allowed'] case final value?)
          'hunting_allowed': value,
        if (metadata['default_basis'] case final value?) 'basis': value,
        if (metadata['boundary_accuracy'] case final value?)
          'boundary_accuracy': value,
        // One statute can govern every feature in a layer. All 306 Ontario
        // conservation reserves are opened by the same sentence of the same
        // subsection, and the card quotes it verbatim rather than paraphrasing,
        // so the layer states it once here instead of 306 times.
        if (metadata['default_reg_text'] case final value?) 'reg_text': value,
        if (metadata['default_designation'] case final value?)
          'designation': value,
      };
}
