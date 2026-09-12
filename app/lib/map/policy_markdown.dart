import 'package:flutter/material.dart';

/// A renderer for the policy files this repo generates, and only those.
///
/// The card sends people here for the official wording, so the wording has to be
/// readable: until now the dialog printed the file verbatim and a hunter looking
/// for whether hunting is permitted read `|---|---|---|` and `**Name:**` on the
/// way to the answer. A full markdown package would carry far more syntax than
/// `tools/gis/build_policies_*.py` ever emits, and the one in wide use is being
/// wound down, so this handles the emitted subset and nothing else. Anything
/// unrecognised falls through as a paragraph rather than being dropped — losing a
/// line of a legal document to a parser is worse than showing it plainly.
sealed class PolicyBlock {
  const PolicyBlock();
}

class PolicyHeading extends PolicyBlock {
  const PolicyHeading(this.level, this.text);
  final int level;
  final String text;
}

/// A `**Label:** value` line. These arrive as a run of consecutive lines and
/// read as a definition list, not as prose.
class PolicyField extends PolicyBlock {
  const PolicyField(this.label, this.value);
  final String label;
  final String value;
}

class PolicyParagraph extends PolicyBlock {
  const PolicyParagraph(this.text);
  final String text;
}

class PolicyTable extends PolicyBlock {
  const PolicyTable(this.headers, this.rows);
  final List<String> headers;
  final List<List<String>> rows;
}

final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _field = RegExp(r'^\*\*(.+?):\*\*\s*(.*)$');
final _tableRule = RegExp(r'^\|[\s\-:|]+\|$');

List<PolicyBlock> parsePolicyMarkdown(String source) {
  final blocks = <PolicyBlock>[];
  final paragraph = <String>[];
  final table = <List<String>>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(PolicyParagraph(paragraph.join(' ')));
    paragraph.clear();
  }

  void flushTable() {
    if (table.isEmpty) return;
    // A table with no body is still worth showing as its header row rather than
    // vanishing: an empty section is a fact about the policy.
    blocks.add(PolicyTable(table.first, table.skip(1).toList()));
    table.clear();
  }

  for (final raw in source.split('\n')) {
    // Two trailing spaces is a markdown hard break, and every field line in
    // these files carries one.
    final line = raw.trimRight();

    if (line.startsWith('|')) {
      flushParagraph();
      if (!_tableRule.hasMatch(line)) {
        table.add([
          for (final cell in line.split('|').skip(1)) cell.trim(),
        ]..removeLast());
      }
      continue;
    }
    flushTable();

    if (line.trim().isEmpty) {
      flushParagraph();
      continue;
    }
    if (_heading.firstMatch(line) case final match?) {
      flushParagraph();
      blocks.add(PolicyHeading(match.group(1)!.length, match.group(2)!.trim()));
      continue;
    }
    if (_field.firstMatch(line) case final match?) {
      flushParagraph();
      blocks.add(PolicyField(match.group(1)!.trim(), match.group(2)!.trim()));
      continue;
    }
    paragraph.add(line.trim());
  }
  flushParagraph();
  flushTable();
  return blocks;
}

/// A column at or under this many characters can size to its own content.
const _narrowColumnChars = 22;

/// Past this, a column holds prose rather than a value, and the table stops
/// being a table.
///
/// Two shapes come out of the build scripts. One is a genuine grid of short
/// values — class, use, yes. The other has a four-hundred character legal
/// guideline in the last column, and on a phone a three-column grid gives that
/// column about ten characters a line, which is a worse way to read a regulation
/// than the raw markdown was. So a table carrying prose is laid out as one block
/// per row, where the wording gets the full width.
const _proseColumnChars = 40;

int _widest(Iterable<String> cells) =>
    cells.map((cell) => cell.length).fold(0, (a, b) => a > b ? a : b);

List<int> _columnWidths(PolicyTable table) => [
      for (var column = 0; column < table.headers.length; column++)
        _widest([
          table.headers[column],
          for (final row in table.rows)
            if (column < row.length) row[column],
        ]),
    ];

class PolicyMarkdown extends StatelessWidget {
  const PolicyMarkdown(this.source, {super.key});

  final String source;

  @override
  Widget build(BuildContext context) {
    final blocks = parsePolicyMarkdown(source);
    final children = <Widget>[];
    var heading = '';

    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block case PolicyHeading(:final text)) heading = text;
      // Fields run together as a block, so they get no gap between them.
      final tight = i > 0 && block is PolicyField && blocks[i - 1] is PolicyField;
      if (i > 0) children.add(SizedBox(height: tight ? 2 : 12));
      children.add(switch (block) {
        PolicyHeading(:final level, :final text) => Text(
            text,
            style: TextStyle(
              fontSize: level <= 1 ? 18 : 15,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        PolicyField(:final label, :final value) => Text.rich(
            TextSpan(children: [
              TextSpan(
                text: '$label: ',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              TextSpan(text: value),
            ]),
            style: const TextStyle(height: 1.35),
          ),
        PolicyParagraph(:final text) =>
          Text(text, style: const TextStyle(height: 1.4)),
        PolicyTable() => _columnWidths(block).any((w) => w > _proseColumnChars)
            ? _StackedTable(block, underHeading: heading)
            : _Grid(block),
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// One block per row, for tables whose last column is a paragraph.
class _StackedTable extends StatelessWidget {
  const _StackedTable(this.table, {required this.underHeading});

  final PolicyTable table;

  /// The heading this table sits under, so a row title that only repeats it can
  /// be left out. The per-use sections do exactly that: `## Hunting` followed by
  /// a one-row table whose first cell is `Hunting`.
  final String underHeading;

  @override
  Widget build(BuildContext context) {
    final rule = Theme.of(context).dividerColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, row) in table.rows.indexed) ...[
          if (index > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 0.5, color: rule),
            ),
          // The first cell titles the block. It is the subject of the row in
          // every table these scripts emit, so repeating its header above it
          // would only add a word.
          if (row.isNotEmpty &&
              row.first.isNotEmpty &&
              row.first != underHeading)
            Text(
              row.first,
              style: const TextStyle(fontWeight: FontWeight.w700, height: 1.35),
            ),
          for (var column = 1; column < table.headers.length; column++)
            if (column < row.length && row[column].isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: '${table.headers[column]}: ',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(text: row[column]),
                  ]),
                  style: const TextStyle(height: 1.4),
                ),
              ),
        ],
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid(this.table);

  final PolicyTable table;

  @override
  Widget build(BuildContext context) {
    final rule = Theme.of(context).dividerColor;
    final widest = _columnWidths(table);

    return Table(
      border: TableBorder.symmetric(inside: BorderSide(color: rule, width: 0.5)),
      columnWidths: {
        for (var column = 0; column < widest.length; column++)
          column: widest[column] <= _narrowColumnChars
              ? const IntrinsicColumnWidth()
              : const FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        _row(table.headers, bold: true),
        for (final row in table.rows)
          _row([
            // A ragged row is a defect in the file, not a reason to drop it.
            for (var column = 0; column < table.headers.length; column++)
              column < row.length ? row[column] : '',
          ]),
      ],
    );
  }

  TableRow _row(List<String> cells, {bool bold = false}) => TableRow(
        children: [
          for (final cell in cells)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
              child: Text(
                cell,
                style: TextStyle(
                  height: 1.35,
                  fontWeight: bold ? FontWeight.w700 : null,
                ),
              ),
            ),
        ],
      );
}
