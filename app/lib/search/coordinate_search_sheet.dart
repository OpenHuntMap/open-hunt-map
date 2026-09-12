import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/gazetteer.dart';
import '../data/province_loader.dart';
import 'coordinate_parser.dart';

/// Everything the panel needs to search place names.
///
/// One object rather than three parameters because the three are useless
/// apart, and because that makes place-name search all-or-nothing: there is no
/// half-wired state where the panel offers a search it cannot run.
class PlaceSearchContext {
  const PlaceSearchContext({
    required this.provinceId,
    required this.loader,
    required this.centreLatitude,
    required this.centreLongitude,
  });

  final String provinceId;
  final ProvinceLoader loader;

  /// Where the map is currently looking. This never moves the camera; it breaks
  /// ties between the places sharing a name, which in this gazetteer is most of
  /// them — Ontario has 75 Mud Lakes and Quebec has 168 Lac Longs.
  final double centreLatitude;
  final double centreLongitude;
}

/// Opens the search box, returning the point to go to or null if dismissed.
///
/// Coordinate search needs nothing. Without [places] the panel is
/// coordinate-only and says so in the field's own label, which is the state a
/// caller that has not wired the gazetteer in yet will see.
Future<Coordinate?> showCoordinateSearch(
  BuildContext context, {
  PlaceSearchContext? places,
}) =>
    showModalBottomSheet<Coordinate>(
      context: context,
      showDragHandle: true,
      // The field pushes a keyboard up, and without this the sheet is capped
      // near half the screen and the Go button ends up behind it.
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          child: CoordinateSearchPanel(
            places: places,
            onAccept: (coordinate) => Navigator.pop(context, coordinate),
          ),
        ),
      ),
    );

/// One field for both a coordinate and a place name.
///
/// Which one it is does not need asking: coordinate notation is recognisable,
/// so anything that parses as a coordinate is treated as one and everything
/// else is looked up in the province's place-name index. That keeps the
/// coordinate behaviour exactly as it was — including the read-back, which is
/// the safety feature, since the mistake people actually make is pasting a
/// coordinate that lost its minus sign somewhere, and seeing "45.086428,
/// 75.786970" next to a note that it is in Uzbekistan is the only warning that
/// costs nothing.
///
/// Place-name search needs the province pack; coordinate search never does.
/// So every way the index can be absent is reported in the panel and leaves
/// the coordinate path untouched.
class CoordinateSearchPanel extends StatefulWidget {
  const CoordinateSearchPanel({
    super.key,
    required this.onAccept,
    this.places,
  });

  final ValueChanged<Coordinate> onAccept;

  /// Null leaves the panel coordinate-only.
  final PlaceSearchContext? places;

  @override
  State<CoordinateSearchPanel> createState() => _CoordinateSearchPanelState();
}

class _CoordinateSearchPanelState extends State<CoordinateSearchPanel> {
  final _controller = TextEditingController();
  CoordinateResult? _result;
  GazetteerResult? _gazetteer;
  PlaceResults _places = PlaceResults.empty;

  @override
  void initState() {
    super.initState();
    // Here rather than at app start: the index is a few megabytes and most
    // sessions never search. Coordinate search works while this is in flight.
    _loadGazetteer();
  }

  Future<void> _loadGazetteer() async {
    final places = widget.places;
    if (places == null) return;
    final loaded = await places.loader.loadGazetteer(places.provinceId);
    if (!mounted) return;
    setState(() {
      _gazetteer = loaded;
      _places = _lookUp(_controller.text);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _reparse(String text) {
    final parsed = parseCoordinate(text);
    setState(() {
      _result = parsed;
      _places = parsed is Coordinate ? PlaceResults.empty : _lookUp(text);
    });
  }

  PlaceResults _lookUp(String text) {
    final index = _gazetteer?.index;
    final places = widget.places;
    if (index == null || places == null || text.trim().isEmpty) {
      return PlaceResults.empty;
    }
    return index.search(
      text,
      latitude: places.centreLatitude,
      longitude: places.centreLongitude,
    );
  }

  Future<void> _paste() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text;
    if (text == null || text.trim().isEmpty) {
      if (!mounted) return;
      setState(() => _result = const CoordinateError('The clipboard is empty.'));
      return;
    }
    _controller.text = text.trim();
    _reparse(_controller.text);
  }

  /// The keyboard's Go key, which takes whichever answer the panel is showing.
  void _submit() {
    final result = _result;
    if (result is Coordinate) {
      widget.onAccept(result);
      return;
    }
    if (_places.isNotEmpty) _accept(_places.matches.first);
  }

  void _accept(PlaceMatch match) => widget.onAccept(
        Coordinate(
          latitude: match.latitude,
          longitude: match.longitude,
          format: 'place name',
          placeName: match.name,
        ),
      );

  bool get _hasQuery => _controller.text.trim().isNotEmpty;

  bool get _placeSearchReady => _gazetteer?.isReady ?? false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _result is Coordinate;
    final index = _gazetteer?.index;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: const Text('Search'),
            subtitle: Text(
              _placeSearchReady
                  ? 'A place name, a coordinate, or a map link.'
                  : 'A coordinate or a map link.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.go,
              // Not TextInputType.number: every notation here needs letters,
              // degree marks or a whole URL, and a place name needs the
              // alphabet, so the plain keyboard is the only one that can type
              // them.
              keyboardType: TextInputType.text,
              onChanged: _reparse,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                // The label is the panel's promise about what it can find, so
                // it names place search only where place search is loaded.
                labelText: _placeSearchReady
                    ? 'Place name, coordinate or map link'
                    : 'Coordinate or map link',
                hintText: '45.086428, -75.786970',
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste),
                  onPressed: _paste,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: _feedback(theme),
          ),
          if (_places.isNotEmpty)
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _places.matches.length,
                itemBuilder: (context, position) =>
                    _PlaceRow(match: _places.matches[position], onTap: _accept),
              ),
            ),
          if (index != null && index.attribution.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                index.attribution,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  // Disabled until a coordinate parsed, so the button itself
                  // says whether the input was understood. A place is taken by
                  // tapping the one you meant, since the panel cannot know
                  // which of 75 Mud Lakes that is.
                  onPressed: ready ? _submit : null,
                  icon: const Icon(Icons.my_location),
                  label: const Text('Go'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _feedback(ThemeData theme) => switch (_result) {
        Coordinate(
          :final latitude,
          :final longitude,
          :final format,
          :final note,
        ) =>
          _Line(
            icon: Icons.place_outlined,
            colour: theme.colorScheme.primary,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${latitude.toStringAsFixed(6)}, '
                  '${longitude.toStringAsFixed(6)}',
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  note == null ? 'Read as $format.' : 'Read as $format. $note',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        // A coordinate-shaped input that did not parse is a mistake worth
        // explaining. A name is not, and the place side of the panel answers
        // for it instead.
        CoordinateError(:final message, isName: false) =>
          _Line(
            icon: Icons.error_outline,
            colour: theme.colorScheme.error,
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        _ => _placeFeedback(theme),
      };

  Widget _placeFeedback(ThemeData theme) {
    final small = theme.textTheme.bodySmall;
    final quiet = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final gazetteer = _gazetteer;
    final index = gazetteer?.index;

    // An empty field gets the formats it accepts rather than an explanation of
    // something the user has not asked for yet. The field's own label has
    // already stopped promising place names where there are none.
    if (!_hasQuery) {
      return Text(
        index == null
            ? 'Decimal degrees, degrees and decimal minutes, '
                'degrees-minutes-seconds, a UTM grid reference, or a Google '
                'Maps link.'
            : '${_grouped(index.recordCount)} approved place names in '
                '${index.provinceName}, or paste a coordinate, a UTM grid '
                'reference or a Google Maps link.',
        style: quiet,
      );
    }

    final province = widget.places?.provinceId.toUpperCase() ?? '';
    if (widget.places == null) {
      return _Line(
        icon: Icons.info_outline,
        colour: theme.colorScheme.onSurfaceVariant,
        child: Text(
          'That is not a coordinate, and this panel was given no place-name '
          'index to look it up in.',
          style: quiet,
        ),
      );
    }
    if (gazetteer == null) {
      return Text('Looking for the place names in this pack…', style: quiet);
    }

    // Each of these leaves coordinate search working, and says so, because the
    // user is standing in front of a box that just stopped doing half of what
    // its label offered.
    final unavailable = switch (gazetteer.availability) {
      GazetteerAvailability.noPack =>
        'Place-name search needs the $province map pack. Install it from '
            'Offline packs. Coordinates and map links work without it.',
      GazetteerAvailability.notInPack =>
        'The installed $province pack carries no place names — it was built '
            'before this search existed. Download the pack again to get them. '
            'Coordinates and map links still work.',
      GazetteerAvailability.unreadable =>
        'The place-name index in the installed $province pack could not be '
            'read, so place names cannot be searched. Download the pack again. '
            'Coordinates and map links still work.',
      GazetteerAvailability.ready => null,
    };
    if (unavailable != null) {
      return _Line(
        icon: Icons.info_outline,
        colour: theme.colorScheme.onSurfaceVariant,
        child: Text(unavailable, style: quiet),
      );
    }

    if (foldForSearch(_controller.text).length < gazetteerMinimumQueryLength) {
      return Text(
        'Type at least $gazetteerMinimumQueryLength letters of a place name.',
        style: quiet,
      );
    }
    if (_places.isEmpty) {
      // The state where somebody who typed a road name is standing, so it is
      // the one place that has to say what this index is not.
      return _Line(
        icon: Icons.search_off,
        colour: theme.colorScheme.onSurfaceVariant,
        child: Text(
          'No approved name in ${index!.provinceName} matches that. This index '
          'holds lakes, rivers, bays, islands, points, hills, towns, parks, '
          'townships, wetlands and boat launches — not roads or trails. A '
          'place known only locally is not in it either.',
          style: quiet,
        ),
      );
    }
    // A list that stops at fifty without saying so reads as though fifty is
    // all there are, which for a name like Mud Lake is badly wrong.
    return Text(
      switch (_places) {
        PlaceResults(isCapped: true, :final total, :final matches) =>
          'Nearest ${matches.length} of ${_grouped(total)} matches. The '
              'feature type and county are what tell two of the same name '
              'apart.',
        PlaceResults(total: 1) => '1 match, with its feature type and county.',
        PlaceResults(:final total) =>
          '${_grouped(total)} matches, nearest first. The feature type and '
              'county are what tell two of the same name apart.',
      },
      style: quiet,
    );
  }
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({required this.match, required this.onTap});

  final PlaceMatch match;
  final ValueChanged<PlaceMatch> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(match.name),
      subtitle: Text('${match.featureType} · ${match.context}'),
      trailing: Text(
        _distanceLabel(match.distanceMetres),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => onTap(match),
    );
  }
}

/// Thousands separators, since the counts here run to six figures and the app
/// has no localisation package to ask.
String _grouped(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

/// Distance from the current view, rounded to what it can honestly claim.
///
/// A gazetteer point is one coordinate standing for a whole lake, so metres
/// past the first couple of figures would be precision the source never had.
String _distanceLabel(double metres) {
  if (metres < 1000) return '${metres.round()} m';
  if (metres < 10000) return '${(metres / 1000).toStringAsFixed(1)} km';
  return '${(metres / 1000).round()} km';
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.colour,
    required this.child,
  });

  final IconData icon;
  final Color colour;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colour),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      );
}
