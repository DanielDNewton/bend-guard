#!/bin/bash
# bend-guard: the proof gate for a staged build folder (see stage.sh).
# Same checks as check.sh, faster:
#   - law folders are checked in parallel;
#   - a proof already checked with the same bend binary and the same .bend
#     sources (everything outside project/, plus project/ for the project
#     folder) reuses that result from a cache inside WSL
#     (/root/.bend-guard-proofs). Any changed source is proven again.
#   - with --no-cache the cache is never read: every proof runs again. The
#     approve tool always uses it, because any root process in WSL can append
#     a line to the cache, so a cache line is no evidence. Proofs that pass
#     are still added to the cache, so later draft checks are fast.
# Run inside WSL as root:  bash -l prove.sh <build-dir> [--no-cache]
# Last line: BEND-GUARD CHECK OK (exit 0) or BEND-GUARD CHECK FAILED (exit 1).
set -eu
export BEND_NO_TELEMETRY=1

use_cache=1
if [ $# -eq 2 ] && [ "$2" = --no-cache ]; then
  use_cache=0
elif [ $# -ne 1 ]; then
  echo "usage: prove.sh <build-dir> [--no-cache]" >&2
  exit 2
fi
if [ ! -d "$1" ]; then
  echo "prove.sh: no such build folder: $1"
  echo "BEND-GUARD CHECK FAILED"
  exit 1
fi
dir=$(realpath -e -- "$1")
fail=0
checked=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

rel() {
  if [ "$1" = "$dir" ]; then echo "."; else echo "${1#"$dir"/}"; fi
}

# run_bend <folder> <file> <label> <result-file> [bend args...]
run_bend() {
  local folder=$1 file=$2 label=$3 res=$4 out
  shift 4
  out=$(cd -- "$folder" && timeout 900 bend "$file" "$@" 2>&1) || true
  if printf '%s\n' "$out" | grep -q 'ALL PROOFS CHECK' \
     && ! printf '%s\n' "$out" | grep -qE 'SOME PROOFS FAIL|Error'; then
    echo "$label: ok" > "$res"
  else
    { echo "$label: FAIL"; printf '%s\n' "$out" | head -15; } > "$res"
  fi
}

# passed <result-file> <label>: the result's FIRST line is exactly
# "<label>: ok" (or "<label>: ok (cached proof)"). Only the first line
# counts: a failed proof's output follows its FAIL line and can contain
# ": ok" (e.g. "Location: okta_protected").
passed() {
  local first
  first=$(head -n 1 -- "$1")
  [ "$first" = "$2: ok" ] || [ "$first" = "$2: ok (cached proof)" ]
}

CACHE=/root/.bend-guard-proofs
touch "$CACHE"
BENDSUM=$(sha256sum "$(command -v bend)" | cut -d' ' -f1)

# key <folder>: the bend binary, the folder, and every .bend file it can import.
key() {
  local f=$1 r
  r=$(rel "$f")
  {
    echo "$BENDSUM $r"
    if [ "$r" = project ]; then
      find "$dir" -type f -name '*.bend' | sort
    else
      find "$dir" -type f -name '*.bend' -not -path "$dir/project/*" | sort
    fi | while read -r x; do echo "== $(rel "$x")"; cat -- "$x"; done
  } | sha256sum | cut -d' ' -f1
}

# 1. Forbidden forms, in every .bend under the build folder.
mapfile -t files < <(find "$dir" -type f -name '*.bend' | sort)
bad=0
imports="$work/imports"
: > "$imports"
if [ ${#files[@]} -gt 0 ]; then
  perl -ne '
    my $raw = $_;
    my $l = $raw;
    $l =~ s/\x27(?:\\.|[^\x27\\])\x27|"(?:\\.|[^"\\])*"|#.*$/ /g;
    my $at = "$ARGV:$.";
    if ($l =~ /\@unsafe/) { print "FORBID\t$at: \@unsafe\n"; }
    if ($l =~ /\?/) { print "FORBID\t$at: ? (a hole or an unchecked def f?)\n"; }
    if ($raw =~ /^\s+import\b/) { print "FORBID\t$at: foreign body (indented import)\n"; }
    if ($raw =~ /^import\b/) {
      (my $c = $raw) =~ s/#.*$//;
      $c =~ s/\s+$//;
      if ($c =~ /^import Base$/) {
      } elsif ($c =~ m{^import (\.\.?/[A-Za-z0-9_/.-]+\.bend) as [A-Za-z_][A-Za-z0-9_]*$}) {
        print "IMPORT\t$ARGV\t$1\n";
      } else {
        print "FORBID\t$at: import that is not Base or a local ./x.bend as X\n";
      }
    }
    close ARGV if eof;
  ' "${files[@]}" > "$imports"
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      FORBID)
        echo "forbidden form: $(rel "${a%%:*}"):${a#*:}"
        bad=1 ;;
      IMPORT)
        target=$(realpath -m -- "$(dirname -- "$a")/$b")
        case "$target" in
          "$dir"/*) ;;
          *) echo "forbidden form: $(rel "$a"): import $b leaves the build folder"; bad=1; continue ;;
        esac
        if [ ! -f "$target" ]; then
          echo "forbidden form: $(rel "$a"): import $b does not exist"
          bad=1
        fi ;;
    esac
  done < "$imports"
fi
if [ $bad -eq 0 ]; then
  echo "forbidden forms (${#files[@]} files): ok"
else
  echo "forbidden forms: FAIL"
  echo "BEND-GUARD CHECK FAILED"
  exit 1
fi

# 2. Law folders: names, then checker and kernel (cached or in parallel).
mapfile -t proofs < <(find "$dir" -type f -name PROOF.bend | sort)
mapfile -t lawfiles < <(find "$dir" -type f -name LAWS.bend | sort)
for l in ${lawfiles[@]+"${lawfiles[@]}"}; do
  if [ ! -f "$(dirname -- "$l")/PROOF.bend" ]; then
    echo "$(rel "$(dirname -- "$l")") laws: FAIL (LAWS.bend has no sibling PROOF.bend)"
    fail=1
  fi
done
i=0
labels=()
for p in ${proofs[@]+"${proofs[@]}"}; do
  folder=$(dirname -- "$p")
  label=$(rel "$folder")
  i=$((i + 1))
  labels[$i]=$label
  if [ -f "$folder/LAWS.bend" ]; then
    missing=""
    for n in $(sed -n 's/^law \([A-Za-z0-9_.]*\)[[:space:]]*:.*$/\1/p' "$folder/LAWS.bend"); do
      esc=$(printf '%s' "$n" | sed 's/\./\\./g')
      if ! grep -qE "^def ([A-Za-z0-9_]+\.)*${esc}[[:space:]]*\(" "$p"; then
        missing="$missing $n"
      fi
    done
    if [ -z "$missing" ]; then
      echo "$label laws proven by name: ok"
    else
      echo "$label laws proven by name: FAIL (no def for:$missing)"
      fail=1
    fi
  fi
  k=$(key "$folder")
  for mode in checker kernel; do
    res="$work/$i.$mode"
    if [ $use_cache -eq 1 ] && grep -qx "$k $mode" "$CACHE"; then
      echo "$label $mode: ok (cached proof)" > "$res"
    else
      flag=""
      [ $mode = kernel ] && flag="--verdict"
      ( run_bend "$folder" PROOF.bend "$label $mode" "$res" $flag
        if [ "$(head -n 1 -- "$res")" = "$label $mode: ok" ]; then echo "$k $mode" >> "$CACHE"; fi ) &
    fi
  done
  checked=$((checked + 1))
done
wait
j=0
for p in ${proofs[@]+"${proofs[@]}"}; do
  j=$((j + 1))
  for mode in checker kernel; do
    cat "$work/$j.$mode"
    passed "$work/$j.$mode" "${labels[$j]} $mode" || fail=1
  done
done

# 3. Policy entries type-check.
for pol in "$dir/base/Policy.bend" "$dir/project/Policy.bend"; do
  if [ -f "$pol" ]; then
    run_bend "$(dirname -- "$pol")" Policy.bend "$(rel "$pol") check-only" "$work/pol" --check-only
    cat "$work/pol"
    passed "$work/pol" "$(rel "$pol") check-only" || fail=1
    checked=$((checked + 1))
  fi
done

if [ $checked -eq 0 ]; then
  echo "nothing checked: no PROOF.bend or Policy.bend under $dir"
  fail=1
fi

if [ $fail -eq 0 ]; then
  echo "BEND-GUARD CHECK OK"
  exit 0
fi
echo "BEND-GUARD CHECK FAILED"
exit 1
