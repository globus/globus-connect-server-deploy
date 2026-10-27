.PHONY: all help check list images export clean clobber

############################################################################
# Makefile - the entry points to this repo
#
# make help shows the targets with examples.  Everything here is a thin wrapper:
# the work is in scripts/ (check-* for 'check', build for 'images', export
# for 'export').  Variables are passed as VAR=value on the command line.
############################################################################

############################################################################
# VARIABLES
#
# Each is used by the targets named in its comment; the help text at the end of
# this file lists them too.
############################################################################

# Distro to act on.  check and images: a space-separated list, default every
# distro.  export: exactly one.
DISTRO ?=

# Which GCS repo: stable, unstable, testing, pre-stable, pre-unstable or
# pre-testing (the pre- ones are internal, and need the VPN).
REPO ?= stable

# images, export: where the globus-repo package (the repo definitions) comes
# from; any REPO value.  Empty means the same as REPO.  Set it to pre-stable for
# a distro whose definitions are only there; the packages still come from REPO.
REPO_CONF ?=

# images, export: install exactly this GCS version instead of the newest in the
# repo, e.g. GCS_VERSION=5.4.83 or GCS_VERSION=5.4.100-rc1 (as --version prints it; 5.4.100~rc1 works too).
GCS_VERSION ?=

# images: the GCS version every image must contain, in the same form.  An image
# with any other version fails the build.  Defaults to GCS_VERSION.  Without
# either, 'make images' only warns, when the images differ from each other or
# from the newest version the repo publishes.
EXPECTED_GCS_VERSION ?=

# images: VERIFY=0 builds only, without the runtime checks.
VERIFY ?= 1

# images: PROXY=socks5h://127.0.0.1:1080 sends the builds' network traffic
# through a proxy (for example a SOCKS5 proxy to the VPN needed for a pre- repo).
PROXY ?=

# images: concurrent builds.  Download-bound, not CPU-bound, so the ceiling is
# your link and your disk, not nproc.
J ?= 4

# images: REFRESH=1 also refreshes the base image and distro packages.
REFRESH ?=

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

## images            build images and verify them (needs Docker and the network)
##                   make images                          every distro, stable
##                   make images DISTRO=fedora-44 REPO=testing
##                   make images REPO=pre-stable EXPECTED_GCS_VERSION=5.4.83
##                                                        sign off a release: any other version fails (needs the VPN)
##                   make images DISTRO=fedora-44 GCS_VERSION=5.4.83
##                                                        install that version, not the newest
##                   make images REPO=unstable REPO_CONF=pre-stable
##                                                        public unstable packages, repo definitions from pre-stable
##                   make images VERIFY=0                 build only, no checks
##                   make images REPO=pre-stable PROXY=socks5h://127.0.0.1:1080
##                                                        reach the VPN through a SOCKS5 proxy
##                   Images are named gcs-deploy/<distro>:<gcs-version>-<repo>, e.g.
##                   gcs-deploy/ubuntu-26.04:5.4.98-stable, and kept until make clobber.
##                   A pre-release keeps its tag: 5.4.100-rc1 gives 5.4.100-rc1-unstable.
##                   Logs go to build-logs/.
images:
	@./scripts/build $(if $(filter 0,$(VERIFY)),--no-check,) $(if $(filter-out 0,$(REFRESH)),--refresh-base,) \
	    -j $(J) --label images --repo $(REPO) \
	    $(if $(REPO_CONF),--repo-conf $(REPO_CONF),) \
	    $(if $(PROXY),--proxy $(PROXY),) \
	    $(if $(GCS_VERSION),--gcs-version '$(GCS_VERSION)',) \
	    $(if $(EXPECTED_GCS_VERSION),--expect-gcs-version '$(EXPECTED_GCS_VERSION)',) \
	    $(if $(DISTRO),$(DISTRO),--all)

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

## clean             remove build-logs
clean:
	@rm -rf build-logs/

## clobber           clean, plus remove the images we built
##                   never touches base images pulled from Docker Hub, or other images
clobber: clean
	@if ! docker info >/dev/null 2>&1; then \
	    printf 'Docker unavailable — removed generated files only\n'; \
	else \
	    ids=$$(docker images --filter label=gcs-deploy=1 -q | sort -u); \
	    if [ -n "$$ids" ]; then \
	        docker image rm -f $$ids; \
	    else \
	        printf 'no gcs-deploy images to remove\n'; \
	    fi; \
	fi

## help              show this message
help:
	@printf 'Usage: make <target> [VAR=value ...]\n\n'
	@awk '/^## / { line=$$0; sub(/^## /,"  ",line); print line }' Makefile
	@printf '\nVariables:\n'
	@printf '  DISTRO=<name>     distro (check, images: a list, default all; export: one)\n'
	@printf '  REPO=<repo>       stable (default), unstable, testing, pre-stable, pre-unstable, pre-testing\n'
	@printf '  REPO_CONF=<repo>  images, export: where the repo definitions come from (default: REPO)\n'
	@printf '  GCS_VERSION=<v>   images, export: install this GCS version, not the newest\n'
	@printf '  EXPECTED_GCS_VERSION=<v>\n'
	@printf '                    images: fail any image whose GCS version differs\n'
	@printf '  VERIFY=0          images: build only, skip the checks\n'
	@printf '  PROXY=<url>       images: network through a proxy, e.g. socks5h://127.0.0.1:1080\n'
	@printf '  J=<n>             images: concurrent builds (default 4)\n'
	@printf '  REFRESH=1         images: also refresh the base image and distro packages\n'
	@printf '  V=1               check: print every assertion\n\n'
