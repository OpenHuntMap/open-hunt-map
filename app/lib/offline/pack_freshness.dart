/// What the app can honestly say about the province pack on this device.
///
/// The screen used to label the action button `Update` whenever a pack was
/// installed, which reads as "newer data exists" when it only ever meant "a pack
/// is here". Users acted on it and downloaded the same bytes again. Nothing here
/// claims an update until something has actually been compared.
library;

import 'pack_index.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// How far the app got in comparing the installed pack with the published one.
enum PackCheck {
  /// No comparison attempted yet.
  notChecked,

  /// Tried and could not reach the index. Distinct from [notChecked] because the
  /// screen owes the user the difference between "haven't looked" and "looked
  /// and couldn't see".
  failed,

  /// The index was read. Whether it names this province is a separate question.
  checked,
}

/// A build stamp as a short date, in UTC.
///
/// UTC because that is what the stamp means, and converting to local time would
/// move the printed day for anyone west of Greenwich without telling them. The
/// day a pack was built is not precise enough for the hour to matter.
String formatPackDate(DateTime built) {
  final utc = built.toUtc();
  return '${utc.day} ${_months[utc.month - 1]} ${utc.year}';
}

/// The status line and button label for a province.
///
/// [installed] and [built] describe what is on disk; [check] and [published]
/// describe what was learned about what is available. `Update` appears only
/// where the two were actually compared and found to differ.
({String status, String action, bool isUpdate}) describeInstalledPack({
  required bool installed,
  required DateTime? built,
  String? contentId,
  PackCheck check = PackCheck.notChecked,
  PackIndexEntry? published,
}) {
  if (!installed) {
    return (status: 'Not downloaded', action: 'Download', isUpdate: false);
  }

  final installedDate = built == null ? null : formatPackDate(built);
  final have = built == null
      ? 'Downloaded, build date unknown'
      : 'Downloaded, built $installedDate';

  if (check == PackCheck.checked && published != null) {
    if (_isNewer(installedContentId: contentId, published: published)) {
      final when = published.built == null
          ? ''
          : ', published ${formatPackDate(published.built!)}';
      return (
        status: 'Update available$when',
        action: 'Update',
        isUpdate: true,
      );
    }
    // Same contents. Say so plainly, and keep the date, because "up to date" on
    // its own gives no way to notice if this screen is ever wrong.
    return (
      status: installedDate == null
          ? 'Up to date'
          : 'Up to date, built $installedDate',
      action: 'Re-download',
      isUpdate: false,
    );
  }

  if (check == PackCheck.failed) {
    return (
      status: '$have. Could not check for newer data.',
      action: 'Re-download',
      isUpdate: false,
    );
  }

  // Either nothing has been checked yet, or the index does not list this
  // province at all. Both mean the same thing to the user: what is here is
  // described, and nothing is claimed about what is not.
  return (status: have, action: 'Re-download', isUpdate: false);
}

bool _isNewer({
  required String? installedContentId,
  required PackIndexEntry published,
}) {
  final remote = published.contentId;
  if (remote == null) return false;
  if (installedContentId != null) return installedContentId != remote;
  // The installed pack carries no digest, and the published one does. Digests
  // were added at a point in time, so a pack without one was necessarily built
  // before any pack with one: the published pack really is newer. This is the
  // only place a conclusion is drawn from an absence, and it holds because the
  // absence itself is dated.
  return true;
}
