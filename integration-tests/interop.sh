#!/usr/bin/env bash
# Cross-implementation test: the Kotlin core (used by the Android app) and the
# Swift core (used by the Mac app) exchange files over real TCP on localhost,
# in both directions, with fresh identities (so every run pairs).
#
# Usage: integration-tests/interop.sh <kotlin-cli> <swift-cli>
# Checks: both sides show the same pairing code, every file arrives with the
# sender's SHA-256, duplicate names are not overwritten, and nothing partial is left.
set -euo pipefail

KOTLIN_CLI="$1"
SWIFT_CLI="$2"
WORK="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/in"
: > "$WORK/in/empty.txt"
printf 'x' > "$WORK/in/one-byte.bin"
head -c 5242881 /dev/urandom > "$WORK/in/random 5MB.bin"
printf 'Grüße aus CrossDrop 🎉\n' > "$WORK/in/ünïcødé – файл.txt"
head -c 300000 /dev/urandom > "$WORK/in/big.bin"
mkdir -p "$WORK/in/dup"
printf 'second copy' > "$WORK/in/dup/big.bin"

expected_hashes() {
  for f in "$WORK/in/empty.txt" "$WORK/in/one-byte.bin" "$WORK/in/random 5MB.bin" "$WORK/in/ünïcødé – файл.txt" "$WORK/in/big.bin" "$WORK/in/dup/big.bin"; do
    shasum -a 256 "$f" | awk '{print $1}'
  done | sort
}

run_case() {
  local name="$1" receiver="$2" sender="$3" port="$4"
  local out="$WORK/out-$name"
  mkdir -p "$out"
  echo "=== $name: $(basename "$sender") -> $(basename "$receiver") ==="
  "$receiver" receive --port "$port" --dir "$out" --identity "$WORK/$name-recv.key" --name "Receiver" --once > "$WORK/$name-recv.log" 2>&1 &
  local rpid=$!
  for _ in $(seq 1 100); do grep -q LISTENING "$WORK/$name-recv.log" 2>/dev/null && break; sleep 0.2; done
  grep -q LISTENING "$WORK/$name-recv.log" || { cat "$WORK/$name-recv.log"; echo "receiver did not start"; exit 1; }

  local start end
  start=$(date +%s)
  if ! "$sender" send --host 127.0.0.1 --port "$port" --identity "$WORK/$name-send.key" --name "Sender" \
      "$WORK/in/empty.txt" "$WORK/in/one-byte.bin" "$WORK/in/random 5MB.bin" "$WORK/in/ünïcødé – файл.txt" "$WORK/in/big.bin" "$WORK/in/dup/big.bin" \
      > "$WORK/$name-send.log" 2>&1; then
    echo "--- sender log"; cat "$WORK/$name-send.log"; echo "--- receiver log"; cat "$WORK/$name-recv.log"
    exit 1
  fi
  end=$(date +%s)
  wait "$rpid" || { echo "receiver failed"; cat "$WORK/$name-recv.log"; exit 1; }

  local sas_send sas_recv
  sas_send=$(grep '^SAS ' "$WORK/$name-send.log" | awk '{print $2}')
  sas_recv=$(grep '^SAS ' "$WORK/$name-recv.log" | awk '{print $2}')
  [[ -n "$sas_send" && "$sas_send" == "$sas_recv" ]] || { echo "pairing codes differ: '$sas_send' vs '$sas_recv'"; exit 1; }

  diff <(expected_hashes) <(grep '^RECEIVED ' "$WORK/$name-recv.log" | awk '{print $NF}' | sort) \
    || { echo "hash mismatch"; cat "$WORK/$name-recv.log"; exit 1; }
  diff <(expected_hashes) <(for f in "$out"/*; do shasum -a 256 "$f" | awk '{print $1}'; done | sort) \
    || { echo "files on disk differ"; ls -la "$out"; exit 1; }
  [[ -f "$out/big.bin" && -f "$out/big (1).bin" ]] || { echo "duplicate name not handled"; ls -la "$out"; exit 1; }
  if ls -a "$out" | grep -q '\.partial$'; then echo "partial file left behind"; exit 1; fi
  echo "ok: SAS $sas_send matched, 6 files verified ($((end - start))s)"
}

run_case kotlin-to-swift "$SWIFT_CLI" "$KOTLIN_CLI" 47801
run_case swift-to-kotlin "$KOTLIN_CLI" "$SWIFT_CLI" 47802
run_case swift-to-swift "$SWIFT_CLI" "$SWIFT_CLI" 47803
run_case kotlin-to-kotlin "$KOTLIN_CLI" "$KOTLIN_CLI" 47804
echo "All interop cases passed."
