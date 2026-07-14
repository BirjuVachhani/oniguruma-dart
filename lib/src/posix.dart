/// POSIX regex API adapter (`regposix.c` / `onigposix.h`), mapped to Dart.
///
/// Mirrors `regcomp`/`regexec`/`regfree`/`regerror` and the `REG_*` flags over
/// the core engine. Idiomatic Dart callers should prefer `OnigRegex`; this
/// exists for 1:1 API parity with the C library.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'encoding/utf8.dart';
import 'exec/search.dart';
import 'onig_errors.dart';
import 'onig_types.dart';
import 'region.dart';
import 'regex.dart';
import 'syntax.dart';

/// POSIX cflags.
abstract final class Reg {
  static const int icase = 1 << 0;
  static const int newline = 1 << 1;
  static const int notbol = 1 << 2;
  static const int noteol = 1 << 3;
  static const int extended = 1 << 4; // else POSIX Basic
  static const int nosub = 1 << 5;

  // return codes
  static const int noMatch = 1;
  static const int badPat = 2;
}

/// A POSIX match register (`regmatch_t`): [rmSo], [rmEo] byte offsets (-1 unset).
class PosixMatch {
  int rmSo;
  int rmEo;
  PosixMatch([this.rmSo = -1, this.rmEo = -1]);
}

/// A compiled POSIX pattern (`regex_t`).
class PosixRegex {
  Regex? _reg;
  int reNsub = 0; // number of subexpressions
  final int _cflags;
  PosixRegex._(this._reg, this.reNsub, this._cflags);
}

/// `regcomp` — compile [pattern] with [cflags]. Returns 0 on success or a
/// `REG_*` error code, filling [out].
int posixRegcomp(PosixRegexHolder out, String pattern, int cflags) {
  // `onig_posix_regcomp`: REG_EXTENDED uses the default (Oniguruma) syntax;
  // without it, POSIX Basic.
  final syntax = (cflags & Reg.extended) != 0
      ? onigSyntaxOniguruma
      : onigSyntaxPosixBasic;
  var options = OnigOption.none;
  if ((cflags & Reg.icase) != 0) options |= OnigOption.ignoreCase;
  if ((cflags & Reg.newline) != 0) {
    options |= OnigOption.negateSingleLine; // ^/$ match at newlines
  }
  final pb = Uint8List.fromList(utf8.encode(pattern));
  try {
    final reg = onigNew(pb, pb.length, utf8Encoding, syntax, options);
    out.regex = PosixRegex._(reg, reg.numMem, cflags);
    return 0;
  } on OnigException {
    out.regex = PosixRegex._(null, 0, cflags);
    return Reg.badPat;
  }
}

/// `regexec` — match [str] against [preg]. Fills up to [nmatch] entries of
/// [matches] with byte offsets. Returns 0 on match or [Reg.noMatch].
int posixRegexec(
  PosixRegex preg,
  String str,
  int nmatch,
  List<PosixMatch> matches,
  int eflags,
) {
  final reg = preg._reg;
  if (reg == null) return Reg.badPat;
  final sb = Uint8List.fromList(utf8.encode(str));
  var opt = OnigOption.none;
  if ((eflags & Reg.notbol) != 0) opt |= OnigOption.notBol;
  if ((eflags & Reg.noteol) != 0) opt |= OnigOption.notEol;
  final region = OnigRegion();
  final r = onigSearch(reg, sb, sb.length, 0, sb.length, region, option: opt);
  if (r < 0) return Reg.noMatch;
  final noSub = (preg._cflags & Reg.nosub) != 0;
  if (!noSub) {
    for (var i = 0; i < nmatch && i < matches.length; i++) {
      if (i < region.numRegs) {
        matches[i]
          ..rmSo = region.beg[i]
          ..rmEo = region.end[i];
      } else {
        matches[i]
          ..rmSo = -1
          ..rmEo = -1;
      }
    }
  }
  return 0;
}

/// `regfree` — release compiled resources.
void posixRegfree(PosixRegex preg) => preg._reg = null;

/// `regerror` — human-readable message for a POSIX error code.
String posixRegerror(int code) {
  switch (code) {
    case Reg.noMatch:
      return onigErrorCodeToStr(OnigResult.mismatch);
    case Reg.badPat:
      return 'invalid regular expression';
    default:
      return 'regex error $code';
  }
}

/// Out-parameter holder for [posixRegcomp] (C passes `regex_t*`).
class PosixRegexHolder {
  PosixRegex? regex;
}
