#!/usr/bin/env bash
############################################################################
# lib.sh - shared helpers for the scripts in this directory
#
# Source it, do not run it:
#     . "$(cd "$(dirname "$0")" && pwd)/lib.sh"
#
# What it gives a script, in the order it appears below:
#   SUPPORTED     DOCKERFILES, REPOS, DISTROS, repo_stage, distro_family
#   OUTPUT        colours (RED GRN YLW DIM RST), TTY, VERBOSE, lib_scan_verbose
#   RESULTS       _pass, _fail, _section, _progress, report
#   PREDICATES    _contains and friends: text tests, for use inside 'if'
#   ASSERTIONS    assert_contains, assert_matches, assert_a_before_b, ...
#
# Every function that records a result ends in an explicit 'return 0'.  Under
# 'set -e' a helper that returns non-zero kills its caller, and these used to
# end in '[[ $VERBOSE -eq 1 ]] && printf ...', which returns 1 whenever
# VERBOSE=0.  Suites then died at their first PASSING assertion with exit 1 and
# no output.  Keep the explicit returns, and never end a function with a bare
# '&&' chain.
############################################################################
# shellcheck shell=bash

############################################################################
# SUPPORTED
#
# What the repo supports is simply the Dockerfiles: adding a distro means
# adding docker-files/Dockerfile.<distro> with a '# family:' header, and nothing
# else.  The list of repos never changes.
############################################################################
DOCKERFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker-files" && pwd)"
# shellcheck disable=SC2034  # read by the scripts that source this file
REPOS=(stable unstable testing pre-stable pre-unstable pre-testing)

DISTROS=()
for _f in "${DOCKERFILES}"/Dockerfile.*; do
  [[ -f "$_f" ]] && DISTROS+=("${_f##*/Dockerfile.}")
done
unset _f

# DISTRO='a b' (set by 'make ... DISTRO=...') narrows every suite, and
# 'build --all', to those distros.  An unknown name is an error, not a skip.
if [[ -n "${DISTRO:-}" ]]; then
  DISTROS=()
  set -f    # DISTRO is a word list, not a glob
  for _d in ${DISTRO}; do
    if [[ ! -f "${DOCKERFILES}/Dockerfile.${_d}" ]]; then
      printf 'unknown distro: %s (see: make list)\n' "$_d" >&2
      exit 2
    fi
    DISTROS+=("$_d")
  done
  set +f
  unset _d
fi

# repo_stage <repo> [<repo-conf>] - print which repo stage a build uses:
# 'stable' for a default build (repo stable, and the definitions from stable too),
# 'other' for everything else.  scripts/build passes it as _REPO_STAGE.
repo_stage() {
  if [[ "$1" == stable && ( -z "${2:-}" || "$2" == stable ) ]]; then printf stable
  else printf other; fi
}

# distro_family <distro> - print deb, el, fedora or suse, from the Dockerfile's
# '# family:' header.  The family decides which commands the checks expect.
distro_family() {
  local f="${DOCKERFILES}/Dockerfile.$1" fam
  if [[ ! -f "$f" ]]; then
    printf 'unknown distro: %s\n' "$1" >&2
    return 1
  fi
  fam=$(sed -nE 's/^# family:[[:space:]]*([^[:space:]]+).*/\1/p' "$f" | head -1)
  if [[ -z "$fam" ]]; then
    printf '%s: no "# family:" header\n' "$f" >&2
    return 1
  fi
  printf '%s' "$fam"
}

############################################################################
# OUTPUT
#
# Colours only when stdout is a terminal.  Quiet is the default; -v or
# --verbose prints every assertion.
############################################################################
if [[ -t 1 ]]; then
  TTY=1
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'
  DIM=$'\033[2m';    RST=$'\033[0m'
else
  TTY=0
  RED=''; GRN=''; YLW=''; DIM=''; RST=''
fi

VERBOSE="${VERBOSE:-0}"
PASS=0
FAIL=0
ERRORS=()

# lib_scan_verbose "$@" - turn VERBOSE on if -v or --verbose is among the args.
lib_scan_verbose() {
  local a
  for a in "$@"; do
    case "$a" in -v|--verbose) VERBOSE=1 ;; esac
  done
  return 0
}

############################################################################
# RESULTS
#
# A suite calls _pass or _fail once per check and ends with 'report', which
# prints the failures and a summary and returns non-zero if anything failed.
############################################################################

# _pass <id>
_pass() {
  PASS=$(( PASS + 1 ))
  if [[ $VERBOSE -eq 1 ]]; then
    printf '    %spass%s  %s\n' "$GRN" "$RST" "$1"
  fi
  return 0
}

# _fail <id> <reason> - the failure is kept for 'report'; shown now if verbose.
_fail() {
  FAIL=$(( FAIL + 1 ))
  ERRORS+=("${RED}FAIL${RST} [${YLW}${1}${RST}] ${2}")
  if [[ $VERBOSE -eq 1 ]]; then
    printf '    %sFAIL%s  %s — %s\n' "$RED" "$RST" "$1" "$2"
  fi
  return 0
}

# _section <title> - a heading between groups of checks (verbose only).
_section() {
  if [[ $VERBOSE -eq 1 ]]; then
    printf '\n%s%s%s\n' "$DIM" "$1" "$RST"
  fi
  return 0
}

# _progress <done> <total> - a one-line counter, on a terminal and not verbose.
# In a pipe or a log, '\r' does nothing useful and the counter would come out
# as one very long line.
_progress() {
  if [[ $VERBOSE -eq 0 && $TTY -eq 1 ]]; then
    printf '\r  %d/%d' "$1" "$2"
  fi
  return 0
}

# _progress_clear - erase the counter line.
_progress_clear() {
  if [[ $VERBOSE -eq 0 && $TTY -eq 1 ]]; then
    printf '\r%*s\r' 24 ''
  fi
  return 0
}

# report <label> [<unit>] [<suffix>] - print the collected failures and a
# summary line.  Returns non-zero if anything failed, so a script can end with
# 'report ...' and exit with the right status.
#   label   what passed, for "All <label> passed", e.g. "dockerfile checks"
#   unit    what the counts count                       [assertions]
#   suffix  appended to the count, e.g. " across 135 combinations"
report() {
  local label="${1:-assertions}" unit="${2:-assertions}" suffix="${3:-}"
  _progress_clear
  printf '\n'
  if (( ${#ERRORS[@]} > 0 )); then
    printf '%b\n' "${ERRORS[@]}"
    printf '\n'
  fi
  if (( FAIL == 0 )); then
    printf '%sAll %s passed%s — %d %s%s\n' \
      "$GRN" "$label" "$RST" "$PASS" "$unit" "$suffix"
  else
    printf '%s%d failed%s, %d passed — %d %s%s\n' \
      "$RED" "$FAIL" "$RST" "$PASS" $(( PASS + FAIL )) "$unit" "$suffix"
  fi
  printf '\n'
  (( FAIL == 0 ))
}

############################################################################
# PREDICATES
#
# Text tests for use inside 'if'.  They return non-zero for "no", so never call
# them bare under 'set -e'; the assertions below wrap them.
#
# None of them uses 'grep -q'.  It exits at the first match, the writer then
# dies of SIGPIPE, and under 'set -o pipefail' a pattern that IS present gets
# reported as missing whenever the text is large enough for the timing to line
# up.  Sending grep's output to /dev/null makes it read all its input.
############################################################################
_contains()     { printf '%s\n' "$2" | grep -F -- "$1" >/dev/null; }
_not_contains() { ! printf '%s\n' "$2" | grep -F -- "$1" >/dev/null; }
_matches()      { printf '%s\n' "$2" | grep -E -- "$1" >/dev/null; }

# _line_of <literal> <text> - the first line number that contains it, or nothing.
_line_of()      { printf '%s\n' "$2" | grep -nF -- "$1" | head -1 | cut -d: -f1 || true; }

# _last_instr <text> - the last line that is neither blank nor a comment.
_last_instr()   { printf '%s\n' "$1" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | tail -1; }

############################################################################
# ASSERTIONS
#
# Each takes what to look for, the text, and an id for the report, records a
# pass or a failure, and always returns 0.
############################################################################

# assert_contains <literal> <text> <id>
assert_contains() {
  local pat="$1" text="$2" id="$3"
  if _contains "$pat" "$text"; then _pass "$id"
  else _fail "$id" "expected to contain: $(printf '%q' "$pat")"; fi
  return 0
}

# assert_not_contains <literal> <text> <id>
assert_not_contains() {
  local pat="$1" text="$2" id="$3"
  if _not_contains "$pat" "$text"; then _pass "$id"
  else _fail "$id" "expected NOT to contain: $(printf '%q' "$pat")"; fi
  return 0
}

# assert_matches <regex> <text> <id> - extended regular expression.
assert_matches() {
  local re="$1" text="$2" id="$3"
  if _matches "$re" "$text"; then _pass "$id"
  else _fail "$id" "expected to match: $(printf '%q' "$re")"; fi
  return 0
}

# assert_last_instruction <literal> <text> <id> - the last real line (not blank,
# not a comment) contains it.
assert_last_instruction() {
  local pat="$1" text="$2" id="$3" last
  last="$(_last_instr "$text")" || true
  if _contains "$pat" "$last"; then _pass "$id"
  else _fail "$id" "expected last instruction to contain '$pat', got: $last"; fi
  return 0
}

# assert_a_before_b <literal-a> <literal-b> <text> <id> - both appear, and the
# first line containing a comes before the first line containing b.
assert_a_before_b() {
  local pa="$1" pb="$2" text="$3" id="$4" la lb
  la="$(_line_of "$pa" "$text")"
  lb="$(_line_of "$pb" "$text")"
  if   [[ -z "$la" ]]; then _fail "$id" "ordering: '$pa' not found"
  elif [[ -z "$lb" ]]; then _fail "$id" "ordering: '$pb' not found"
  elif (( la < lb ));  then _pass "$id"
  else _fail "$id" "ordering: '$pa' (line $la) must come before '$pb' (line $lb)"; fi
  return 0
}
