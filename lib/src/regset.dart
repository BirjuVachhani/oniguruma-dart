/// Multi-pattern search set (`OnigRegSet`, regext.c): search several compiled
/// patterns over one subject and report which matched where.
library;

import 'dart:typed_data';

import 'exec/search.dart';
import 'onig_types.dart';
import 'region.dart';
import 'regex.dart';

/// Lead mode for [OnigRegSet.search] (`onig_regset_search` lead).
enum RegSetLead {
  /// Return the overall left-most match; ties broken by add order.
  positionLead,

  /// Return the first pattern (in add order) that matches, at its match pos.
  regexLead,
}

/// A set of compiled [Regex]es searched together (`OnigRegSet`).
class OnigRegSet {
  final List<Regex> _regexes = [];

  /// The region of the most recent successful [search], per matched pattern.
  OnigRegion? region;

  /// Add a compiled pattern; returns its index.
  int add(Regex reg) {
    _regexes.add(reg);
    return _regexes.length - 1;
  }

  int get length => _regexes.length;
  Regex operator [](int i) => _regexes[i];

  /// Search all patterns in `[start, range]`. Returns the index of the matching
  /// pattern (and sets [region] + the match position via [matchPos]), or -1 for
  /// no match.
  int search(
    Uint8List str,
    int end,
    int start,
    int range, {
    RegSetLead lead = RegSetLead.positionLead,
  }) {
    var bestIdx = -1;
    var bestPos = -1;
    OnigRegion? bestRegion;
    for (var i = 0; i < _regexes.length; i++) {
      final rg = OnigRegion();
      final r = onigSearch(_regexes[i], str, end, start, range, rg);
      if (r >= 0) {
        if (lead == RegSetLead.regexLead) {
          region = rg;
          matchPos = r;
          return i;
        }
        if (bestIdx < 0 || r < bestPos) {
          bestIdx = i;
          bestPos = r;
          bestRegion = rg;
        }
      } else if (r < OnigResult.mismatch) {
        return r; // hard error
      }
    }
    region = bestRegion;
    matchPos = bestPos;
    return bestIdx;
  }

  /// Match start byte offset of the most recent successful [search].
  int matchPos = -1;
}
