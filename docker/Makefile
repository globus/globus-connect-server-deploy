.PHONY: all help check list export

############################################################################
# Makefile - the entry points to this repo
#
# make help shows the targets with examples.  Everything here is a thin wrapper:
# the work is in scripts/ (check-* for 'check', export for 'export').
# Variables are passed as VAR=value on the command line.
############################################################################

############################################################################
# VARIABLES
#
# Each is used by the targets named in its comment; the help text at the end of
# this file lists them too.
############################################################################

# Distro to act on.  check: a space-separated list, default every distro.
# export: exactly one.
DISTRO ?=

# Which GCS repo: stable, unstable, testing, pre-stable, pre-unstable or
# pre-testing (the pre- ones are internal, and need the VPN).
REPO ?= stable

# export: where the globus-repo package (the repo definitions) comes
# from; any REPO value.  Empty means the same as REPO.  Set it to pre-stable for
# a distro whose definitions are only there; the packages still come from REPO.
REPO_CONF ?=

# export: install exactly this GCS version instead of the newest in the
# repo, e.g. GCS_VERSION=5.4.83 or GCS_VERSION=5.4.100-rc1 (as --version prints it; 5.4.100~rc1 works too).
GCS_VERSION ?=

# check: V=1 prints every assertion.
V ?=

############################################################################
# TARGETS
#
# A comment starting with '## ' is shown by 'make help'.  Keep them in step with
# the recipes below them.
############################################################################

all: help

## check             lint and test everything that needs neither Docker nor the network
##                   (the docker build --check lint runs only where Docker is available)
##                   make check V=1                  print every assertion
##                   make check DISTRO=fedora-44     only that distro (skips the script lint)
check:
	@status=0; \
	for s in $(if $(DISTRO),,shell) syntax dockerfiles content; do \
	    printf '═══ %s ═══\n' $$s; \
	    DISTRO="$(DISTRO)" ./scripts/check-$$s $(if $(filter-out 0,$(V)),--verbose,) || status=1; \
	done; \
	exit $$status

## list              list all supported distros
list:
	@ls docker-files | sed -n 's/^Dockerfile\.//p'

## export            write one Dockerfile for DISTRO and REPO to stdout
##                   make export DISTRO=ubuntu-24.04 > Dockerfile
##                   make export DISTRO=ubuntu-24.04 REPO=unstable REPO_CONF=pre-stable > Dockerfile
##                   The default is stable: no repo selection is left in the file.
export:
	@if [ -z "$(DISTRO)" ]; then \
	    printf 'make export needs DISTRO, e.g.\n' >&2; \
	    printf '  make export DISTRO=ubuntu-24.04 > Dockerfile\n' >&2; \
	    exit 2; \
	fi
	@./scripts/export $(DISTRO) --repo $(REPO) $(if $(REPO_CONF),--repo-conf $(REPO_CONF),) \
	    $(if $(GCS_VERSION),--gcs-version '$(GCS_VERSION)',)

## help              show this message
help:
	@printf 'Usage: make <target> [VAR=value ...]\n\n'
	@awk '/^## / { line=$$0; sub(/^## /,"  ",line); print line }' Makefile
	@printf '\nVariables:\n'
	@printf '  DISTRO=<name>     distro (check: a list, default all; export: one)\n'
	@printf '  REPO=<repo>       stable (default), unstable, testing, pre-stable, pre-unstable, pre-testing\n'
	@printf '  REPO_CONF=<repo>  export: where the repo definitions come from (default: REPO)\n'
	@printf '  GCS_VERSION=<v>   export: install this GCS version, not the newest\n'
	@printf '  V=1               check: print every assertion\n\n'
