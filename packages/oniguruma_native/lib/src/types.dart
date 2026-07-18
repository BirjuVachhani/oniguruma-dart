/// Platform-independent result types, shared by the FFI (IO) and web backends.
library;

/// A capture group's `[start, end)` range, in UTF-16 code units. Unmatched
/// groups report `start == end == -1`.
class OnigCapture {
  const OnigCapture(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start;
}

/// The result of `OnigScanner.findNextMatch`: which pattern matched and the
/// capture ranges (index 0 is the whole match).
///
/// Named `OnigScannerMatch` (not `OnigMatch`) to match the sibling
/// `oniguruma_dart` scanner and leave `OnigMatch` free for an idiomatic
/// String-API match type.
class OnigScannerMatch {
  const OnigScannerMatch(this.index, this.captureIndices);
  final int index;
  final List<OnigCapture> captureIndices;
}
