import 'package:flutter/material.dart';

enum BasemapKind {
  offline,
  streets,
  satellite,
  hybrid,
}

extension BasemapKindX on BasemapKind {
  String get label => switch (this) {
        BasemapKind.offline => 'Offline (simple)',
        BasemapKind.streets => 'Streets',
        BasemapKind.satellite => 'Satellite',
        BasemapKind.hybrid => 'Hybrid',
      };

  String get shortHint => switch (this) {
        BasemapKind.offline => 'Works offline · no street detail',
        BasemapKind.streets => 'OpenFreeMap · needs network',
        BasemapKind.satellite =>
          'ON/QC aerial photos · Sentinel-2 elsewhere · needs network',
        BasemapKind.hybrid =>
          'Aerial photos with road, water and place names · needs network',
      };

  IconData get icon => switch (this) {
        BasemapKind.offline => Icons.map_outlined,
        BasemapKind.streets => Icons.signpost_outlined,
        BasemapKind.satellite => Icons.satellite_alt,
        BasemapKind.hybrid => Icons.layers_outlined,
      };

  /// Streets use the OpenFreeMap hosted style; satellite and hybrid are local
  /// style JSON that stacks provincial orthophotography over global Sentinel-2,
  /// with hybrid adding OpenFreeMap's labels on top.
  String? get remoteStyleUrl => switch (this) {
        BasemapKind.streets => 'https://tiles.openfreemap.org/styles/liberty',
        BasemapKind.offline ||
        BasemapKind.satellite ||
        BasemapKind.hybrid =>
          null,
      };

  String? get assetStylePath => switch (this) {
        BasemapKind.offline => 'assets/styles/offline.json',
        BasemapKind.satellite => 'assets/styles/satellite.json',
        BasemapKind.hybrid => 'assets/styles/hybrid.json',
        BasemapKind.streets => null,
      };

  /// Whether an area of this basemap can be saved for offline use.
  ///
  /// The offline basemap draws a flat background and has nothing to fetch.
  bool get supportsOfflineAreas => this != BasemapKind.offline;
}
