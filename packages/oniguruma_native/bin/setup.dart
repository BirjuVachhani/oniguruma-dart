// Downloads the version-matched Oniguruma WebAssembly module into your app's
// `web/` directory, so the web backend serves it locally — streaming-compiled,
// browser-cached, and available offline / under a strict CSP — instead of
// falling back to fetching it from the GitHub Release at runtime.
//
//   dart run oniguruma_native:setup
//
// The download is verified against the SHA-256 manifest that ships with the
// package (prebuilt/checksums.sha256), so the file you get is exactly the blob
// this package version was built and released with.
//
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:oniguruma_native/src/release.dart';

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  if (opts.help) {
    _printUsage();
    return;
  }

  final version = opts.version ?? packageVersion;
  final url = opts.url ?? releaseWasmUrl(version);
  // Verify against the shipped manifest only for the default asset of this exact
  // version; a custom --url/--version may legitimately point at an unlisted blob.
  final usingDefaults = opts.url == null && opts.version == null;

  final outDir = Directory(opts.output);
  final target = File('${outDir.path}/$wasmAssetName');

  if (target.existsSync() && !opts.force) {
    print('✓ ${target.path} already exists — use --force to overwrite.');
    return;
  }

  stdout.write('Downloading $wasmAssetName ($version)\n  from $url ...\n');
  final bytes = await _downloadWithRetry(url);
  print('  downloaded ${bytes.length} bytes.');

  if (usingDefaults) {
    final expected = await _expectedChecksum();
    if (expected == null) {
      print('! checksum manifest not found — skipping verification.');
    } else {
      final actual = sha256.convert(bytes).toString();
      if (actual != expected) {
        stderr.writeln(
          'SHA-256 mismatch for $wasmAssetName:\n'
          '  expected $expected\n'
          '  actual   $actual\n'
          'Refusing to write a mismatched module.',
        );
        exit(1);
      }
      print('✓ SHA-256 verified.');
    }
  } else {
    print('! custom --url/--version — skipping checksum verification.');
  }

  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  target.writeAsBytesSync(bytes);
  print('✓ Wrote ${target.path}');
  print('');
  print('`await loadWasm()` will now serve this local copy on web.');
  print('Commit it, or add it to .gitignore and re-run this in CI.');
}

/// Reads the expected SHA-256 for `web/oniguruma_native.wasm` from the manifest
/// that ships in this package (`prebuilt/checksums.sha256`), or null if absent.
Future<String?> _expectedChecksum() async {
  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:oniguruma_native/oniguruma_native.dart'),
  );
  if (libUri == null) return null;
  final manifest = File.fromUri(libUri.resolve('../prebuilt/checksums.sha256'));
  if (!manifest.existsSync()) return null;
  for (final line in manifest.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.endsWith('web/$wasmAssetName')) {
      return trimmed.split(RegExp(r'\s+')).first;
    }
  }
  return null;
}

Future<List<int>> _downloadWithRetry(String url, {int attempts = 3}) async {
  Object? lastErr;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await _download(url);
    } catch (e) {
      lastErr = e;
      if (attempt < attempts) {
        stderr.writeln('  attempt $attempt failed ($e) — retrying...');
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
  }
  stderr.writeln('Download failed after $attempts attempts: $lastErr');
  exit(1);
}

Future<List<int>> _download(String url) async {
  final client = HttpClient(); // follows GitHub's redirect to the CDN by default
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}

class _Opts {
  String output = 'web';
  String? url;
  String? version;
  bool force = false;
  bool help = false;
}

_Opts _parseArgs(List<String> args) {
  final o = _Opts();
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) {
        stderr.writeln('Missing value for $a');
        exit(64);
      }
      return args[++i];
    }

    switch (a) {
      case '-h' || '--help':
        o.help = true;
      case '-f' || '--force':
        o.force = true;
      case '-o' || '--output':
        o.output = next();
      case '--url':
        o.url = next();
      case '--version':
        o.version = next();
      default:
        if (a.startsWith('--output=')) {
          o.output = a.substring('--output='.length);
        } else if (a.startsWith('--url=')) {
          o.url = a.substring('--url='.length);
        } else if (a.startsWith('--version=')) {
          o.version = a.substring('--version='.length);
        } else {
          stderr.writeln('Unknown argument: $a (try --help)');
          exit(64);
        }
    }
  }
  return o;
}

void _printUsage() {
  print('''
Downloads the Oniguruma WebAssembly module into your app's web/ directory.

Usage: dart run oniguruma_native:setup [options]

Options:
  -o, --output <dir>   Directory to write into (default: web)
      --url <url>      Download from this URL instead of the GitHub Release
      --version <ver>  Download the asset for this package version
  -f, --force          Overwrite an existing file
  -h, --help           Show this help

By default it fetches oniguruma_native.wasm for version $packageVersion from the
GitHub Release and verifies it against the package's SHA-256 manifest.''');
}
