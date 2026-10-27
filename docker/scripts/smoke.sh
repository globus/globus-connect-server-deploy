#!/bin/sh
############################################################################
# smoke.sh - what is actually inside a built GCS image
#
# Runs inside the container; scripts/build pipes it in, nothing is copied:
#     docker run --rm -i --entrypoint /bin/sh <image> -s < scripts/smoke.sh
#
# It only OBSERVES.  It prints one KEY=value line per fact and always exits 0.
# scripts/build reads the lines and decides what is a failure, because the
# expected values depend on the repo the image was built for.
#
# Sections, and the keys each prints (* = scripts/build asserts on it):
#   GCS                 GCS_PATH, GCS_VERSION*
#   SYSTEMCTL MOCK      SYSTEMCTL_PATH, SYSTEMCTL_TARGET, SYSTEMCTL_IS_MOCK*,
#                       SYSTEMCTL_RESPONDS*, SYSTEMCTL_CAPS
#   ENTRYPOINT          ENTRYPOINT*, DROPIN_GCS_MANAGER*, DROPIN_OIDC*, DROPINS_PARSE*,
#                       PYTHON3
#   GLOBUS REPOS        GLOBUS_REPOS_ENABLED*
#
# Plain POSIX sh and tools every minimal image has: no bashisms, no GNU-only
# flags (readlink -f is used when present, only to show where the link goes),
# no awk (SLES 15 images lack it).  It must run unchanged on EL built
# from scratch, SUSE and Debian.
############################################################################

# _have <command> - is the command available?
_have() { command -v "$1" >/dev/null 2>&1; }

# _yesno <command...> - print yes if the command succeeds, no if it fails.
_yesno() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

############################################################################
# GCS
#
# Is GCS installed, and which version.  Both are empty if it is not;
# scripts/build decides whether that is right.
############################################################################
gcs_path=$(command -v globus-connect-server 2>/dev/null || true)
echo "GCS_PATH=${gcs_path}"

gcs_version=''
if [ -n "$gcs_path" ]; then
    # --version prints to stdout on some releases and stderr on others, so
    # read both and take the first x.y.z, with a pre-release tag if it has one
    # (5.4.100-rc1 is what a release candidate prints).  scripts/build uses the same
    # pattern to name the image; keep them the same.
    gcs_version=$("$gcs_path" --version 2>&1 \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([~.+-]?[A-Za-z]+[0-9]*)?' \
        | head -1 || true)
fi
echo "GCS_VERSION=${gcs_version}"

############################################################################
# SYSTEMCTL MOCK
#
# There is no systemd in a container, so the Dockerfiles replace systemctl
# with a mock that GCS's package scriptlets and entrypoint talk to.  These
# checks prove the mock survived the GCS install (a package update can
# silently put the real systemctl back) and that it still answers.
############################################################################

# --- Which systemctl is on PATH ---------------------------------------------
# Resolve it the way the scriptlets do, by PATH, not by testing /bin/systemctl.
sysctl_path=$(command -v systemctl 2>/dev/null || true)
echo "SYSTEMCTL_PATH=${sysctl_path}"

# --- Is it the mock? ---------------------------------------------------------
# The mock is a script that names itself ('systemctl-mock'), so look for that
# in the file the PATH entry resolves to (it is normally a symlink).
sysctl_is_mock=no
sysctl_target=''
if [ -n "$sysctl_path" ]; then
    sysctl_target=$sysctl_path
    if _have readlink; then
        resolved=$(readlink -f "$sysctl_path" 2>/dev/null || true)
        [ -n "$resolved" ] && sysctl_target=$resolved
    fi
    if grep -q 'systemctl-mock' "$sysctl_target" 2>/dev/null; then
        sysctl_is_mock=yes
    fi
fi
echo "SYSTEMCTL_TARGET=${sysctl_target}"
echo "SYSTEMCTL_IS_MOCK=${sysctl_is_mock}"

# --- Does it answer? ---------------------------------------------------------
# Existing is not enough.  is-active on a unit that is not running should exit
# non-zero, so the exit code is not the test; the failures are exit 127 (not
# found) or a Python traceback (the mock crashed).
sysctl_responds=no
if [ -n "$sysctl_path" ]; then
    out=$("$sysctl_path" is-active gcs_manager 2>&1)
    rc=$?
    if [ "$rc" -lt 126 ] && ! printf '%s' "$out" | grep -q 'Traceback'; then
        sysctl_responds=yes
    fi
fi
echo "SYSTEMCTL_RESPONDS=${sysctl_responds}"

# --- Does it report the capabilities GCS needs? ------------------------------
# check-capabilities is what the GCS entrypoint calls at startup.  Informational
# only: scripts/build does not fail on it.
sysctl_caps=no
[ -n "$sysctl_path" ] && sysctl_caps=$(_yesno "$sysctl_path" check-capabilities)
echo "SYSTEMCTL_CAPS=${sysctl_caps}"

############################################################################
# ENTRYPOINT
#
# The files the Dockerfiles install under /gcs-deploy: the entrypoint and the
# service drop-ins that make GCS's services run in a container.
############################################################################
echo "ENTRYPOINT=$(_yesno test -x /gcs-deploy/entrypoint.sh)"

# Read the drop-ins through /etc/systemd/system, the symlink path systemd and
# GCS use, so a broken link fails here too.
echo "DROPIN_GCS_MANAGER=$(_yesno test -r /etc/systemd/system/gcs_manager.service.d/container.conf)"
echo "DROPIN_OIDC=$(_yesno test -r /etc/systemd/system/globus-oidc.service.d/container.conf)"

# Informational: the mock is a Python script, so the image needs python3.
echo "PYTHON3=$(command -v python3 2>/dev/null || true)"

# --- Can the mock read the drop-ins? -----------------------------------------
# Present is not enough: the mock must parse them into the commands a start
# will run.  Load each service through the mock's own loader and check that the
# drop-in replaced the base unit's ExecStart with a gunicorn that binds its own
# socket, that the commands run after it are there, and that no line is left
# half-joined (a trailing backslash).  This does not start anything.  Prints
# 'yes', or 'no - <why>' on one line.
if _have python3; then
    echo "DROPINS_PARSE=$(python3 - <<'PY' 2>&1 | tail -1
import importlib.machinery, importlib.util

try:
    loader = importlib.machinery.SourceFileLoader('systemctl_mock', '/gcs-deploy/systemctl-mock')
    mock = importlib.util.module_from_spec(importlib.util.spec_from_loader('systemctl_mock', loader))
    loader.exec_module(mock)
    for unit in ('gcs_manager.service', 'globus-oidc.service'):
        data = mock.load_unit(unit)
        start = mock.get_all(data, 'Service', 'ExecStart')
        post = mock.get_all(data, 'Service', 'ExecStartPost')
        if len(start) != 1 or '--bind' not in start[0]:
            raise ValueError(f'{unit}: ExecStart is not the drop-in gunicorn: {start}')
        if not post:
            raise ValueError(f'{unit}: no ExecStartPost')
        if any('\\' in c for c in start + post):
            raise ValueError(f'{unit}: a line is not joined to the next')
    print('yes')
except Exception as e:
    print('no - ' + ' '.join(str(e).split()))
PY
)"
else
    echo "DROPINS_PARSE=no - python3 not found"
fi

############################################################################
# GLOBUS REPOS
#
# Which Globus repos are enabled: any of stable, unstable, testing, pre-stable,
# pre-unstable, pre-testing, printed in that order and space-separated.
# scripts/build requires exactly
# the repo the image was built for.  Anything else enabled alongside it means a
# later 'apt-get upgrade' or 'dnf update' could replace the GCS build under test
# (usually with the stable one); nothing enabled means the intended repo is not
# there at all.
#
# This reads the repo configuration files, not the package manager, so it works
# offline and after 'clean all'.  A repo is told apart by its URL:
#     https://downloads.globus.org/globus-connect-server/<repo>/...
#     https://builds.globus.org/downloads.globus.org/globus-connect-server/<repo>/...
#                                                                 (pre-<repo>)
# The host alone is not enough: the public repos share one host, and a pre- repo
# embeds the public URL after its own host.
#
# SMOKE_ROOT points the check at a fake root directory; for trying the script by hand.
############################################################################
root="${SMOKE_ROOT:-}"
enabled_seen=' '

# _trim <line> - the line without its leading whitespace.
_trim() { printf '%s' "${1#"${1%%[![:space:]]*}"}"; }

# _repo_of <url> - which Globus repo a URL belongs to (nothing if none).  The
# pre- patterns come first: their URL also contains the public one.
_repo_of() {
    case "$1" in
        *builds.globus.org/*globus-connect-server/stable/*)    echo pre-stable ;;
        *builds.globus.org/*globus-connect-server/unstable/*)  echo pre-unstable ;;
        *builds.globus.org/*globus-connect-server/testing/*)   echo pre-testing ;;
        *globus-connect-server/stable/*)       echo stable ;;
        *globus-connect-server/unstable/*)     echo unstable ;;
        *globus-connect-server/testing/*)      echo testing ;;
    esac
}

# _mark <repo> - record that the repo is enabled.  An empty name (a URL that is
# no Globus repo) and a repeat are ignored.
_mark() {
    case "$1" in
        '') ;;
        *) case "$enabled_seen" in *" $1 "*) ;; *) enabled_seen="$enabled_seen$1 " ;; esac ;;
    esac
}

# --- dnf and zypper: .repo files ---------------------------------------------
# Each [section] is one repo.  Its baseurl says which, and it is enabled unless
# the section says enabled=0.
#
# dnf5 does not edit the .repo file when a repo is switched: 'config-manager
# setopt Repo.enabled=0' writes /etc/dnf/repos.override.d/99-config_manager.repo
# and leaves the .repo file as shipped.  So the override files are read too, and
# an enabled= there wins over the one in the .repo file.
#
# POSIX sh has no arrays, so each repo id gets two variables: repo_which_<id>
# and repo_enabled_<id>.
repo_ids=''

# _read_repo_file <file> <base|override>
_read_repo_file() {
    sid=''
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(_trim "$line")
        case "$line" in
            \[*)  sid=$(printf '%s' "${line#\[}" | tr -c 'A-Za-z0-9\n' '_')
                  sid=${sid%_}
                  case " $repo_ids " in *" $sid "*) ;; *) repo_ids="$repo_ids $sid" ;; esac
                  # a repo is enabled unless told otherwise; an override file
                  # only changes what it says
                  if [ "$2" = base ]; then eval "repo_enabled_$sid=1"; fi ;;
            baseurl=*|'baseurl '*=*)
                  [ -n "$sid" ] && eval "repo_which_$sid=\$(_repo_of \"\${line#*=}\")" ;;
            enabled=*|'enabled '*=*)
                  value=$(printf '%s' "${line#*=}" | tr -d '[:space:]')
                  if [ -n "$sid" ]; then
                      if [ "$value" = 0 ]; then eval "repo_enabled_$sid=0"; else eval "repo_enabled_$sid=1"; fi
                  fi ;;
        esac
    done < "$1"
}

for dir in "$root/etc/yum.repos.d" "$root/etc/zypp/repos.d"; do
    for file in "$dir"/*.repo; do
        [ -f "$file" ] && _read_repo_file "$file" base
    done
done
for file in "$root"/etc/dnf/repos.override.d/*.repo; do
    [ -f "$file" ] && _read_repo_file "$file" override
done

which=; enabled=1    # set by the eval below; declared so shellcheck sees them
for sid in $repo_ids; do
    eval "which=\${repo_which_$sid:-}; enabled=\${repo_enabled_$sid:-1}"
    [ -n "$which" ] && [ "$enabled" != 0 ] && _mark "$which"
done

# --- apt: sources lists ------------------------------------------------------
# A repo is enabled by an uncommented 'deb' line; disabling comments it out.
for file in "$root/etc/apt/sources.list" "$root"/etc/apt/sources.list.d/*.list; do
    [ -f "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(_trim "$line")
        case "$line" in
            deb[[:space:]]*) _mark "$(_repo_of "$line")" ;;
        esac
    done < "$file"
done

enabled_repos=''
for repo in stable unstable testing pre-stable pre-unstable pre-testing; do
    case "$enabled_seen" in *" $repo "*) enabled_repos="$enabled_repos $repo" ;; esac
done
echo "GLOBUS_REPOS_ENABLED=${enabled_repos# }"

exit 0
