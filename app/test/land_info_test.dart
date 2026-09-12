import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/data/models.dart';
import 'package:open_woods_map/map/land_info.dart';
import 'package:open_woods_map/map/overlay_controller.dart';

LandFeature feature(String layerId, Map<String, dynamic> properties) =>
    LandFeature(layerId: layerId, properties: properties, geometry: const {});

LandInfo infoWith(List<LandFeature> hits) => LandInfo(
      latitude: 45.0,
      longitude: -79.0,
      hits: hits,
      attribution: 'test',
    );

void main() {
  group('no layer reaches the map without the card deciding about it', () {
    // Layers the card reports somewhere other than the land-use list. Anything
    // that is neither here nor in landUseLayers is drawn on the map, toggled in
    // the panel, and then silently missing when the user taps it — which reads
    // as the data being wrong rather than the list being short. crown_disposition
    // shipped that way: on the map, in the panel, in the pack, invisible here.
    const reportedElsewhere = {
      'sunday_gun': 'has its own Sunday gun section',
      'municipalities': 'resolves the local government line',
      'land_use_plan': 'answers "the atlas never reached here"',
    };

    test('every drawn layer is either land use or deliberately elsewhere', () {
      for (final id in OverlayController.layerOrder) {
        expect(
          LandInfo.landUseLayers.contains(id) ||
              reportedElsewhere.containsKey(id),
          isTrue,
          reason: '$id is drawn on the map but Land Info would never show it. '
              'Add it to LandInfo.landUseLayers, or to reportedElsewhere here '
              'with the section that does report it.',
        );
      }
    });

    test('a Crown disposition reaches the land-use list', () {
      final info = infoWith([
        feature('crown_land', {'hunting_allowed': null, 'basis': 'tenure_only'}),
        feature('crown_disposition', {
          'kind': 'Licence of occupation',
          'hunting_allowed': 'conditional',
          'basis': 'disposition_occupied',
        }),
      ]);
      expect(
        info.landUse.map((f) => f.layerId),
        containsAll(['crown_land', 'crown_disposition']),
      );
    });

    // It qualifies the parcel underneath, so it has to be read after it.
    test('it is listed after the Crown parcel it sits on', () {
      final info = infoWith([
        feature('crown_land', {'hunting_allowed': null, 'basis': 'tenure_only'}),
        feature('crown_disposition', {'basis': 'disposition_occupied'}),
      ]);
      final ids = info.landUse.map((f) => f.layerId).toList();
      expect(ids.indexOf('crown_disposition'),
          greaterThan(ids.indexOf('crown_land')));
    });

    // A lease is not a closure. Putting it behind the red banner would say no
    // hunting, when the truth is that the occupier may ask you to leave.
    test('it is not treated as a closure', () {
      final info = infoWith([
        feature('crown_disposition', {
          'hunting_allowed': 'conditional',
          'basis': 'disposition_occupied',
        }),
      ]);
      expect(info.closures, isEmpty);
    });
  });

  group('park hunting permission from O. Reg. 663/98 Part 3', () {
    test('a park opened in whole reports permitted', () {
      final park = feature('parks', {
        'name': 'ROCK POINT PROVINCIAL PARK',
        'hunting_allowed': true,
        'basis': 'reg663_part3',
        'hunting_extent': 'whole',
        'reg_schedule': 14,
        'reg_text': 'Rock Point Provincial Park.',
      });
      expect(park.huntingAllowed, isTrue);
      expect(park.huntingExtent, 'whole');
      expect(park.regulationSchedule, 14);
    });

    test('a park opened only in part is not reported as permitted', () {
      // The open piece is metes-and-bounds prose the province never mapped, so
      // the outline cannot answer for a specific point and must not claim to.
      final park = feature('parks', {
        'name': 'ALGONQUIN PROVINCIAL PARK',
        'hunting_allowed': null,
        'basis': 'reg663_part3_partial',
        'hunting_extent': 'part',
        'reg_schedule': 42,
        'reg_text': 'The part of Algonquin Provincial Park known as the '
            '“McRae Addition” located in Eyre Township.',
      });
      expect(park.huntingAllowed, isNull);
      expect(park.huntingExtent, 'part');
      expect(park.regulationText, contains('McRae Addition'));
    });

    test('an unscheduled park is closed, not unknown', () {
      final park = feature('parks', {
        'name': 'PINERY PROVINCIAL PARK',
        'hunting_allowed': false,
        'basis': 'reg663_part3_unlisted',
      });
      expect(park.huntingAllowed, isFalse);
      expect(park.huntingExtent, isNull);
    });

    test('a carve-out survives verbatim rather than being summarised', () {
      final park = feature('parks', {
        'name': 'GRUNDY LAKE PROVINCIAL PARK',
        'hunting_allowed': true,
        'basis': 'reg663_part3',
        'hunting_extent': 'whole',
        'reg_text': 'Grundy Lake Provincial Park, excepting those parts '
            'thereof that are posted with signs prohibiting hunting.',
      });
      expect(park.regulationText, contains('posted with signs'));
    });
  });

  group('Sunday gun hunting', () {
    test('resolves the listed municipality covering the point', () {
      final info = infoWith([
        feature('crown_land', {'hunting_allowed': true}),
        feature('sunday_gun', {
          'name': 'Township of Armour',
          'listed_as': 'Armour, Township of',
          'sunday_gun': true,
          'basis': 'reg663_part7',
        }),
      ]);
      expect(info.sundayGun, isNotNull);
      expect(info.sundayGun!.properties['listed_as'], 'Armour, Township of');
    });

    test('is null where no polygon covers the point', () {
      // Null is a meaningful answer here, not a missing one: south of the French
      // and Mattawa rivers an unlisted municipality is a prohibition.
      final info = infoWith([feature('crown_land', {'hunting_allowed': true})]);
      expect(info.sundayGun, isNull);
    });

    group('where more than one feature covers the point', () {
      LandFeature scheduled() => feature('sunday_gun', {
            'name': 'Municipality of Killarney',
            'listed_as': 'Killarney, Town of',
            'basis': 'reg663_part7',
          });
      LandFeature north() => feature('sunday_gun', {
            'name': 'North of the French and Mattawa rivers',
            'basis': 'reg665_s66',
            'near_divide': false,
          });
      LandFeature band() => feature('sunday_gun', {
            'name': 'Near the French-Mattawa divide',
            'basis': 'reg665_s66',
            'near_divide': true,
          });

      // Killarney straddles the mouth of the French River, so it is both listed
      // in the schedule and inside the north polygon. Either answer is a yes,
      // but the schedule is the one that does not depend on which bank you are
      // standing on.
      test('the schedule outranks geography', () {
        expect(infoWith([north(), scheduled()]).sundayGun!.basis,
            'reg663_part7');
        expect(infoWith([scheduled(), north()]).sundayGun!.basis,
            'reg663_part7');
      });

      // The band only ever says "we cannot tell". Letting it win over a
      // definite answer would turn a yes into a shrug.
      test('anything definite outranks the uncertainty band', () {
        expect(infoWith([band(), scheduled()]).sundayGun!.basis,
            'reg663_part7');
        expect(
          infoWith([band(), north()]).sundayGun!.properties['near_divide'],
          isFalse,
        );
      });

      test('the band still answers when it is all there is', () {
        expect(
          infoWith([band()]).sundayGun!.properties['near_divide'],
          isTrue,
        );
      });
    });

    test('does not appear in the land use list', () {
      final info = infoWith([
        feature('sunday_gun', {'sunday_gun': true}),
        feature('parks', {'name': 'A park'}),
      ]);
      expect(
        info.landUse.map((f) => f.layerId),
        isNot(contains('sunday_gun')),
      );
    });
  });

  group('closures still outrank everything', () {
    test('a game preserve is reported first even with a park underneath', () {
      final info = infoWith([
        feature('parks', {'name': 'A park', 'hunting_allowed': true}),
        feature('game_preserve', {
          'name': 'Chapleau',
          'basis': 'fwca_s9',
          'hunting_allowed': false,
        }),
      ]);
      expect(info.gamePreserve, isNotNull);
      expect(info.landUse.first.layerId, 'game_preserve');
      expect(info.closures.single.layerId, 'game_preserve');
    });

    test('defence property closes ground the tenure layer shows as Crown', () {
      final info = infoWith([
        feature('crown_land', {'hunting_allowed': null, 'basis': 'tenure_only'}),
        feature('defence_land', {
          'name': 'Canadian Forces Base Petawawa',
          'basis': 'dnd_closed',
          'hunting_allowed': false,
          'record_url': 'https://www.tbs-sct.gc.ca/dfrp-rbif/pn-nb/11347-eng.aspx',
        }),
      ]);
      expect(info.defenceLand, isNotNull);
      expect(info.closures.single.layerId, 'defence_land');
      expect(info.landUse.first.layerId, 'defence_land');
      expect(info.defenceLand!.recordUrl?.host, 'www.tbs-sct.gc.ca');
    });

    // Found by comparing the two apps at Bonnechere Provincial Park, which the
    // regulation never opened. Ours put a green Sunday-gun tick, then "General
    // rules apply, no local policy", then "Occupied" above it, and reached the
    // prohibition four screens down. iHunter led with it.
    test('a park the regulation never opened leads the card', () {
      final info = infoWith([
        feature('crown_land', {'hunting_allowed': null, 'basis': 'tenure_only'}),
        feature('crown_disposition', {
          'hunting_allowed': 'conditional',
          'basis': 'disposition_occupied',
        }),
        feature('parks', {
          'name': 'BONNECHERE PROVINCIAL PARK (RECREATIONAL CLASS)',
          'hunting_allowed': false,
          'basis': 'reg663_part3_unlisted',
        }),
      ]);
      expect(info.closures.single.layerId, 'parks');
      expect(info.landUse.first.layerId, 'parks');
    });

    test('a park the regulation opened is not a closure', () {
      final info = infoWith([
        feature('parks', {
          'name': 'WESTMEATH PROVINCIAL PARK (NATURAL ENVIRONMENT CLASS)',
          'hunting_allowed': true,
          'basis': 'reg663_part3',
        }),
      ]);
      expect(info.closures, isEmpty);
      expect(info.landUse.map((f) => f.layerId), contains('parks'));
    });

    // Neither yes nor no, so it must not be behind a banner that says no: the
    // ground inside this outline genuinely is open somewhere.
    test('a park opened only in part is not a closure either', () {
      final info = infoWith([
        feature('parks', {
          'name': 'ALGONQUIN PROVINCIAL PARK (NATURAL ENVIRONMENT CLASS)',
          'hunting_allowed': null,
          'basis': 'reg663_part3_partial',
        }),
      ]);
      expect(info.closures, isEmpty);
    });

    test('provincial and federal closures are both reported', () {
      // They are enforced by different officers, so showing only the first
      // would leave the user arguing with the wrong government.
      final info = infoWith([
        feature('game_preserve', {'basis': 'fwca_s9', 'hunting_allowed': false}),
        feature('federal_closure', {
          'name': 'Mississippi Lake National Wildlife Area',
          'basis': 'nwa_closed',
          'hunting_allowed': false,
        }),
      ]);
      expect(info.closures.map((f) => f.layerId),
          ['game_preserve', 'federal_closure']);
    });
  });

  group('one park, one answer', () {
    // Ontario states a park's hunting rule twice. The atlas policy that reaches
    // us through crown_land reads as a flat prohibition; O. Reg. 663/98 Part 3,
    // which reaches us through parks, is the regulation that actually opens a
    // park and opens several of them in only a described part. At Algonquin the
    // card showed the same park name twice, with two different certainties and
    // nothing to say which governed.
    LandInfo algonquin() => infoWith([
          feature('crown_land', {
            'name': 'ALGONQUIN PROVINCIAL PARK (NATURAL ENVIRONMENT CLASS)',
            'hunting_allowed': false,
            'basis': 'protected_area',
            'designation': 'Provincial Park',
            'policy_id': 'P1915',
          }),
          feature('parks', {
            'name': 'ALGONQUIN PROVINCIAL PARK (NATURAL ENVIRONMENT CLASS)',
            'hunting_allowed': null,
            'basis': 'reg663_part3_partial',
            'hunting_extent': 'part',
            'reg_schedule': 42,
          }),
        ]);

    test('the regulation governs and the atlas copy steps aside', () {
      final ids = algonquin().landUse.map((f) => f.layerId).toList();
      expect(ids, contains('parks'));
      expect(ids, isNot(contains('crown_land')));
    });

    test('so a partly opened park is not reported as closed', () {
      // The failure this prevents: the atlas verdict is a flat false, so leaving
      // it in put "Hunting not permitted" on a park that is open in part.
      expect(algonquin().closures, isEmpty);
    });

    // A wilderness area carries the same basis and has no counterpart in the
    // parks layer, so nothing there is superseded.
    test('a protected area with no park polygon still speaks for itself', () {
      final info = infoWith([
        feature('crown_land', {
          'name': 'Killarney Wilderness Area',
          'hunting_allowed': false,
          'basis': 'protected_area',
          'designation': 'Wilderness Area',
        }),
      ]);
      expect(info.landUse.map((f) => f.layerId), contains('crown_land'));
      expect(info.closures.single.layerId, 'crown_land');
    });

    // Only the park's own atlas policy steps aside. Tenure under a park is a
    // different fact and the card still needs it.
    test('ordinary Crown tenure under a park is untouched', () {
      final info = infoWith([
        feature('crown_land', {'hunting_allowed': null, 'basis': 'tenure_only'}),
        feature('parks', {
          'name': 'BONNECHERE PROVINCIAL PARK (RECREATIONAL CLASS)',
          'hunting_allowed': false,
          'basis': 'reg663_part3_unlisted',
        }),
      ]);
      expect(info.landUse.map((f) => f.layerId), contains('crown_land'));
    });
  });

  // Ontario states the rule for a conservation reserve in the Act, the opposite
  // way round from a park: s. 15 (1) closes a park unless a regulation opens it,
  // s. 15 (3) opens a reserve unless a regulation closes it. We carried no
  // reserve boundaries at all, so Conroys Marsh read as undesignated Crown land
  // where iHunter named the reserve.
  group('conservation reserves', () {
    LandFeature reserve([Map<String, dynamic> extra = const {}]) =>
        feature('conservation_reserve', {
          'name': 'CONROYS MARSH CONSERVATION RESERVE',
          'hunting_allowed': true,
          'basis': 'ppcra_s15_3',
          'designation': 'Conservation Reserve',
          'regulation': 'O. Reg. 237/03',
          ...extra,
        });

    test('a reserve reaches the land-use list and is not a closure', () {
      final info = infoWith([
        feature('crown_land', {'hunting_allowed': null, 'basis': 'tenure_only'}),
        reserve(),
      ]);
      expect(
        info.landUse.map((f) => f.layerId),
        containsAll(['crown_land', 'conservation_reserve']),
      );
      expect(info.closures, isEmpty);
    });

    // The one prohibition s. 15 (3) contemplates that we actually carry. Six
    // reserves are overlapped by a Crown game preserve, and at Conroys Marsh
    // iHunter shows the reserve's permission and the preserve's prohibition side
    // by side without resolving them.
    test('a game preserve over a reserve leads the card', () {
      final info = infoWith([
        reserve(),
        feature('game_preserve', {
          'name': 'Conroy Marsh Crown Game Preserve',
          'hunting_allowed': false,
          'basis': 'fwca_s9',
        }),
      ]);
      expect(info.closures.single.layerId, 'game_preserve');
      expect(info.landUse.first.layerId, 'game_preserve');
    });
  });

  // Ontario's tenure record covers the beds of lakes and rivers, so a tap in the
  // middle of Round Lake returned a Crown parcel and described it in exactly the
  // words it uses for dry ground. Dropping those parcels would invent an
  // exclusion the province never made, so they stay and say what they are.
  group('a parcel that is a lake bed', () {
    test('is flagged, and the flag is only ever an explicit true', () {
      final wet = feature('crown_land', {
        'basis': 'tenure_only',
        'area_ha': 2625.6,
        'over_water': true,
      });
      expect(wet.isOverWater, isTrue);
      expect(
        feature('crown_land', {'basis': 'tenure_only'}).isOverWater,
        isFalse,
        reason: 'a parcel that was never measured must not read as water',
      );
    });

    // Water is not a closure. Waterfowl hunting over Crown water is legal, and a
    // lake bed that led the card behind a prohibition banner would be the same
    // error as erasing it, pointed the other way.
    test('is not a closure and does not change the verdict', () {
      final info = infoWith([
        feature('crown_land', {
          'hunting_allowed': null,
          'basis': 'tenure_only',
          'over_water': true,
        }),
      ]);
      expect(info.closures, isEmpty);
      expect(info.landUse.single.huntingAllowed, isNull);
      expect(info.landUse.single.basis, 'tenure_only');
    });
  });

  group('federal wildlife areas', () {
    test('a wildlife area authorising waterfowl is not a flat closure', () {
      // The regulation opens it, but only in areas the Minister designates and
      // never publishes, so it belongs in the land-use list with its conditions
      // rather than behind a banner that says no.
      final nwa = feature('federal_closure', {
        'name': 'Long Point National Wildlife Area - Long Point',
        'basis': 'nwa_waterfowl',
        'hunting_allowed': null,
        'hunting_extent': 'part',
        'reg_text': 'Sport hunting of waterfowl, including with dogs off-leash, '
            'in designated areas from half an hour before sunrise to half an '
            'hour after sunset',
      });
      final info = infoWith([nwa]);
      expect(info.closures, isEmpty);
      expect(info.federalClosure, isNotNull);
      expect(nwa.huntingAllowed, isNull);
      expect(nwa.huntingExtent, 'part');
      expect(nwa.regulationText, contains('designated areas'));
    });

    test('a sanctuary carries the firearm prohibition, not just no hunting', () {
      final mbs = feature('federal_closure', {
        'name': 'Upper Canada Migratory Bird Sanctuary',
        'basis': 'mbs_closed',
        'hunting_allowed': false,
        'firearm_prohibited': true,
      });
      expect(mbs.huntingAllowed, isFalse);
      expect(mbs.properties['firearm_prohibited'], isTrue);
    });

    test('an area absent from the schedule is closed, not assumed open', () {
      final nwa = feature('federal_closure', {
        'name': 'Some New Wildlife Area',
        'basis': 'nwa_unverified',
        'hunting_allowed': false,
      });
      expect(nwa.huntingAllowed, isFalse);
    });
  });

  group('reserve land', () {
    test('is permission required, never a closure', () {
      // The distinction is the whole point: an Ontario licence does not reach
      // this land, which is not the same as hunting being prohibited on it.
      final reserve = feature('first_nations', {
        'name': 'Curve Lake First Nation 35',
        'basis': 'reserve_permission',
        'hunting_allowed': null,
        'permit_required': true,
        'boundary_accuracy': 'mapped',
      });
      final info = infoWith([reserve]);
      expect(reserve.huntingAllowed, isNull);
      expect(info.closures, isEmpty);
      expect(info.landUse.map((f) => f.layerId), contains('first_nations'));
    });

    test('a loosely surveyed boundary is drawn as approximate', () {
      final reserve = feature('first_nations', {
        'basis': 'reserve_permission',
        'boundary_accuracy': 'approximate',
        'survey_accuracy': 'Greater than 100 metres',
      });
      expect(reserve.isApproximate, isTrue);
    });
  });

  group('Far North land use planning', () {
    LandFeature plan(String scope, [Map<String, Object?> extra = const {}]) =>
        feature('land_use_plan', {'plan_scope': scope, ...extra});

    test('the boundary is recognised without being a land-use entry', () {
      final info = infoWith([
        feature('crown_land', {'hunting_allowed': null, 'basis': 'tenure_only'}),
        plan('far_north', {'name': 'Far North of Ontario'}),
      ]);
      expect(info.inFarNorth, isTrue);
      expect(info.communityLandUsePlan, isNull);
      // Context only: it must not appear as a land-use polygon of its own.
      expect(info.landUse.map((f) => f.layerId), isNot(contains('land_use_plan')));
    });

    test('a community plan is found and carries its document link', () {
      final info = infoWith([
        plan('far_north'),
        plan('community', {
          'name': 'Keeping the Land',
          'year_approved': 2006,
          'record_url': 'http://www.whitefeatherforest.ca/land-use-strategy.pdf',
        }),
      ]);
      expect(info.inFarNorth, isTrue);
      expect(info.communityLandUsePlan?.name, 'Keeping the Land');
      expect(info.communityLandUsePlan?.recordUrl, isNotNull);
    });

    test('south of the line nothing changes', () {
      final info = infoWith([
        feature('crown_land', {'hunting_allowed': true, 'basis': 'tenure_only'}),
      ]);
      expect(info.inFarNorth, isFalse);
      expect(info.communityLandUsePlan, isNull);
    });
  });

  group('conservation authority land', () {
    test('is neither open nor closed, and names who to ask', () {
      final ca = feature('conservation_authority', {
        'name': 'Glen Haffy Conservation Area',
        'basis': 'ca_permit',
        'hunting_allowed': null,
        'permit_required': true,
        'authority': 'Toronto and Region Conservation Authority',
      });
      final info = infoWith([ca]);
      expect(info.conservationAuthority, isNotNull);
      expect(ca.huntingAllowed, isNull);
      expect(info.closures, isEmpty);
      expect(info.landUse.map((f) => f.layerId),
          contains('conservation_authority'));
      expect(ca.properties['authority'],
          'Toronto and Region Conservation Authority');
    });

    test('an incomplete layer that drew nothing here says so', () {
      // The whole point: CPCAD does not hold every authority's property, so
      // silence from this layer must not read as permission.
      final layers = {
        'conservation_authority': LoadedLayer(
          manifest: const LayerManifest(
            id: 'conservation_authority',
            label: 'Conservation authority land',
            path: 'overlays/conservation_authority.geojson',
            featureCount: 409,
          ),
          metadata: const {
            'coverage_incomplete': true,
            'coverage_note': 'Grand River Conservation Authority is absent '
                'entirely, so the absence of a polygon is not evidence that the '
                'land is open.',
          },
          sourceUri: 'file:///tmp/ca.geojson',
        ),
      };
      final elsewhere = infoWith([feature('crown_land', {})]);
      expect(elsewhere.incompleteCoverage(layers).single,
          contains('Grand River'));

      // On a property the layer does cover, the caveat would only bury the
      // instruction to get a permit.
      final onProperty = infoWith([
        feature('conservation_authority', {'basis': 'ca_permit'}),
      ]);
      expect(onProperty.incompleteCoverage(layers), isEmpty);
    });
  });

  group('layer metadata carries the legal source', () {
    test('exposes regulation, currency date and link', () {
      final layer = LoadedLayer(
        manifest: const LayerManifest(
          id: 'parks',
          label: 'Parks',
          path: 'overlays/parks.geojson',
          featureCount: 347,
        ),
        metadata: const {
          'hunting_source': 'O. Reg. 663/98 (Area Descriptions) Part 3',
          'hunting_source_url':
              'https://www.ontario.ca/laws/regulation/980663',
          'hunting_currency_date': '2026-04-01',
        },
        sourceUri: 'file:///tmp/parks.geojson',
      );
      expect(layer.huntingSource, contains('663/98'));
      expect(layer.huntingSourceUrl?.host, 'www.ontario.ca');
      expect(layer.currencyDate, '2026-04-01');
    });
  });
}
