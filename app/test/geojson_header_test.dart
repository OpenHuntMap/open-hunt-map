import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/data/geojson_header.dart';

void main() {
  test('reads metadata that sits ahead of the features array', () {
    const header = '{"type":"FeatureCollection","metadata":{"layer":"crown_land"'
        ',"tenure":"Crown land","basis_notes":{"clupa":"See the policy."}},'
        '"features":[{"type":"Feature"';

    final metadata = geoJsonMetadata(header);

    expect(metadata['layer'], 'crown_land');
    expect(metadata['tenure'], 'Crown land');
    expect(metadata['basis_notes'], {'clupa': 'See the policy.'});
  });

  test('ignores braces and quotes inside metadata string values', () {
    const header = r'{"metadata":{"note":"a } brace and a \" quote",'
        '"layer":"parks"},"features":[]}';

    final metadata = geoJsonMetadata(header);

    expect(metadata['note'], 'a } brace and a " quote');
    expect(metadata['layer'], 'parks');
  });

  test('returns nothing when the object runs past the end of the header', () {
    // Simulates a metadata block larger than the bytes we read from the file.
    const truncated = '{"metadata":{"layer":"crown_land","coverage":"Ontario';

    expect(geoJsonMetadata(truncated), isEmpty);
  });

  test('returns nothing for absent metadata or an unreadable file', () {
    expect(geoJsonMetadata('{"type":"FeatureCollection","features":[]}'),
        isEmpty);
    expect(geoJsonMetadata(null), isEmpty);
  });
}
