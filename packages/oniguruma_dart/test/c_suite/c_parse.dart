// Faithful parser for the original Oniguruma C test files. It reads the C
// sources at runtime, extracts the `x2/x3/n/e`-style macro invocations, and
// decodes the C string literals into exact byte sequences, so each Dart case is
// logically identical to the C one (same pattern bytes, subject, expectations).
import 'dart:typed_data';

/// One extracted macro invocation. [args] holds the raw top-level argument
/// slices (trimmed); strings are still quoted, ints/consts are literal text.
class CCall {
  final String name;
  final List<String> args;
  final int line;
  CCall(this.name, this.args, this.line);
}

/// Decode a C argument that is a (possibly concatenated) string literal into
/// bytes. Handles `\n \t \r \f \v \a \b \0 \\ \" \' \e`, `\xHH`, and octal
/// `\o \oo \ooo`. Adjacent `"..."` literals are concatenated.
Uint8List decodeCString(String arg) {
  final out = <int>[];
  final s = arg;
  var i = 0;
  final n = s.length;
  while (i < n) {
    // skip whitespace between concatenated literals
    if (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
      i++;
      continue;
    }
    if (s[i] != '"') {
      // not a string literal (shouldn't happen for string args)
      i++;
      continue;
    }
    i++; // opening quote
    while (i < n && s[i] != '"') {
      if (s[i] == '\\') {
        i++;
        if (i >= n) break;
        final c = s[i];
        switch (c) {
          case 'n':
            out.add(0x0a);
            i++;
          case 't':
            out.add(0x09);
            i++;
          case 'r':
            out.add(0x0d);
            i++;
          case 'f':
            out.add(0x0c);
            i++;
          case 'v':
            out.add(0x0b);
            i++;
          case 'a':
            out.add(0x07);
            i++;
          case 'b':
            out.add(0x08);
            i++;
          case 'e':
            out.add(0x1b);
            i++;
          case '\\':
            out.add(0x5c);
            i++;
          case '"':
            out.add(0x22);
            i++;
          case '\'':
            out.add(0x27);
            i++;
          case '?':
            out.add(0x3f);
            i++;
          case 'x':
            {
              i++;
              var hex = '';
              while (i < n && hex.length < 2 && _isHex(s[i])) {
                hex += s[i];
                i++;
              }
              out.add(int.parse(hex, radix: 16));
            }
          case 'u': // C universal character name \uHHHH → UTF-8 bytes
            {
              i++;
              var hex = '';
              while (i < n && hex.length < 4 && _isHex(s[i])) {
                hex += s[i];
                i++;
              }
              _addUtf8(out, int.parse(hex, radix: 16));
            }
          case 'U': // \UHHHHHHHH → UTF-8 bytes
            {
              i++;
              var hex = '';
              while (i < n && hex.length < 8 && _isHex(s[i])) {
                hex += s[i];
                i++;
              }
              _addUtf8(out, int.parse(hex, radix: 16));
            }
          default:
            if (c.compareTo('0') >= 0 && c.compareTo('7') <= 0) {
              var oct = '';
              while (i < n &&
                  oct.length < 3 &&
                  s[i].compareTo('0') >= 0 &&
                  s[i].compareTo('7') <= 0) {
                oct += s[i];
                i++;
              }
              out.add(int.parse(oct, radix: 8) & 0xff);
            } else {
              out.add(c.codeUnitAt(0));
              i++;
            }
        }
      } else {
        // Regular char. The C sources are read as latin1 (raw bytes → code
        // units), and non-ASCII appears via `\xHH` escapes, so every code unit
        // here is a single byte.
        out.add(s.codeUnitAt(i) & 0xff);
        i++;
      }
    }
    i++; // closing quote
  }
  return Uint8List.fromList(out);
}

bool _isHex(String c) =>
    (c.compareTo('0') >= 0 && c.compareTo('9') <= 0) ||
    (c.toLowerCase().compareTo('a') >= 0 &&
        c.toLowerCase().compareTo('f') <= 0);

/// UTF-8-encode a Unicode code point into [out] (C `\u`/`\U` universal names).
void _addUtf8(List<int> out, int code) {
  if (code < 0x80) {
    out.add(code);
  } else if (code < 0x800) {
    out.add(0xc0 | (code >> 6));
    out.add(0x80 | (code & 0x3f));
  } else if (code < 0x10000) {
    out.add(0xe0 | (code >> 12));
    out.add(0x80 | ((code >> 6) & 0x3f));
    out.add(0x80 | (code & 0x3f));
  } else {
    out.add(0xf0 | (code >> 18));
    out.add(0x80 | ((code >> 12) & 0x3f));
    out.add(0x80 | ((code >> 6) & 0x3f));
    out.add(0x80 | (code & 0x3f));
  }
}

/// Extract all invocations of the given macro [names] from C [source].
/// Handles line comments, block comments, string/char literals, and nested
/// parentheses inside arguments. `line` is the 1-based line of the call start.
List<CCall> extractCalls(String source, Set<String> names) {
  final calls = <CCall>[];
  final n = source.length;
  var i = 0;
  var line = 1;
  var atLineStart = true; // first non-blank column of the current line
  while (i < n) {
    final ch = source[i];
    if (ch == '\n') {
      line++;
      i++;
      atLineStart = true;
      continue;
    }
    // Skip preprocessor directives (e.g. the `#define x2(...)` macro defs) so
    // they are never mistaken for invocations.
    if (atLineStart && ch == '#') {
      while (i < n && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch != ' ' && ch != '\t') atLineStart = false;
    // comments
    if (ch == '/' && i + 1 < n && source[i + 1] == '/') {
      while (i < n && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '/' && i + 1 < n && source[i + 1] == '*') {
      i += 2;
      while (i + 1 < n && !(source[i] == '*' && source[i + 1] == '/')) {
        if (source[i] == '\n') line++;
        i++;
      }
      i += 2;
      continue;
    }
    // string / char literal at top level: skip
    if (ch == '"' || ch == '\'') {
      i = _skipLiteral(source, i);
      continue;
    }
    // identifier?
    if (_isIdentStart(ch)) {
      final start = i;
      while (i < n && _isIdentChar(source[i])) {
        i++;
      }
      final ident = source.substring(start, i);
      // must be a standalone call: preceded by non-ident (guaranteed) and
      // followed (after ws) by '('
      var j = i;
      while (j < n && (source[j] == ' ' || source[j] == '\t')) {
        j++;
      }
      if (names.contains(ident) && j < n && source[j] == '(') {
        final callLine = line;
        final parsed = _parseArgs(source, j);
        // advance line counter across the consumed span
        for (var k = i; k < parsed.end; k++) {
          if (source[k] == '\n') line++;
        }
        calls.add(CCall(ident, parsed.args, callLine));
        i = parsed.end;
      }
      continue;
    }
    i++;
  }
  return calls;
}

bool _isIdentStart(String c) =>
    c == '_' ||
    (c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
    (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0);
bool _isIdentChar(String c) =>
    _isIdentStart(c) || (c.compareTo('0') >= 0 && c.compareTo('9') <= 0);

int _skipLiteral(String s, int i) {
  final q = s[i];
  i++;
  while (i < s.length) {
    if (s[i] == '\\') {
      i += 2;
      continue;
    }
    if (s[i] == q) return i + 1;
    i++;
  }
  return i;
}

class _Args {
  final List<String> args;
  final int end;
  _Args(this.args, this.end);
}

/// Parse a parenthesized argument list starting at `s[open] == '('`.
_Args _parseArgs(String s, int open) {
  final args = <String>[];
  var depth = 0;
  var i = open;
  var argStart = open + 1;
  while (i < s.length) {
    final c = s[i];
    if (c == '"' || c == '\'') {
      i = _skipLiteral(s, i);
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      i += 2;
      while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    if (c == '(') {
      depth++;
      i++;
      continue;
    }
    if (c == ')') {
      depth--;
      if (depth == 0) {
        args.add(s.substring(argStart, i).trim());
        return _Args(args, i + 1);
      }
      i++;
      continue;
    }
    if (c == ',' && depth == 1) {
      args.add(s.substring(argStart, i).trim());
      argStart = i + 1;
      i++;
      continue;
    }
    i++;
  }
  return _Args(args, i);
}
