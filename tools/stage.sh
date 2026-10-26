#!/bin/bash
# bend-guard: stage Bend sources into a fresh native WSL build folder.
# Run inside WSL as root:  bash -l stage.sh <name> <bend-dir-wsl> [<project-dir-wsl>]
#   copies <bend-dir>/core, laws and base (whichever exist, subfolders kept)
#   to /root/bg-build/<name>/, and the project's *.bend to .../project/.
# Prints the build folder on its last line. Plan: docs/plan.md Task 1.1.
set -eu
export BEND_NO_TELEMETRY=1

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: stage.sh <name> <bend-dir-wsl> [<project-dir-wsl>]" >&2
  exit 2
fi
name=$1
src=$2
proj=${3:-}

# The name becomes a folder that is deleted first, so keep it plain.
case "$name" in
  ''|.|..|*[!A-Za-z0-9_.-]*)
    echo "stage.sh: bad build name '$name' (letters, digits, _ . - only)" >&2
    exit 2 ;;
esac
if [ ! -d "$src" ]; then
  echo "stage.sh: no such bend folder: $src" >&2
  exit 2
fi
if [ -n "$proj" ] && [ ! -d "$proj" ]; then
  echo "stage.sh: no such project folder: $proj" >&2
  exit 2
fi

out=/root/bg-build/$name
rm -rf -- "$out"
mkdir -p -- "$out"

for part in core laws base; do
  if [ -d "$src/$part" ]; then
    cp -r -- "$src/$part" "$out/$part"
  fi
done

if [ -n "$proj" ]; then
  mkdir -p -- "$out/project"
  for f in "$proj"/*.bend; do
    [ -e "$f" ] || continue
    cp -- "$f" "$out/project/"
  done
fi

echo "$out"
