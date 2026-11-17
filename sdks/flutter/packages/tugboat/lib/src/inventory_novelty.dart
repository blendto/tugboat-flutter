import 'anchors.dart';

/// Backstop: at most this many re-sampled inventories per route visit (route
/// epoch). Novelty bounds a visit on its own; this only stops a page whose
/// structure keeps changing for ever (a feed that keeps adding new kinds of
/// rows).
const int inventoryResampleCapPerVisit = 50;

final RegExp _itemToken = RegExp(r'^\[item:[^\]]+\]$');

/// The path a control is compared by for novelty: every list position
/// collapsed to `[item]` (the normalisation of the structural route
/// signature), except the page position of a `PageView`. Its pages are
/// different screens under one route (an onboarding flow), and two pages of
/// one widget class would otherwise share every path. The page positions are
/// the `[item:N]` segments after a `PageView`'s own `Scrollable`, up to the
/// next `Scrollable` (a list inside the page), whose rows collapse again.
String inventoryNoveltyPath(String canonicalPath) {
  final out = <String>[];
  var paging = _Paging.none;
  for (final segment in canonicalPath.split('/')) {
    paging = _nextPaging(paging, segment);
    final collapse = paging != _Paging.inPage && _itemToken.hasMatch(segment);
    out.add(collapse ? '[item]' : segment);
  }
  return out.join('/');
}

enum _Paging { none, pageView, inPage }

_Paging _nextPaging(_Paging paging, String segment) {
  if (segment.startsWith('PageView#')) return _Paging.pageView;
  if (!segment.startsWith('Scrollable#')) return paging;
  return paging == _Paging.pageView ? _Paging.inPage : _Paging.none;
}

/// What one route visit (route epoch) has sent: each entry's novelty path
/// with the states it was sent in (enabled, placeholder). Exploration only.
class InventoryVisit {
  InventoryVisit(this.routeEpoch);

  final int routeEpoch;
  final Map<String, Set<String>> _sent = <String, Set<String>>{};

  /// Re-sampled inventories emitted in this visit.
  int resamples = 0;

  /// `trigger` for the next re-sample: the moment that asked for it (`tap`,
  /// `gesture`, `scroll`), else `settled`.
  String pendingTrigger = 'settled';

  bool get capReached => resamples >= inventoryResampleCapPerVisit;

  /// Records [inventory] as sent: emitted now, or an exact repeat of one
  /// emitted earlier in the session (downstream already has it).
  void noteSent(TugboatSceneInventory inventory) {
    for (final entry in inventory.elements) {
      (_sent[inventoryNoveltyPath(entry.canonicalPath)] ??= <String>{}).add(
        _state(entry),
      );
    }
  }

  /// Whether [inventory] adds a control or content path not sent in this
  /// visit, or lists a sent path in a state it was not sent in: enabled or
  /// disabled, loaded or placeholder.
  bool isNovel(TugboatSceneInventory inventory) {
    for (final entry in inventory.elements) {
      final states = _sent[inventoryNoveltyPath(entry.canonicalPath)];
      if (states == null || !states.contains(_state(entry))) return true;
    }
    return false;
  }

  static String _state(TugboatSceneInventoryEntry entry) =>
      '${entry.enabled}|${entry.placeholder}';
}
