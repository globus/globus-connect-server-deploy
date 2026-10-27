.PHONY: all help export

############################################################################
# Makefile - the entry points to this repo
#
# make help shows the targets with examples.  Everything here is a thin wrapper:
# the work is in scripts/ (export for 'export').  Variables are passed as
# VAR=value on the command line.
############################################################################

############################################################################
# VARIABLES
#
# Each is used by the targets named in its comment; the help text at the end of
# this file lists them too.
############################################################################

# Distro to act on.  export: exactly one.
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

############################################################################
# TARGETS
#
# A comment starting with '## ' is shown by 'make help'.  Keep them in step with
# the recipes below them.
############################################################################

all: help

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
	@printf '  DISTRO=<name>     the distro to export\n'
	@printf '  REPO=<repo>       stable (default), unstable, testing, pre-stable, pre-unstable, pre-testing\n'
	@printf '  REPO_CONF=<repo>  where the repo definitions come from (default: REPO)\n'
	@printf '  GCS_VERSION=<v>   install this GCS version, not the newest\n'
	@printf '\n'
