import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_woods_map/map/policy_markdown.dart';

void main() {
  // The shape of a real generated file, matching what
  // tools/gis/build_policies_on.py writes for G396 — including the trailing two
  // spaces on field lines, which are markdown hard breaks.
  const source = '''
# Crown Land Use Policy — G396

**Name:** Multiple Natural Resource Use (General Use Area)  
**Policy ID:** G396  
**Official area:** 614181.40 ha  

## Hunting

Listed as a permitted use.

| Use | Permitted | Guidelines |
|---|---|---|
| Hunting | Yes | Hunting is permitted in accordance with the Fish and Wildlife Conservation Act and regulations. |

Provincial season rules still apply.

## Land use intent

Within this area, resource management will be directed to multiple use
management.
''';

  group('parsing what the build scripts emit', () {
    final blocks = parsePolicyMarkdown(source);

    test('no markdown punctuation survives into the text', () {
      for (final block in blocks) {
        final text = switch (block) {
          PolicyHeading(:final text) => text,
          PolicyParagraph(:final text) => text,
          PolicyField(:final label, :final value) => '$label $value',
          PolicyTable(:final headers, :final rows) =>
            [...headers, for (final row in rows) ...row].join(' '),
        };
        expect(text, isNot(contains('**')));
        expect(text, isNot(contains('|')));
        expect(text, isNot(startsWith('#')));
      }
    });

    test('the heading keeps its em dash', () {
      final heading = blocks.whereType<PolicyHeading>().first;
      expect(heading.level, 1);
      expect(heading.text, 'Crown Land Use Policy — G396');
    });

    test('field lines become label and value, not prose', () {
      final fields = blocks.whereType<PolicyField>().toList();
      expect(fields.map((f) => f.label),
          containsAll(['Name', 'Policy ID', 'Official area']));
      expect(fields.first.value, 'Multiple Natural Resource Use (General Use Area)');
    });

    test('a table keeps its cells and drops only the rule row', () {
      final table = blocks.whereType<PolicyTable>().single;
      expect(table.headers, ['Use', 'Permitted', 'Guidelines']);
      expect(table.rows, hasLength(1));
      expect(table.rows.single[0], 'Hunting');
      expect(table.rows.single[1], 'Yes');
      expect(table.rows.single[2], contains('Fish and Wildlife Conservation Act'));
    });

    test('a wrapped paragraph rejoins into one', () {
      final wrapped = blocks
          .whereType<PolicyParagraph>()
          .where((p) => p.text.startsWith('Within this area'))
          .single;
      expect(wrapped.text, endsWith('multiple use management.'));
      expect(wrapped.text, isNot(contains('\n')));
    });

    // A legal document is the one place a lenient parser has to be. Dropping an
    // unrecognised line would silently remove wording someone is relying on.
    test('an unrecognised line is kept rather than dropped', () {
      final blocks = parsePolicyMarkdown('> a blockquote we never emit');
      expect(blocks.whereType<PolicyParagraph>().single.text,
          '> a blockquote we never emit');
    });

    // A grid is right for a table of short values and wrong for one carrying a
    // paragraph, because a phone gives the paragraph column about ten characters
    // a line.
    testWidgets('a table of prose is not laid out as a grid', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PolicyMarkdown(source)),
        ),
      ));
      expect(find.byType(Table), findsNothing);
      expect(find.textContaining('Fish and Wildlife Conservation Act'),
          findsOneWidget);
    });

    testWidgets('a row title that repeats its heading is not printed twice',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PolicyMarkdown(source)),
        ),
      ));
      // The heading, and not the row's first cell as well.
      expect(find.text('Hunting'), findsOneWidget);
    });

    testWidgets('a table of short values keeps its grid', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: PolicyMarkdown(
            '| Class | Use | Permitted |\n|---|---|---|\n'
            '| Commercial | Bait Fishing | Yes |\n',
          ),
        ),
      ));
      expect(find.byType(Table), findsOneWidget);
    });

    test('a ragged table row is kept, padded to the header', () {
      final table = parsePolicyMarkdown(
        '| A | B | C |\n|---|---|---|\n| only one |\n',
      ).whereType<PolicyTable>().single;
      expect(table.rows.single, hasLength(1));
      expect(table.headers, hasLength(3));
    });
  });
}
