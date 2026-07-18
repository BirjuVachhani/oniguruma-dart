/// Backend-independent Layer-0 types, shared by the FFI (IO) and web backends.
///
/// These mirror the sibling `oniguruma_dart` package's names/shapes so low-level
/// code written against one package moves to the other unchanged.
library;

/// Capture-group result storage (`OnigRegion` / `re_registers`, oniguruma.h),
/// holding **byte offsets** of the whole match (index 0) and each group.
///
/// This is a plain Dart value object on every platform; the FFI backend copies
/// the native region's registers into it after each search.
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

  /// Copy every register from [from] into this region (`onig_region_copy`,
  /// with `this` as the destination). Grows this region if needed.
  void copyFrom(OnigRegion from) {
    resize(from.numRegs);
    for (var i = 0; i < from.numRegs; i++) {
      beg[i] = from.beg[i];
      end[i] = from.end[i];
    }
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

/// Thrown when a pattern fails to compile (`onig_new` returns an error code).
class OnigException implements Exception {
  const OnigException(this.code, this.message);

  /// The Oniguruma error code (`ONIGERR_*`, negative).
  final int code;

  /// A human-readable message from `onig_error_code_to_str`.
  final String message;

  @override
  String toString() => 'OnigException($code): $message';
}

/// Lead mode for [OnigRegSet.search] (`onig_regset_search` lead argument).
enum RegSetLead {
  /// Return the overall left-most match; ties broken by add order
  /// (`ONIG_REGSET_POSITION_LEAD` = 0).
  positionLead,

  /// Return the first pattern (in add order) that matches
  /// (`ONIG_REGSET_REGEX_LEAD` = 1).
  regexLead,
}
