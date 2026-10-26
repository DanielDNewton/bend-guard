#!/bin/bash
# bend-guard: compile a staged entry file to an ES module.
# Run inside WSL as root:  bash -l compile.sh <build-dir> <entry-rel-path> <out-path-wsl>
#   e.g. compile.sh /root/bg-build/x base/Policy.bend /root/bg-build/x/policy.mjs
# bend checks before it writes, and writes nothing when a proof fails.
# Prints "sha256 <hex>" (of the bytes bend wrote, hashed right away), then
# "compiled <out> (<n> bytes)". The approve tool compiles into the root-only
# build folder and checks the bytes it reads back against that hash.
# Plan: docs/plan.md Task 1.1.
set -eu
export BEND_NO_TELEMETRY=1

if [ $# -ne 3 ]; then
  echo "usage: compile.sh <build-dir> <entry-rel-path> <out-path-wsl>" >&2
  exit 2
fi
dir=$1
entry=$2
out=$3

if [ ! -f "$dir/$entry" ]; then
  echo "compile.sh: no such entry: $dir/$entry" >&2
  exit 1
fi
case "$out" in
  /*) ;;
  *) echo "compile.sh: the output path must be absolute: $out" >&2; exit 2 ;;
esac

mkdir -p -- "$(dirname -- "$out")"
rm -f -- "$out"
log=$(cd -- "$(dirname -- "$dir/$entry")" && timeout 900 bend "$(basename -- "$entry")" -o "$out" 2>&1) || true

if printf '%s\n' "$log" | grep -qE 'SOME PROOFS FAIL|Error' || [ ! -s "$out" ]; then
  printf '%s\n' "$log" | head -15
  echo "compile failed: $entry"
  rm -f -- "$out"
  exit 1
fi
echo "sha256 $(sha256sum -- "$out" | cut -d' ' -f1)"
echo "compiled $out ($(wc -c < "$out" | tr -d ' ') bytes)"
