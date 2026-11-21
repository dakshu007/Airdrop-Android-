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

start_receiver() { # name receiver port extra-args...
  local name="$1" receiver="$2" port="$3"; shift 3
  mkdir -p "$WORK/out-$name"
  "$receiver" receive --port "$port" --dir "$WORK/out-$name" --identity "$WORK/$name-recv.key" --name "Receiver" "$@" > "$WORK/$name-recv.log" 2>&1 &
  RPID=$!
  for _ in $(seq 1 100); do grep -q LISTENING "$WORK/$name-recv.log" 2>/dev/null && break; sleep 0.2; done
  grep -q LISTENING "$WORK/$name-recv.log" || { cat "$WORK/$name-recv.log"; echo "receiver did not start"; exit 1; }
}

fail_with_logs() { echo "$1"; for f in "$WORK"/*.log; do echo "--- $f"; cat "$f"; done; exit 1; }

# v1 extensions (docs/protocol-v1.md §9): links, folders, QR pairing with
# "my devices only", and resuming a dropped transfer.
run_extras() {
  local name="$1" receiver="$2" sender="$3" port="$4"
  echo "=== extras $name: $(basename "$sender") -> $(basename "$receiver") ==="

  # Link: arrives as text, nothing saved.
  start_receiver "$name-link" "$receiver" "$port" --once
  "$sender" send --host 127.0.0.1 --port "$port" --identity "$WORK/$name-send.key" --kind link --text "https://example.com/a?b=c" \
    > "$WORK/$name-link-send.log" 2>&1 || fail_with_logs "link send failed"
  wait "$RPID" || fail_with_logs "link receiver failed"
  grep -q "^TEXT link $(printf 'https://example.com/a?b=c' | base64)" "$WORK/$name-link-recv.log" || fail_with_logs "link not received"
  [[ -z "$(ls -A "$WORK/out-$name-link")" ]] || fail_with_logs "a link must not create files"

  # Folder: structure kept under the destination.
  start_receiver "$name-folder" "$receiver" $((port + 1)) --once
  "$sender" send --host 127.0.0.1 --port $((port + 1)) --identity "$WORK/$name-send.key" --path "Trip/Day 1" "$WORK/in/one-byte.bin" \
    > "$WORK/$name-folder-send.log" 2>&1 || fail_with_logs "folder send failed"
  wait "$RPID" || fail_with_logs "folder receiver failed"
  [[ -f "$WORK/out-$name-folder/Trip/Day 1/one-byte.bin" ]] || { ls -laR "$WORK/out-$name-folder"; fail_with_logs "folder structure lost"; }

  # My devices only: a stranger is refused, a QR token gets in.
  start_receiver "$name-qr" "$receiver" $((port + 2)) --private --token-out "$WORK/$name-token"
  if "$sender" send --host 127.0.0.1 --port $((port + 2)) --identity "$WORK/$name-stranger.key" "$WORK/in/one-byte.bin" > "$WORK/$name-stranger.log" 2>&1; then
    fail_with_logs "private receiver accepted a stranger"
  fi
  grep -q "not_receiving" "$WORK/$name-stranger.log" || fail_with_logs "stranger should see not_receiving"
  read -r token fpr < "$WORK/$name-token"
  "$sender" send --host 127.0.0.1 --port $((port + 2)) --identity "$WORK/$name-send.key" --qr "$token:$fpr" "$WORK/in/big.bin" \
    > "$WORK/$name-qr-send.log" 2>&1 || fail_with_logs "QR pairing send failed"
  if grep -q '^SAS' "$WORK/$name-qr-send.log" "$WORK/$name-qr-recv.log"; then fail_with_logs "QR pairing must not show codes"; fi
  kill "$RPID" 2>/dev/null || true; wait "$RPID" 2>/dev/null || true

  # Resume: the sender dies halfway; the next attempt sends only the rest.
  start_receiver "$name-resume" "$receiver" $((port + 3))
  "$sender" send --host 127.0.0.1 --port $((port + 3)) --identity "$WORK/$name-send.key" --die-after 2500000 "$WORK/in/random 5MB.bin" \
    > "$WORK/$name-resume-1.log" 2>&1 && fail_with_logs "the dying sender should not succeed"
  sleep 1
  "$sender" send --host 127.0.0.1 --port $((port + 3)) --identity "$WORK/$name-send.key" "$WORK/in/random 5MB.bin" \
    > "$WORK/$name-resume-2.log" 2>&1 || fail_with_logs "resumed send failed"
  grep -q '^RESUMED ' "$WORK/$name-resume-2.log" || fail_with_logs "second attempt did not resume"
  kill "$RPID" 2>/dev/null || true; wait "$RPID" 2>/dev/null || true
  [[ "$(shasum -a 256 "$WORK/out-$name-resume/random 5MB.bin" | awk '{print $1}')" == "$(shasum -a 256 "$WORK/in/random 5MB.bin" | awk '{print $1}')" ]] \
    || fail_with_logs "resumed file differs"
  echo "ok: link, folder, QR + my-devices-only, resume ($(grep '^RESUMED' "$WORK/$name-resume-2.log"))"
}

if [[ "${INTEROP_EXTRAS_ONLY:-}" != "1" ]]; then
run_case kotlin-to-swift "$SWIFT_CLI" "$KOTLIN_CLI" 47801
run_case swift-to-kotlin "$KOTLIN_CLI" "$SWIFT_CLI" 47802
run_case swift-to-swift "$SWIFT_CLI" "$SWIFT_CLI" 47803
run_case kotlin-to-kotlin "$KOTLIN_CLI" "$KOTLIN_CLI" 47804
fi
run_extras kotlin-to-swift "$SWIFT_CLI" "$KOTLIN_CLI" 47810
run_extras swift-to-kotlin "$KOTLIN_CLI" "$SWIFT_CLI" 47820
run_extras kotlin-to-kotlin "$KOTLIN_CLI" "$KOTLIN_CLI" 47830
echo "All interop cases passed."
