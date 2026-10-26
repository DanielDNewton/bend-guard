#!/bin/bash
# bend-guard: the proof gate for a staged build folder (see stage.sh).
# Run inside WSL as root:  bash -l check.sh <build-dir>
#   - every folder holding a PROOF.bend: `bend PROOF.bend` (checker) and
#     `bend PROOF.bend --verdict` (kernel) must print ALL PROOFS CHECK and
#     neither SOME PROOFS FAIL nor Error (bend exits 0 either way);
#   - every law in a LAWS.bend has a def of that name in the sibling PROOF.bend;
#   - no .bend file holds @unsafe, a ? (holes ?TODO/?goal, def f?(..)), a
#     foreign body (an indented `import "x.js"`), or an import other than
#     `import Base` / `import ./x.bend as X` resolving inside the build folder;
#   - base/Policy.bend and project/Policy.bend, if present, pass --check-only.
# A forbidden form stops the check before bend runs at all.
# Last line: BEND-GUARD CHECK OK (exit 0) or BEND-GUARD CHECK FAILED (exit 1).
# Plan: docs/plan.md Task 1.1; Bend facts: bend/NOTES.md.
set -eu
export BEND_NO_TELEMETRY=1

if [ $# -ne 1 ]; then
  echo "usage: check.sh <build-dir>" >&2
  exit 2
fi
if [ ! -d "$1" ]; then
  echo "check.sh: no such build folder: $1"
  echo "BEND-GUARD CHECK FAILED"
  exit 1
fi
dir=$(realpath -e -- "$1")
fail=0
checked=0

rel() {
  if [ "$1" = "$dir" ]; then echo "."; else echo "${1#"$dir"/}"; fi
}

# run_bend <folder> <file> <label> [bend args...]
run_bend() {
  local folder=$1 file=$2 label=$3 out
  shift 3
  out=$(cd -- "$folder" && timeout 900 bend "$file" "$@" 2>&1) || true
  if printf '%s\n' "$out" | grep -q 'ALL PROOFS CHECK' \
     && ! printf '%s\n' "$out" | grep -qE 'SOME PROOFS FAIL|Error'; then
    echo "$label: ok"
  else
    echo "$label: FAIL"
    printf '%s\n' "$out" | head -15
    fail=1
  fi
}

# 1. Forbidden forms, in every .bend under the build folder.
mapfile -t files < <(find "$dir" -type f -name '*.bend' | sort)
bad=0
imports=$(mktemp)
trap 'rm -f "$imports"' EXIT
if [ ${#files[@]} -gt 0 ]; then
  # Strip char literals, strings and comments, then look for the forms.
  # Import paths are printed as "IMPORT<TAB>file<TAB>path" for step 2.
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
  # Stop before running bend: a hub import would fetch from the network.
  echo "forbidden forms: FAIL"
  echo "BEND-GUARD CHECK FAILED"
  exit 1
fi

# 2. Law folders: names, checker, kernel.
mapfile -t proofs < <(find "$dir" -type f -name PROOF.bend | sort)
mapfile -t lawfiles < <(find "$dir" -type f -name LAWS.bend | sort)
for l in ${lawfiles[@]+"${lawfiles[@]}"}; do
  if [ ! -f "$(dirname -- "$l")/PROOF.bend" ]; then
    echo "$(rel "$(dirname -- "$l")") laws: FAIL (LAWS.bend has no sibling PROOF.bend)"
    fail=1
  fi
done
for p in ${proofs[@]+"${proofs[@]}"}; do
  folder=$(dirname -- "$p")
  label=$(rel "$folder")
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
  run_bend "$folder" PROOF.bend "$label checker"
  run_bend "$folder" PROOF.bend "$label kernel" --verdict
  checked=$((checked + 1))
done

# 3. Policy entries type-check.
for pol in "$dir/base/Policy.bend" "$dir/project/Policy.bend"; do
  if [ -f "$pol" ]; then
    run_bend "$(dirname -- "$pol")" Policy.bend "$(rel "$pol") check-only" --check-only
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
