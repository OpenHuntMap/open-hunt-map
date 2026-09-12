import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/province_loader.dart';
import '../data/seasons.dart';
import 'land_info.dart';
import 'seasons_tab.dart';
import 'weather_tab.dart';

Future<void> showLandInfoSheet(
  BuildContext context, {
  required LandInfo info,
  required String provinceId,
  required ProvinceLoader loader,
  required ProvinceManifest manifest,
  ProvinceSeasons? seasons,
  Map<String, LoadedLayer> layers = const {},
  VoidCallback? onSaveWaypoint,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFFFBF0),
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.88,
        child: _LandInfoReport(
          info: info,
          provinceId: provinceId,
          loader: loader,
          manifest: manifest,
          seasons: seasons,
          layers: layers,
          onSaveWaypoint: onSaveWaypoint,
        ),
      ),
    );

class _LandInfoReport extends StatelessWidget {
  const _LandInfoReport({
    required this.info,
    required this.provinceId,
    required this.loader,
    required this.manifest,
    this.seasons,
    this.layers = const {},
    this.onSaveWaypoint,
  });

  final LandInfo info;
  final String provinceId;
  final ProvinceLoader loader;
  final ProvinceManifest manifest;
  final ProvinceSeasons? seasons;
  final Map<String, LoadedLayer> layers;
  final VoidCallback? onSaveWaypoint;

  @override
  Widget build(BuildContext context) {
    final wmuId = info.wmuId;
    final unitSeasons = seasons?.forUnit(wmuId) ?? const <SeasonEntry>[];
    final today = DateUtils.dateOnly(DateTime.now());
    final openCount = unitSeasons
        .where((season) => season.statusOn(today) == SeasonStatus.open)
        .length;

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'LAND INFO',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontFamily: 'serif',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                        ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          TabBar(
            labelColor: const Color(0xFF1B4332),
            indicatorColor: const Color(0xFF1B4332),
            labelPadding: const EdgeInsets.symmetric(horizontal: 8),
            tabs: [
              const Tab(text: 'LAND'),
              Tab(text: openCount > 0 ? 'SEASONS ($openCount)' : 'SEASONS'),
              const Tab(text: 'WEATHER'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                SelectionArea(
                  child: _LandTab(
                    info: info,
                    provinceId: provinceId,
                    loader: loader,
                    manifest: manifest,
                    layers: layers,
                    onSaveWaypoint: onSaveWaypoint,
                  ),
                ),
                SelectionArea(
                  child: SeasonsTab(
                    wmuId: wmuId,
                    pack: seasons,
                    seasons: unitSeasons,
                    today: today,
                  ),
                ),
                WeatherTab(
                  latitude: info.latitude,
                  longitude: info.longitude,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LandTab extends StatelessWidget {
  const _LandTab({
    required this.info,
    required this.provinceId,
    required this.loader,
    required this.manifest,
    required this.layers,
    this.onSaveWaypoint,
  });

  final LandInfo info;
  final String provinceId;
  final ProvinceLoader loader;
  final ProvinceManifest manifest;
  final Map<String, LoadedLayer> layers;
  final VoidCallback? onSaveWaypoint;

  @override
  Widget build(BuildContext context) {
    final localGov = info.localGovernmentLabel;
    final wmuId = info.wmuId;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        // A closure outranks everything below it, so it does not wait its turn
        // in the land-use list. Provincial and federal closures can overlap, and
        // both are shown: they are enforced by different officers.
        for (final closure in info.closures) ...[
          _ClosureBanner(feature: closure, layer: layers[closure.layerId]),
          const SizedBox(height: 4),
        ],
        _Section(
          title: 'LOCATION',
          children: [
            _line(
              'Coordinates',
              '${info.latitude.toStringAsFixed(6)}, '
                  '${info.longitude.toStringAsFixed(6)}',
            ),
            _line('Local government', localGov ?? 'Not identified'),
            _line('WMU', wmuId == null ? 'Not identified' : 'WMU $wmuId'),
            const SizedBox(height: 6),
            Text(
              localGov == null
                  ? 'Municipal boundary data is missing for this point, so '
                      'bylaw jurisdiction could not be resolved.'
                  : 'Check this municipality’s hunting and discharge bylaws '
                      '(many Ontario municipalities are legally named '
                      '“Township of …”).',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.black54,
                    height: 1.35,
                  ),
            ),
            // Where the coordinates already are, because a waypoint is a
            // coordinate the user wants to keep. The card is open because they
            // pointed at this spot, which is the moment they want to save it.
            if (onSaveWaypoint case final save?) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    save();
                  },
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Save a waypoint here'),
                ),
              ),
            ],
          ],
        ),
        // Only Ontario packs carry the schedule this is built from; without the
        // layer the app has nothing to say and says nothing.
        if (layers['sunday_gun'] case final sundayLayer?) ...[
          const Divider(),
          _SundayGun(feature: info.sundayGun, layer: sundayLayer),
        ],
        const Divider(),
        _Section(
          title: 'LAND USE',
          children: [
            if (info.landUse.isEmpty)
              const Text(
                'No bundled land-use polygon covers this point. This does '
                'not establish land ownership or hunting permission.',
              )
            else
              ...info.landUse.map((feature) => _FeatureReport(
                    feature: feature,
                    provinceId: provinceId,
                    loader: loader,
                    manifest: manifest,
                    layer: layers[feature.layerId],
                    latitude: info.latitude,
                    longitude: info.longitude,
                    inFarNorth: info.inFarNorth,
                    communityPlan: info.communityLandUsePlan,
                  )),
            // Shown only where no polygon from an admittedly incomplete layer
            // covers the point, which is exactly where its silence could be read
            // as permission. Conservation authority land is the live case:
            // CPCAD holds only what each authority reported, so plenty of
            // permit-only ground in the south is simply not in it.
            for (final gap in info.incompleteCoverage(layers)) ...[
              const SizedBox(height: 10),
              _Warning(gap),
            ],
          ],
        ),
        const Divider(),
        Text(
          'Map results are informational and may be incomplete. Verify current '
          'regulations, posted notices, ownership, and boundaries before use.'
          '\n\n${info.attribution}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.black54,
                height: 1.35,
              ),
        ),
      ],
    );
  }
}

Widget _line(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child:
                Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final Iterable<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: const Color(0xFF1B4332),
                    letterSpacing: 1.2,
                  ),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );
}

class _FeatureReport extends StatelessWidget {
  const _FeatureReport({
    required this.feature,
    required this.provinceId,
    required this.loader,
    required this.manifest,
    required this.latitude,
    required this.longitude,
    this.layer,
    this.inFarNorth = false,
    this.communityPlan,
  });

  final ProvinceManifest manifest;
  final LandFeature feature;
  final String provinceId;
  final ProvinceLoader loader;
  final LoadedLayer? layer;

  /// The tapped point, so a parcel with no policy can still hand the user
  /// coordinates to find in the official atlas.
  final double latitude;
  final double longitude;

  /// Whether the atlas can be expected to have anything here at all, and the
  /// community plan to offer instead if it does not. Both change what the
  /// missing-policy dialog is allowed to claim.
  final bool inFarNorth;
  final LandFeature? communityPlan;

  @override
  Widget build(BuildContext context) {
    final isWmu = feature.layerId == 'wmu';
    final title = isWmu
        ? 'WMU ${feature.properties['wmu_id'] ?? feature.name ?? ''}'.trim()
        : (feature.name ??
            layer?.defaultName ??
            feature.layerId.replaceAll('_', ' '));
    final tenure = _ownerLabel(feature.ownerType) ?? layer?.tenure;
    final basisNote = layer?.basisNote(feature.basis) ?? feature.notes;
    final area = feature.areaHa;
    final fromStatute = quotesStatute(feature.basis);

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          if (!isWmu && tenure != null) Text(tenure),
          if (feature.designation != null)
            Text('Designation: ${feature.designation}'),
          if (feature.within != null) Text('Inside: ${feature.within}'),
          if (feature.lot case final lot?) Text('Lot: $lot'),
          if (area != null) Text('Mapped area: ${formatArea(area)}'),
          if (!isWmu) ...[
            const SizedBox(height: 6),
            _HuntingBadge(
              value: feature.huntingAllowed,
              basis: feature.basis,
            ),
          ],
          if (feature.isApproximate) ...[
            const SizedBox(height: 8),
            const _Warning(
              'Approximate outline. This is not a property boundary and may '
              'include private land. Do not rely on it to decide where you can '
              'hunt.',
            ),
          ],
          // Ahead of the basis note, which is the paragraph about seasons,
          // licences and discharge by-laws. On a lake bed that paragraph is
          // still true and still reads as a description of dry ground, so what
          // the ground actually is has to come first.
          if (feature.isOverWater && layer?.waterNote != null) ...[
            const SizedBox(height: 8),
            _Warning(layer!.waterNote!),
          ],
          if (layer?.isReferenceOnly == true && !feature.isApproximate) ...[
            const SizedBox(height: 8),
            const _Warning(
              'Reference layer only — this does not establish public ownership '
              'or hunting access.',
            ),
          ],
          if (feature.huntingExtent == 'part') ...[
            const SizedBox(height: 8),
            // The reason the open area is unmapped differs by layer — Ontario
            // describes park openings in survey prose, while a federal wildlife
            // area's open areas are designated by the Minister and not published
            // at all — so the layer supplies the wording.
            _Warning(
              layer?.extentNote ??
                  'The regulation opens only part of this area, and that part is '
                      'not published as a boundary, so this outline cannot tell '
                      'you whether your spot is inside it.',
            ),
          ],
          if (feature.regulationText case final text?) ...[
            const SizedBox(height: 8),
            _RegulationQuote(
              text: text,
              schedule: feature.regulationSchedule,
              heading: fromStatute ? 'The Act says' : null,
              source: layer?.huntingSource,
              currency: layer?.currencyDate,
              url: layer?.huntingSourceUrl,
              linkLabel: fromStatute ? 'Read the Act' : 'Read the regulation',
              onOpen: _openOfficialReport,
            ),
          ],
          // Second, and never instead of the schedule: both openings are real
          // and a user in Bruton needs the one the regulation does not carry.
          if (feature.statuteText case final text?) ...[
            const SizedBox(height: 8),
            _RegulationQuote(
              text: text,
              heading: 'The Act itself also opens part of this park',
              source: feature.statuteCitation,
              currency: feature.statuteCurrencyDate,
              url: feature.statuteUrl,
              linkLabel: 'Read the Act',
              onOpen: _openOfficialReport,
            ),
          ],
          if (basisNote != null) ...[
            const SizedBox(height: 6),
            Text(basisNote, style: const TextStyle(height: 1.35)),
          ],
          if (layer?.accuracyNote case final note?) ...[
            const SizedBox(height: 6),
            Text(
              note,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.black54,
                    height: 1.35,
                  ),
            ),
          ],
          if (feature.summary != null) ...[
            const SizedBox(height: 6),
            Text(feature.summary!, style: const TextStyle(height: 1.35)),
          ],
          // Checked before the policy branch because a feature carrying its
          // custodian's own record has a better answer than anything we bundle.
          if (feature.recordUrl case final record?)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open the property record'),
                onPressed: () => _openOfficialReport(context, record),
              ),
            )
          else if (feature.policyId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.description_outlined),
                label: Text('Open policy ${feature.policyId}'),
                onPressed: () => _openPolicy(context, feature.policyId!),
              ),
            )
          // No policy id means no report exists to open, not that we failed to
          // find one. The atlas is still the place to confirm that, and in
          // Ontario it will open on the spot.
          else if (manifest.policyAtlasUrl case final atlas?)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.travel_explore),
                label: const Text('Browse the policy atlas'),
                onPressed: () => _openAtlas(context, atlas),
              ),
            ),
        ],
      ),
    );
  }

  String? _ownerLabel(String? ownerType) => switch (ownerType) {
        'county' => 'County forest — publicly owned',
        'region' => 'Regional forest — publicly owned',
        'municipal' => 'Municipal forest — publicly owned',
        'conservation_authority' => 'Conservation authority forest',
        _ => null,
      };

  Future<void> _openPolicy(BuildContext context, String policyId) async {
    final text = await loader.loadPolicy(provinceId, policyId);
    if (!context.mounted) return;
    final officialUrl = manifest.policyReportUrl(policyId);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Policy $policyId'),
        content: SizedBox(
          width: 640,
          child: SelectionArea(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text ??
                        'No policy document is bundled for $policyId. Open the '
                            'official report to read it.',
                  ),
                  if (text != null && officialUrl != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Bundled copy, current as of the pack you installed. The '
                      'official report is the authority.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.black54,
                            height: 1.35,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          if (officialUrl != null)
            TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Official report'),
              onPressed: () => _openOfficialReport(context, officialUrl),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// For parcels the policy atlas does not cover. Ontario's viewer takes a
  /// coordinate, so the link opens on the spot — but it ignores a bad one
  /// silently, landing on the province with nothing on screen to say so. The
  /// coordinates stay visible and copyable for exactly that case.
  Future<void> _openAtlas(BuildContext context, Uri atlas) async {
    final coordinates =
        '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
    // North of the Far North line the atlas is sparse to absent, so the absence
    // of a report says nothing about whether direction exists. Claiming "no
    // policy covers this parcel" there would be asserting a fact we do not have.
    final explanation = inFarNorth
        ? 'This parcel is in the Far North, where the atlas thins out to '
            'nothing. There is no policy report for it, and that most likely '
            'means the atlas has never reached this ground rather than that no '
            'direction applies to it.'
        : 'No land use policy covers this parcel, so there is no policy '
            'report to open. The official atlas is the place to confirm that, '
            'and to check for anything added since this pack was built.';
    final plan = communityPlan;
    final planName = plan?.name ?? 'an approved plan';
    final planYear = plan?.properties['year_approved'];
    final target = manifest.policyAtlasAt(latitude, longitude) ?? atlas;
    final centred = target != atlas;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Crown Land Use Policy Atlas'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(explanation, style: const TextStyle(height: 1.35)),
            if (plan != null) ...[
              const SizedBox(height: 12),
              Text(
                'A community based land use plan does cover it: $planName'
                '${planYear == null ? '' : ', approved $planYear'}. It directs '
                'how Crown land here is managed and is not a hunting '
                'regulation, so seasons and WMU rules still decide whether you '
                'may hunt.',
                style: const TextStyle(height: 1.35),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              centred
                  ? 'It should open centred here. If it opens at the whole '
                      'province instead, search these coordinates:'
                  : 'It opens at the province, not at this parcel. Search '
                      'these coordinates once it loads:',
              style: const TextStyle(height: 1.35),
            ),
            const SizedBox(height: 8),
            SelectableText(
              coordinates,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        actions: [
          if (plan?.recordUrl case final planUrl?)
            TextButton.icon(
              icon: const Icon(Icons.description_outlined, size: 18),
              label: const Text('Open the plan'),
              onPressed: () => _openOfficialReport(context, planUrl),
            ),
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: coordinates));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('Coordinates copied'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open atlas'),
            onPressed: () => _openOfficialReport(context, target),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Opens the province's live policy report in a browser. Needs a connection,
  /// so failure is reported rather than left as a dead tap.
  Future<void> _openOfficialReport(BuildContext context, Uri url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    var launched = false;
    try {
      launched = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (launched) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text('Could not open the report. $url'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Whether Sunday gun hunting is permitted at the tapped point.
///
/// The absence of a polygon is the interesting case. Sunday gun hunting is
/// permitted everywhere north of the French and Mattawa rivers, and south of
/// them only in the municipalities scheduled in O. Reg. 663/98 Part 7. We map
/// where it is permitted, but not the river line itself, so outside a polygon
/// the honest answer depends on which side of those rivers the user is on and
/// the card says so rather than guessing.
/// The four things this app can honestly say about hunting with a gun on a
/// Sunday, and which one a point earns.
class SundayGunVerdict {
  const SundayGunVerdict({
    required this.headline,
    required this.body,
    required this.colour,
    required this.icon,
    this.citation,
  });

  final String headline;
  final String body;
  final Color colour;
  final IconData icon;

  /// The provision that governs *this* answer, where it is not the schedule the
  /// layer as a whole is built from.
  ///
  /// Two regulations are in play and only one of them decides any given point.
  /// The schedule of municipalities answers inside a listed one; everywhere else
  /// the answer comes from the prohibition, which the schedule is merely an
  /// exception to. Citing the schedule for a point that is north of the rivers
  /// sends someone to a list their answer is not in.
  final String? citation;
}

/// Reads the verdict off the covering feature, or off its absence.
///
/// A top-level function so the wording can be tested, for the same reason
/// [huntingVerdict] is one: it decides whether someone fires a rifle.
///
/// The prohibition is O. Reg. 665/98 s. 66 (1), and it only reaches south of the
/// French and Mattawa rivers. So three of these four states are a yes, and the
/// interesting one is the band along the rivers themselves. There, the honest
/// answer is that we cannot tell which bank you are on — our line is a
/// digitised centreline and the regulation means the water. It must not lead
/// with the word permitted: a hunter within half a kilometre of the Mattawa who
/// reads "permitted" and is actually on the south bank in an unlisted township
/// has been handed an offence by this app.
SundayGunVerdict sundayGunVerdict(LandFeature? feature) {
  const permitted = Color(0xFF1B5E20);
  const uncertain = Color(0xFF8D6E00);
  const prohibited = Color(0xFFB3261E);

  const prohibition = 'O. Reg. 665/98 (Hunting) s. 66 (1), which prohibits '
      'Sunday gun hunting only in the area south of the French and Mattawa '
      'rivers';

  if (feature == null) {
    return const SundayGunVerdict(
      headline: 'Not permitted here on Sundays',
      body: 'This point is south of the French and Mattawa rivers and is not '
          'in a municipality the regulation lists. Hunting on a Sunday here '
          'with anything other than a bow or crossbow is an offence.',
      colour: prohibited,
      icon: Icons.block_outlined,
      // Both provisions matter here: one prohibits, and the other would have
      // excepted this place if it were listed.
      citation: '$prohibition, and O. Reg. 663/98 Part 7 Schedule 1, which '
          'does not list this municipality',
    );
  }
  if (feature.basis == 'reg663_part7') {
    final listedAs = feature.properties['listed_as']?.toString();
    return SundayGunVerdict(
      headline: 'Permitted here during open seasons',
      body: 'This point is inside ${listedAs ?? 'a listed municipality'}, '
          'which is scheduled for Sunday gun hunting.',
      colour: permitted,
      icon: Icons.check_circle_outline,
    );
  }
  if (feature.properties['near_divide'] == true) {
    return const SundayGunVerdict(
      headline: 'Too close to the rivers to say',
      body: 'The prohibition applies only south of the French and Mattawa '
          'rivers, and this point is within about half a kilometre of that '
          'line — the wrong side of which is an offence. The line here is a '
          'digitised channel, not the water itself, so this map cannot tell '
          'you which bank you are on. Work it out on the ground before '
          'hunting, or check whether the municipality you are in is listed.',
      colour: uncertain,
      icon: Icons.help_outline,
      citation: prohibition,
    );
  }
  return const SundayGunVerdict(
    headline: 'Permitted here during open seasons',
    body: 'This point is north of the French and Mattawa rivers. The Sunday '
        'prohibition reaches only south of them, so no municipal listing is '
        'needed here.',
    colour: permitted,
    icon: Icons.check_circle_outline,
    citation: prohibition,
  );
}

class _SundayGun extends StatelessWidget {
  const _SundayGun({required this.feature, required this.layer});

  final LandFeature? feature;
  final LoadedLayer layer;

  @override
  Widget build(BuildContext context) {
    final verdict = sundayGunVerdict(feature);

    return _Section(
      title: 'SUNDAY GUN HUNTING',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(verdict.icon, size: 20, color: verdict.colour),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                verdict.headline,
                style: TextStyle(
                  color: verdict.colour,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(verdict.body, style: const TextStyle(height: 1.35)),
        // A carve-out such as "except that part in The Archipelago" decides
        // legality on the ground, so it survives the verdict wording and stays
        // in the schedule's own words.
        if (feature?.properties['exception']?.toString() case final exception?) ...[
          const SizedBox(height: 8),
          _Warning('The schedule lists this area $exception.'),
        ],
        const SizedBox(height: 8),
        Text(
          [
            // The verdict's own provision wins. The layer's citation is the
            // schedule this was built from, which only governs a point inside a
            // listed municipality.
            if (verdict.citation ?? layer.citation case final citation?)
              citation,
            // The consolidation date belongs to the schedule the layer was built
            // from, so it travels with that citation and not with a substituted
            // one. Trailing it after a different regulation would be asserting a
            // currency for that regulation which nothing here establishes.
            if (verdict.citation == null)
              if (layer.currencyDate case final date?) 'consolidated $date',
          ].join(', '),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.black54,
                height: 1.35,
              ),
        ),
      ],
    );
  }
}

/// The regulation's own wording, quoted rather than summarised. Carve-outs like
/// "excepting those parts posted with signs" decide legality on the ground and
/// paraphrasing them would drop exactly the part that matters.
class _RegulationQuote extends StatelessWidget {
  const _RegulationQuote({
    required this.text,
    required this.onOpen,
    this.schedule,
    this.heading,
    this.source,
    this.currency,
    this.url,
    this.linkLabel = 'Read the regulation',
  });

  final String text;
  final int? schedule;

  /// Overrides the schedule-derived heading for a quote that is not from the
  /// layer's own regulation.
  final String? heading;
  final String? source;
  final String? currency;
  final Uri? url;
  final String linkLabel;
  final Future<void> Function(BuildContext, Uri) onOpen;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F1E7),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFD8D2BC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading ??
                (schedule == null
                    ? 'The regulation says'
                    : 'Schedule $schedule says'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(text, style: const TextStyle(height: 1.4, fontFamily: 'serif')),
          if (source != null) ...[
            const SizedBox(height: 8),
            Text(
              currency == null
                  ? source!
                  : '$source, as consolidated $currency.',
              style: small?.copyWith(color: Colors.black54, height: 1.35),
            ),
          ],
          if (url case final target?)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(linkLabel),
                onPressed: () => onOpen(context, target),
              ),
            ),
        ],
      ),
    );
  }
}

/// A parcel's mapped extent, in the unit that reads at its size.
///
/// Top-level so it can be tested, which it previously was not: the conversion
/// divided by 100 and then rounded the result to one decimal by dividing by 10
/// again, so every parcel over 1,000 ha was reported at a tenth of its size.
/// Round Lake's 2,625.6 ha read as 2.6 km² instead of 26.3.
String formatArea(double hectares) {
  if (hectares >= 1000) {
    const hectaresPerSquareKm = 100;
    final km2 = hectares / hectaresPerSquareKm;
    return '${km2.toStringAsFixed(km2 < 100 ? 1 : 0)} km²';
  }
  return '${hectares.toStringAsFixed(hectares < 10 ? 1 : 0)} ha';
}

/// Whether a feature's quoted passage comes from an Act rather than from a
/// regulation.
///
/// Every layer but one quotes a regulation, so the quote box says "the
/// regulation" by default. A conservation reserve is opened by the Provincial
/// Parks and Conservation Reserves Act, 2006 itself, and a user who follows the
/// citation printed under the quote would catch us naming the wrong kind of
/// instrument before we did.
bool quotesStatute(String? basis) => basis == 'ppcra_s15_3';

/// Only [huntingVerdict] may return this, and only for a parcel a source
/// explicitly permits hunting on. Nothing inferred gets to look this certain.
const Color _permitted = Color(0xFF1B5E20);

/// The words and colour for a feature's hunting status.
///
/// A top-level function rather than a method on the badge so the wording can be
/// tested. It is the most safety-critical string in the app: it is the sentence
/// a user reads before deciding whether to fire a rifle, and it has to stay
/// harder to make sound permissive than it is to make sound uncertain.
(String, Color) huntingVerdict(Object? value, String? basis) {
  // Where a basis is specific enough to name the reason, it outranks the
  // boolean: "no hunting" and "no hunting because the park was never opened"
  // send a user to different places for a second opinion. The middle colour is
  // for the answers that are genuinely neither yes nor no.
  const closed = Color(0xFFB3261E);
  const qualified = Color(0xFF8D6E00);
  switch (basis) {
    // A park opened only in part is neither permitted nor unknown, and calling
    // it either would be wrong: the regulation opens ground inside this
    // outline but describes it in words the province never mapped.
    case 'reg663_part3_partial':
      return ('Open in part of this park only', qualified);
    // No schedule opens this park, but the Act does, in townships it names and
    // Ontario does not publish as a park boundary. Same answer as a partial
    // schedule for the same reason, and emphatically not "park not opened".
    case 'ppcra_s15_2_partial':
      return ('Open in part of this park only', qualified);
    case 'reg663_part3_unlisted':
      return ('No hunting — park not opened', closed);
    // The Act permits hunting here itself, which is a stronger statement than a
    // planning table listing hunting as a permitted use, and it forbids a
    // management plan from narrowing it. Only a regulation can close this
    // ground, and the one that does — a Crown game preserve — is a layer of its
    // own that leads the card wherever it applies.
    case 'ppcra_s15_3':
      return ('Hunting permitted by the Act', _permitted);
    case 'ca_permit':
      return ('Conservation authority permit required', qualified);
    case 'conservation_permission':
      return ("Owner's permission required", qualified);
    // Not a prohibition. A provincial licence simply does not reach this land,
    // which is a different answer and has to read like one.
    case 'reserve_permission':
      return ('Permission of the First Nation required', qualified);
    case 'dnd_closed':
      return ('No public hunting — defence property', closed);
    case 'nwa_waterfowl':
      return ('Waterfowl only, in designated areas', qualified);
    case 'nwa_no_entry':
      return ('No entry without a federal permit', closed);
    case 'nwa_closed':
    case 'mbs_closed':
      return ('No hunting — federal protected area', closed);
    case 'nwa_unverified':
    case 'mbs_unverified':
      return ('Treat as closed — rules unconfirmed', closed);
    // Not a wildlife closure, and the wording has to avoid sounding like one:
    // the Crown still owns this and no season is closed on it. What has changed
    // is that somebody else may lawfully tell you to leave, which "permitted
    // with conditions" does not convey.
    case 'disposition_occupied':
      return ('Occupied — the holder may refuse entry', qualified);
    case 'disposition_mining':
      return ('Under a mining licence of occupation', qualified);
  }
  if (value == true) {
    return ('Hunting listed as permitted', _permitted);
  }
  if (value == false) {
    return ('Hunting not permitted', closed);
  }
  if (value == 'conditional') {
    return ('Hunting permitted with conditions', qualified);
  }
  if (value == null) {
    // A parcel with no area-specific policy is not a gap in the data — it is
    // Crown land the province leaves to the general rules. Saying "not on
    // record" there reads as ignorance and sends people elsewhere for an answer
    // that already exists, so it gets its own wording.
    //
    // It does not get a green one. That is 52% of Ontario's Crown land by area,
    // where the province has stated no position on this ground specifically and
    // the answer is inferred from a rule about Crown land in general. Two shades
    // of green could not carry that difference, and the confident one was being
    // read as a permission the source does not give. Amber says what the
    // conditional parcels say, which is what this is: yes, subject to things
    // this map cannot see — a lease, a land use permit, posted signage.
    return basis == 'tenure_only'
        ? ('General rules apply, no local policy', qualified)
        : ('Hunting status not on record', const Color(0xFF4A4A4A));
  }
  return (value.toString(), const Color(0xFF4A4A4A));
}

class _HuntingBadge extends StatelessWidget {
  const _HuntingBadge({required this.value, this.basis});

  final Object? value;
  final String? basis;

  @override
  Widget build(BuildContext context) {
    final (label, color) = huntingVerdict(value, basis);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A hard closure at the tapped point, shown before anything else on the card.
class _ClosureBanner extends StatelessWidget {
  const _ClosureBanner({required this.feature, this.layer});

  final LandFeature feature;
  final LoadedLayer? layer;

  /// Names the closure rather than just asserting one. A hunter who reads "no
  /// hunting" needs to know which authority to argue with, and a provincial game
  /// preserve, a federal wildlife area and a bird sanctuary send them three
  /// different places.
  String get _headline => switch (feature.basis) {
        'fwca_s9' => 'No hunting — Crown game preserve',
        'fwca_s9_unconfirmed' => 'Crown game preserve — treat as no hunting',
        'nwa_no_entry' => 'No entry — National Wildlife Area',
        'nwa_closed' => 'No hunting — National Wildlife Area',
        'mbs_closed' => 'No hunting, and no firearm — bird sanctuary',
        'nwa_unverified' || 'mbs_unverified' =>
          'Treat as closed — rules unconfirmed',
        'dnd_closed' => 'No public hunting — defence property',
        _ => 'No hunting here',
      };

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFB3261E);
    final name = feature.name ?? layer?.defaultName ?? 'Closed area';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: red.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.block, size: 20, color: red),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _headline,
                  style: const TextStyle(
                    color: red,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (layer?.basisNote(feature.basis) case final note?) ...[
            const SizedBox(height: 6),
            Text(note, style: const TextStyle(height: 1.35)),
          ],
          if (feature.properties['citation'] case final citation?) ...[
            const SizedBox(height: 6),
            Text(
              [
                citation.toString(),
                if (feature.properties['reg_paragraph'] case final paragraph?)
                  paragraph.toString(),
                if (layer?.currencyDate case final date?) 'consolidated $date',
              ].join(', '),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.black54, height: 1.35),
            ),
          ],
        ],
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3CD),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFFE0C060)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(text, style: const TextStyle(height: 1.3)),
            ),
          ],
        ),
      );
}
