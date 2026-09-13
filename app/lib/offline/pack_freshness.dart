/// What the app can honestly say about the province pack on this device.
///
/// The screen used to label the action button `Update` whenever a pack was
/// installed, which reads as "newer data exists" when it only ever meant "a pack
/// is here". Users acted on it and downloaded the same bytes again. Nothing here
/// claims an update until something has actually been compared.
library;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// A build stamp as a short date, in UTC.
///
/// UTC because that is what the stamp means, and converting to local time would
/// move the printed day for anyone west of Greenwich without telling them. The
/// day a pack was built is not precise enough for the hour to matter.
String formatPackDate(DateTime built) {
  final utc = built.toUtc();
  return '${utc.day} ${_months[utc.month - 1]} ${utc.year}';
}

/// The status line and button label for a province, given only what is on disk.
///
/// Deliberately says nothing about whether newer data exists, because with no
/// network check nothing here knows. `Re-download` describes what the button
/// does; `Update` would describe something this has not established.
({String status, String action}) describeInstalledPack({
  required bool installed,
  required DateTime? built,
}) {
  if (!installed) {
    return (status: 'Not downloaded', action: 'Download');
  }
  if (built == null) {
    // A pack from before build_pack.py stamped one. Saying so is better than
    // omitting the line, because "Downloaded" alone is what left people unable
    // to tell a fresh pack from a stale one. Resolves after one re-download.
    return (status: 'Downloaded, build date unknown', action: 'Re-download');
  }
  return (
    status: 'Downloaded, built ${formatPackDate(built)}',
    action: 'Re-download',
  );
}
