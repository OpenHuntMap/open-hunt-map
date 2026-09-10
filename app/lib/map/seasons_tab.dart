import 'package:flutter/material.dart';

import '../data/seasons.dart';

/// Seasons pane of the Land Info sheet: every species with a published season
/// in this WMU, split into what is open today, what is still coming, and what
/// has already closed for the regulation year.
class SeasonsTab extends StatefulWidget {
  const SeasonsTab({
    super.key,
    required this.wmuId,
    required this.pack,
    required this.seasons,
    required this.today,
  });

  final String? wmuId;
  final ProvinceSeasons? pack;
  final List<SeasonEntry> seasons;
  final DateTime today;

  @override
  State<SeasonsTab> createState() => _SeasonsTabState();
}

class _SeasonsTabState extends State<SeasonsTab> {
  String? _group;
  Residency? _residency;

  @override
  Widget build(BuildContext context) {
    final pack = widget.pack;
    if (widget.wmuId == null) {
      return const _Empty(
        icon: Icons.help_outline,
        title: 'No wildlife management unit here',
        body: 'Seasons are set per WMU. Tap a point inside a mapped WMU to see '
            'its seasons.',
      );
    }
    if (pack == null) {
      // A pack is installed (the sheet cannot open otherwise), so this means
      // the province pack does not carry a season table yet.
      return const _Empty(
        icon: Icons.event_note_outlined,
        title: 'No season tables in this pack',
        body: 'This province pack does not include hunting seasons yet. Check '
            'the provincial regulations summary directly.',
      );
    }
    if (widget.seasons.isEmpty) {
      return _Empty(
        icon: Icons.event_busy_outlined,
        title: 'No seasons listed for WMU ${widget.wmuId}',
        body: 'The ${pack.yearLabel} regulations summary publishes no open '
            'season table for this unit. Check the official summary before '
            'assuming it is closed.',
      );
    }

    final filtered = widget.seasons.where((season) {
      if (_group != null && season.group != _group) return false;
      if (_residency != null &&
          season.residency != _residency &&
          season.residency != Residency.any) {
        return false;
      }
      return true;
    }).toList();

    final buckets = {
      for (final status in SeasonStatus.values)
        status: filtered
            .where((season) => season.statusOn(widget.today) == status)
            .toList(),
    };

    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'WMU ${widget.wmuId} · ${pack.yearLabel} regulations',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  'As of ${_formatDate(widget.today, withYear: true)}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.black54),
                ),
                if (!pack.coversDate(widget.today)) ...[
                  const SizedBox(height: 8),
                  _Banner(
                    'This pack covers the ${pack.yearLabel} regulation year, '
                    'which does not include today. Update the province pack '
                    'before relying on these dates.',
                  ),
                ],
              ],
            ),
          ),
          _Filters(
            pack: pack,
            seasons: widget.seasons,
            group: _group,
            residency: _residency,
            onGroup: (value) => setState(() => _group = value),
            onResidency: (value) => setState(() => _residency = value),
          ),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: const Color(0xFF1B4332),
            indicatorColor: const Color(0xFF1B4332),
            tabs: [
              Tab(text: 'OPEN NOW (${buckets[SeasonStatus.open]!.length})'),
              Tab(text: 'UPCOMING (${buckets[SeasonStatus.upcoming]!.length})'),
              Tab(text: 'CLOSED (${buckets[SeasonStatus.closed]!.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _SeasonList(
                  seasons: buckets[SeasonStatus.open]!,
                  status: SeasonStatus.open,
                  today: widget.today,
                  pack: pack,
                  emptyText: 'Nothing is open in WMU ${widget.wmuId} today for '
                      'the current filter.',
                ),
                _SeasonList(
                  seasons: buckets[SeasonStatus.upcoming]!,
                  status: SeasonStatus.upcoming,
                  today: widget.today,
                  pack: pack,
                  emptyText: 'No further seasons open in WMU ${widget.wmuId} '
                      'before the ${pack.yearLabel} regulation year ends.',
                ),
                _SeasonList(
                  seasons: buckets[SeasonStatus.closed]!,
                  status: SeasonStatus.closed,
                  today: widget.today,
                  pack: pack,
                  emptyText: 'No seasons have closed yet this regulation year.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.pack,
    required this.seasons,
    required this.group,
    required this.residency,
    required this.onGroup,
    required this.onResidency,
  });

  final ProvinceSeasons pack;
  final List<SeasonEntry> seasons;
  final String? group;
  final Residency? residency;
  final ValueChanged<String?> onGroup;
  final ValueChanged<Residency?> onResidency;

  @override
  Widget build(BuildContext context) {
    // Only offer groups this WMU actually has, in a stable regulation order.
    const order = ['big_game', 'wild_turkey', 'small_game', 'furbearer'];
    final present = seasons.map((season) => season.group).toSet();
    final groups = order.where(present.contains).toList()
      ..addAll(present.where((id) => !order.contains(id)));

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        children: [
          _chip('All game', group == null, () => onGroup(null)),
          for (final id in groups)
            _chip(pack.groupLabel(id), group == id, () => onGroup(id)),
          const VerticalDivider(width: 20, indent: 8, endIndent: 8),
          _chip(
            'Resident',
            residency == Residency.resident,
            () => onResidency(
              residency == Residency.resident ? null : Residency.resident,
            ),
          ),
          _chip(
            'Non-resident',
            residency == Residency.nonResident,
            () => onResidency(
              residency == Residency.nonResident ? null : Residency.nonResident,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          selectedColor: const Color(0xFF1B4332).withValues(alpha: 0.16),
        ),
      );
}

class _SeasonList extends StatelessWidget {
  const _SeasonList({
    required this.seasons,
    required this.status,
    required this.today,
    required this.pack,
    required this.emptyText,
  });

  final List<SeasonEntry> seasons;
  final SeasonStatus status;
  final DateTime today;
  final ProvinceSeasons pack;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (seasons.isEmpty) {
      return _Empty(
        icon: Icons.event_available_outlined,
        title: 'Nothing here',
        body: emptyText,
      );
    }

    // One card per species so a hunter reads "deer" once, not nine times.
    final bySpecies = <String, List<SeasonEntry>>{};
    for (final season in seasons) {
      bySpecies.putIfAbsent(season.species, () => []).add(season);
    }
    final species = bySpecies.keys.toList()
      ..sort((a, b) {
        final left = bySpecies[a]!;
        final right = bySpecies[b]!;
        final byDate = switch (status) {
          SeasonStatus.upcoming =>
            left.first.start.compareTo(right.first.start),
          SeasonStatus.closed => right.first.end.compareTo(left.first.end),
          SeasonStatus.open => left.first.end.compareTo(right.first.end),
        };
        return byDate != 0
            ? byDate
            : left.first.speciesName.compareTo(right.first.speciesName);
      });

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        for (final id in species)
          _SpeciesCard(
            seasons: bySpecies[id]!,
            status: status,
            today: today,
          ),
        const SizedBox(height: 8),
        Text(
          pack.disclaimer,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Colors.black54, height: 1.35),
        ),
        const SizedBox(height: 6),
        Text(
          'Source: ${pack.sourceTitle}${pack.generated.isEmpty ? '' : ' · '
              'read ${pack.generated}'}\n${pack.regsUrl}',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Colors.black45, height: 1.35),
        ),
      ],
    );
  }
}

class _SpeciesCard extends StatelessWidget {
  const _SpeciesCard({
    required this.seasons,
    required this.status,
    required this.today,
  });

  final List<SeasonEntry> seasons;
  final SeasonStatus status;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final sorted = [...seasons]..sort((a, b) => a.start.compareTo(b.start));
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFE3DCC8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    sorted.first.speciesName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _StatusPill(status: status, season: sorted.first, today: today),
              ],
            ),
            const SizedBox(height: 8),
            for (final season in sorted) _SeasonRow(season: season, today: today),
          ],
        ),
      ),
    );
  }
}

class _SeasonRow extends StatelessWidget {
  const _SeasonRow({required this.season, required this.today});

  final SeasonEntry season;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Colors.black54, height: 1.3);
    final detail = [
      if (season.residency != Residency.any) season.residency.label,
      if (season.huntCode != null) 'Hunt code ${season.huntCode}',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            season.allYear
                ? 'Open all year'
                : '${_formatDate(season.start)} – ${_formatDate(season.end)}',
            style: const TextStyle(fontWeight: FontWeight.w600, height: 1.3),
          ),
          if (season.label != null && season.label!.isNotEmpty)
            Text(season.label!, style: const TextStyle(height: 1.3)),
          if (detail.isNotEmpty) Text(detail, style: small),
          if (season.limits != null) Text(season.limits!, style: small),
          if (season.notes != null) Text(season.notes!, style: small),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.status,
    required this.season,
    required this.today,
  });

  final SeasonStatus status;
  final SeasonEntry season;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      SeasonStatus.open => (
          season.allYear
              ? 'Open'
              : _remaining('Closes', season.daysUntilClose(today)),
          const Color(0xFF1B5E20),
        ),
      SeasonStatus.upcoming => (
          _remaining('Opens', season.daysUntilOpen(today)),
          const Color(0xFF8D6E00),
        ),
      SeasonStatus.closed => ('Closed', const Color(0xFF7A7A7A)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }

  String _remaining(String verb, int days) {
    if (days <= 0) return verb == 'Opens' ? 'Opens today' : 'Closes today';
    if (days == 1) return '$verb tomorrow';
    return '$verb in $days days';
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);
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
            Expanded(child: Text(text, style: const TextStyle(height: 1.3))),
          ],
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: Colors.black38),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54, height: 1.35),
              ),
            ],
          ),
        ),
      );
}

const _months = [
  '',
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _formatDate(DateTime value, {bool withYear = false}) {
  final base = '${_months[value.month]} ${value.day}';
  return withYear ? '$base, ${value.year}' : base;
}
