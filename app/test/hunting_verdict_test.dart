import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/map/land_info_sheet.dart';

/// The one green in the palette, reserved for a source that actually permits
/// hunting. Duplicated here on purpose: if someone widens what may use it, this
/// file should fail rather than follow along.
const Color permitted = Color(0xFF1B5E20);

void main() {
  group('a source that permits hunting', () {
    test('reads as permitted, and is the only thing that gets the green', () {
      final (label, colour) = huntingVerdict(true, 'clupa');
      expect(label, 'Hunting listed as permitted');
      expect(colour, permitted);
    });
  });

  group('Crown land with no area-specific policy', () {
    // 52% of Ontario's Crown land by area. The province has stated no position
    // on this ground, so the answer is inferred from a rule about Crown land in
    // general, and it must not be dressed as a permission. It used to be green.
    final (label, colour) = huntingVerdict(null, 'tenure_only');

    test('does not borrow the colour reserved for a real permission', () {
      expect(colour, isNot(permitted));
    });

    test('says the rules are general rather than about this parcel', () {
      expect(label, 'General rules apply, no local policy');
      expect(label.toLowerCase(), contains('general rules'));
    });

    test('never claims hunting is permitted here', () {
      expect(label.toLowerCase(), isNot(contains('permitted')));
      expect(label.toLowerCase(), isNot(contains('allowed')));
    });

    // "Not on record" is for genuine silence. This parcel is not silence: it is
    // known Crown land the province leaves to the general rules, and saying
    // otherwise sends people looking for an answer that already exists.
    test('is not reported as missing data', () {
      expect(label.toLowerCase(), isNot(contains('not on record')));
      expect(huntingVerdict(null, null).$1, 'Hunting status not on record');
    });
  });

  group('a named basis outranks the boolean', () {
    // The reason matters as much as the answer: these send a user to different
    // authorities for a second opinion.
    test('a park never opened to hunting says so', () {
      expect(
        huntingVerdict(null, 'reg663_part3_unlisted').$1,
        'No hunting — park not opened',
      );
    });

    test('a reserve reads as permission needed, not as a prohibition', () {
      final (label, colour) = huntingVerdict(null, 'reserve_permission');
      expect(label, 'Permission of the First Nation required');
      expect(colour, isNot(const Color(0xFFB3261E)));
    });

    test('an unconfirmed federal area is treated as closed', () {
      expect(
        huntingVerdict(true, 'nwa_unverified').$1,
        'Treat as closed — rules unconfirmed',
      );
    });

    // A conservation reserve is the mirror image of a park: the Act permits
    // hunting unless a regulation prohibits it, and forbids a management plan
    // from narrowing that. This is a statute permitting hunting outright, so it
    // is one of the few things entitled to the green.
    test('the Act permitting hunting in a reserve says so, in green', () {
      final (label, colour) = huntingVerdict(true, 'ppcra_s15_3');
      expect(label, 'Hunting permitted by the Act');
      expect(colour, permitted);
    });

    // Algonquin's Bruton and Clyde townships are opened by the Act, not by
    // O. Reg. 663/98, so no schedule matches and the park would otherwise be
    // reported closed. It is open in part, exactly like a partial schedule.
    test('a park the Act opens in part is not reported as closed', () {
      final (label, colour) = huntingVerdict(null, 'ppcra_s15_2_partial');
      expect(label, 'Open in part of this park only');
      expect(label, huntingVerdict(null, 'reg663_part3_partial').$1);
      expect(colour, isNot(permitted));
      expect(label.toLowerCase(), isNot(contains('not opened')));
    });
  });

  group('everything that is not a yes', () {
    // Whatever the data says, only an explicit permission may look like one.
    for (final (value, basis) in <(Object?, String?)>[
      (false, 'clupa'),
      (null, 'tenure_only'),
      (null, null),
      ('conditional', 'disposition_occupied'),
      ('something the app has never seen', null),
    ]) {
      test('${value ?? 'null'} / ${basis ?? 'no basis'} is not green', () {
        expect(huntingVerdict(value, basis).$2, isNot(permitted));
      });
    }

    test('an unrecognised value is shown as-is rather than guessed at', () {
      expect(huntingVerdict('umbrella', null).$1, 'umbrella');
    });
  });

  group('the mapped extent of a parcel', () {
    // A hectare is 0.01 km². Dividing by 100 and then rounding to one decimal
    // reported every parcel over 1,000 ha at a tenth of its size, and the large
    // parcels are the ones whose size a user is most likely to lean on.
    test('Round Lake is 26.3 km², not 2.6', () {
      expect(formatArea(2625.6), '26.3 km²');
    });

    test('a hundred hectares is a square kilometre, however large the parcel', () {
      expect(formatArea(1000), '10.0 km²');
      expect(formatArea(100000), '1000 km²');
    });

    test('below a thousand hectares it stays in hectares', () {
      expect(formatArea(999), '999 ha');
      expect(formatArea(19.23), '19 ha');
      expect(formatArea(4.5), '4.5 ha');
    });
  });

  group('the instrument a quote comes from', () {
    // A conservation reserve is the only layer opened by an Act rather than by a
    // regulation, and the quote box prints the citation right underneath, so
    // calling the PPCRA a regulation is an error the reader can see.
    test('a conservation reserve quotes the Act', () {
      expect(quotesStatute('ppcra_s15_3'), isTrue);
    });

    test('every park basis quotes a regulation', () {
      expect(quotesStatute('reg663_part3'), isFalse);
      expect(quotesStatute('reg663_part3_partial'), isFalse);
      expect(quotesStatute('reg663_part3_unlisted'), isFalse);
      expect(quotesStatute('ppcra_s15_2_partial'), isFalse);
      expect(quotesStatute(null), isFalse);
    });
  });
}
