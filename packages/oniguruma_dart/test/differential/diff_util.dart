/// Shared helper for differential testing the Dart port against the C library
/// via the `benchmark/c/onig_cli` reference harness.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:oniguruma_dart/oniguruma_dart.dart';

/// Result of a single search, in a form comparable across C and Dart.
class SearchOutcome {
  final String kind; // 'MATCH' | 'NOMATCH' | 'ERROR'
  final int start; // match start (MATCH only)
  final List<int> regs; // flat [b0,e0,b1,e1,...] (MATCH only)
  final int errorCode;
  SearchOutcome(
    this.kind, {
    this.start = -1,
    this.regs = const [],
    this.errorCode = 0,
  });

  @override
  String toString() {
    if (kind == 'MATCH') return 'MATCH $start ${regs.join(",")}';
    if (kind == 'ERROR') return 'ERROR $errorCode';
    return 'NOMATCH';
  }

  @override
  bool operator ==(Object other) =>
      other is SearchOutcome &&
      other.kind == kind &&
      other.start == start &&
      _listEq(other.regs, regs);

  @override
  int get hashCode => Object.hash(kind, start, Object.hashAll(regs));
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Run the Dart engine on ([patternBytes], [subjectBytes]). [retryLimit] caps
/// backtracking (0 = unlimited) so the fuzzer doesn't hang on pathological
/// patterns; on overflow the engine returns an error code (skipped by callers).
SearchOutcome runDart(
  Uint8List patternBytes,
  Uint8List subjectBytes, {
  int retryLimit = 0,
}) {
  try {
    final reg = onigNew(
      patternBytes,
      patternBytes.length,
      utf8Encoding,
      onigSyntaxDefault,
      OnigOption.defaultOption,
    );
    final region = OnigRegion();
    final r = onigSearch(
      reg,
      subjectBytes,
      subjectBytes.length,
      0,
      subjectBytes.length,
      region,
      retryLimit: retryLimit,
    );
    if (r >= 0) {
      final regs = <int>[];
      for (var i = 0; i < region.numRegs; i++) {
        regs.add(region.beg[i]);
        regs.add(region.end[i]);
      }
      return SearchOutcome('MATCH', start: r, regs: regs);
    }
    if (r == OnigResult.mismatch) return SearchOutcome('NOMATCH');
    return SearchOutcome('ERROR', errorCode: r);
  } on OnigException catch (e) {
    return SearchOutcome('ERROR', errorCode: e.code);
  } catch (_) {
    // UnimplementedError / RangeError / StateError from beyond-slice constructs.
    return SearchOutcome('ERROR', errorCode: -12345);
  }
}

/// A persistent connection to the C reference CLI (framed stdin protocol).
class COracle {
  final Process _proc;
  final StreamIterator<String> _out;

  COracle._(this._proc, this._out);

  static Future<COracle> start(String cliPath) async {
    final p = await Process.start(cliPath, const []);
    final out = StreamIterator(
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    return COracle._(p, out);
  }

  Future<SearchOutcome> run(
    Uint8List patternBytes,
    Uint8List subjectBytes,
  ) async {
    final frame = BytesBuilder();
    frame.add(_u32(patternBytes.length));
    frame.add(patternBytes);
    frame.add(_u32(subjectBytes.length));
    frame.add(subjectBytes);
    _proc.stdin.add(frame.toBytes());
    await _proc.stdin.flush();
    if (!await _out.moveNext()) {
      return SearchOutcome('ERROR', errorCode: -9999);
    }
    return _parse(_out.current);
  }

  SearchOutcome _parse(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts[0] == 'MATCH') {
      final start = int.parse(parts[1]);
      final n = int.parse(parts[2]);
      final regs = <int>[];
      for (var i = 0; i < n * 2; i++) {
        regs.add(int.parse(parts[3 + i]));
      }
      return SearchOutcome('MATCH', start: start, regs: regs);
    }
    if (parts[0] == 'ERROR') {
      return SearchOutcome('ERROR', errorCode: int.parse(parts[1]));
    }
    return SearchOutcome('NOMATCH');
  }

  static Uint8List _u32(int v) => Uint8List.fromList([
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ]);

  Future<void> close() async {
    await _proc.stdin.close();
    _proc.kill();
  }
}

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
