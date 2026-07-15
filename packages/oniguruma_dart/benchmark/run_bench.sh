#!/usr/bin/env bash
# Head-to-head benchmark: Dart port (AOT) vs. C libonig, same patterns + dataset.
#
#   benchmark/run_bench.sh
#
# Builds nothing (assumes benchmark/bench_dart and benchmark/c/onig_cli exist);
# run `dart compile exe benchmark/bench_dart.dart -o benchmark/bench_dart` and
# the C build first if needed.
set -euo pipefail
cd "$(dirname "$0")/.."

DATA=benchmark/datasets/corpus.txt
ITERS=${1:-50}
DART=benchmark/bench_dart
C=benchmark/c/onig_cli

hex() { printf '%s' "$1" | xxd -p | tr -d '\n'; }

# pattern list (label : regex)
patterns=(
  "literal:lorem"
  "alt3:lorem|ipsum|dolor"
  "class+:[a-z]+"
  "digits:[0-9]+"
  "word-bound:\\benim\\b"
  "email:\\w+@\\w+"
  "two-words:[a-z]+ [a-z]+"
)

printf '%-14s | %14s | %14s | %8s\n' "pattern" "C (ns/scan)" "Dart (ns/scan)" "Dart/C"
printf -- '---------------+----------------+----------------+---------\n'

extract_ns() { awk -F',' '{print $2}' | awk '{print $1}'; }

for entry in "${patterns[@]}"; do
  label="${entry%%:*}"
  pat="${entry#*:}"
  cout=$("$C" bench "$(hex "$pat")" "$DATA" "$ITERS")
  dout=$("$DART" "$pat" "$DATA" "$ITERS")
  cns=$(printf '%s' "$cout" | extract_ns)
  dns=$(printf '%s' "$dout" | extract_ns)
  ratio=$(awk -v d="$dns" -v c="$cns" 'BEGIN{ if (c>0) printf "%.2fx", d/c; else print "n/a" }')
  printf '%-14s | %14.0f | %14.0f | %8s\n' "$label" "$cns" "$dns" "$ratio"
done
