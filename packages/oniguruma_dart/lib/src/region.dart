/// Capture-group result storage (`OnigRegion` / `re_registers`, oniguruma.h).
library;

/// Holds the byte offsets of the whole match (index 0) and each capture group.
///
/// `beg[i]`/`end[i]` are **byte offsets** into the subject; an unset group has
/// both set to [regionNotFound] (`ONIG_REGION_NOTPOS` = -1).
class OnigRegion {
  static const int notFound = -1;

  /// Number of active registers (group count + 1 for the whole match).
  int numRegs = 0;

  /// Start byte offsets, index 0 = whole match. Length is [allocated].
  List<int> beg;

  /// End byte offsets, index 0 = whole match.
  List<int> end;

  OnigRegion([int capacity = 10])
    : beg = List<int>.filled(capacity < 1 ? 1 : capacity, notFound),
      end = List<int>.filled(capacity < 1 ? 1 : capacity, notFound);

  /// Allocated capacity of [beg]/[end].
  int get allocated => beg.length;

  /// Reset all registers to "not found" (`onig_region_clear`).
  void clear() {
    for (var i = 0; i < numRegs; i++) {
      beg[i] = notFound;
      end[i] = notFound;
    }
  }

  /// Grow to hold at least [n] registers (`onig_region_resize`).
  void resize(int n) {
    if (n > beg.length) {
      var cap = beg.isEmpty ? 1 : beg.length;
      while (cap < n) {
        cap <<= 1;
      }
      final nb = List<int>.filled(cap, notFound);
      final ne = List<int>.filled(cap, notFound);
      for (var i = 0; i < numRegs; i++) {
        nb[i] = beg[i];
        ne[i] = end[i];
      }
      beg = nb;
      end = ne;
    }
    numRegs = n;
  }

  /// Length of group [i] in bytes, or -1 if unset.
  int length(int i) =>
      (i < numRegs && beg[i] != notFound) ? end[i] - beg[i] : -1;

  @override
  String toString() {
    final sb = StringBuffer('OnigRegion(');
    for (var i = 0; i < numRegs; i++) {
      if (i > 0) sb.write(', ');
      sb.write('$i:(${beg[i]}-${end[i]})');
    }
    sb.write(')');
    return sb.toString();
  }
}
