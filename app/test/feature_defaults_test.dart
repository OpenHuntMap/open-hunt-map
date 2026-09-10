import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/data/models.dart';

LoadedLayer layer(Map<String, dynamic> metadata) => LoadedLayer(
      manifest: const LayerManifest(
        id: 'crown_disposition',
        label: 'Leased & occupied Crown land',
        path: 'overlays/crown_disposition.geojson',
        featureCount: 1,
      ),
      metadata: metadata,
      sourceUri: 'file:///nowhere.geojson',
    );

void main() {
  group('a layer can state a property once instead of on every feature', () {
    final dispositions = layer({
      'default_hunting_allowed': 'conditional',
      'default_basis': 'disposition_occupied',
      'boundary_accuracy': 'mapped',
    });

    test('the header supplies what the features leave out', () {
      expect(dispositions.featureDefaults, {
        'hunting_allowed': 'conditional',
        'basis': 'disposition_occupied',
        'boundary_accuracy': 'mapped',
      });
    });

    test('a feature that omitted them reads as though it carried them', () {
      final feature = LandFeature.fromGeoJson(
        'crown_disposition',
        {'properties': {'kind': 'Crown lease'}, 'geometry': {}},
        defaults: dispositions.featureDefaults,
      );
      expect(feature.huntingAllowed, 'conditional');
      expect(feature.basis, 'disposition_occupied');
      expect(feature.boundaryAccuracy, 'mapped');
      expect(feature.isApproximate, isFalse);
    });

    test('a feature that states its own exception keeps it', () {
      final feature = LandFeature.fromGeoJson(
        'crown_disposition',
        {
          'properties': {
            'basis': 'disposition_mining',
            'boundary_accuracy': 'approximate',
          },
          'geometry': {},
        },
        defaults: dispositions.featureDefaults,
      );
      expect(feature.basis, 'disposition_mining');
      expect(feature.isApproximate, isTrue,
          reason: 'a parcel mapped to worse than 100 m has to stay flagged');
    });

    // All 306 Ontario conservation reserves are opened by the same sentence of
    // the same subsection, and the card quotes it verbatim rather than
    // paraphrasing, so the layer states it once.
    test('one statute can stand in for every feature in a layer', () {
      final reserves = layer({
        'default_hunting_allowed': true,
        'default_basis': 'ppcra_s15_3',
        'default_designation': 'Conservation Reserve',
        'default_reg_text': 'Hunting is permitted in conservation reserves '
            'unless it is prohibited by regulation made under the Fish and '
            'Wildlife Conservation Act, 1997.',
      });
      final feature = LandFeature.fromGeoJson(
        'conservation_reserve',
        {
          'properties': {'name': 'CONROYS MARSH CONSERVATION RESERVE'},
          'geometry': {},
        },
        defaults: reserves.featureDefaults,
      );
      expect(feature.huntingAllowed, isTrue);
      expect(feature.basis, 'ppcra_s15_3');
      expect(feature.designation, 'Conservation Reserve');
      expect(feature.regulationText, contains('permitted in conservation'));
    });

    test('a layer that declares no defaults changes nothing', () {
      final bare = layer({'default_name': 'Crown land'});
      expect(bare.featureDefaults, isEmpty);
      final feature = LandFeature.fromGeoJson(
        'crown_land',
        {'properties': {'basis': 'tenure_only'}, 'geometry': {}},
        defaults: bare.featureDefaults,
      );
      expect(feature.huntingAllowed, isNull);
      expect(feature.basis, 'tenure_only');
    });

    // crown_land depends on this: a null hunting_allowed there means "no policy
    // covers this parcel", which is an answer. Filling it in from a default
    // would turn a deliberate silence into a claim.
    test('an explicit null is a value, not a gap to be filled', () {
      final feature = LandFeature.fromGeoJson(
        'crown_land',
        {
          'properties': {'hunting_allowed': null, 'basis': 'tenure_only'},
          'geometry': {},
        },
        defaults: const {'hunting_allowed': 'conditional'},
      );
      expect(feature.huntingAllowed, isNull);
    });
  });
}
