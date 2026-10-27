# Template for a new distro's Dockerfile.  Not built or checked by anything.
# Easier in practice: copy the closest sibling (same family) to
# Dockerfile.<distro> and change the FROM line and the family header.
#
# Replace everything in <angle brackets>.  The commands depend on the family:
# each real Dockerfile of that family has the exact line to copy.  The comments
# below are the ones every real file carries; keep them.  A distro with no Docker
# Hub image (centos, springdale) also starts with '# syntax=docker/dockerfile:1',
# for the COPY <<EOF heredocs its bootstrap stage uses; copy that sibling.
#
# --- the file starts here ---------------------------------------------

# family: <deb | el | fedora | suse>

############################################################################
# LAYOUT
#
# The stages, top to bottom.  Details: docker-files/README.md.
#
#   base               the starting image   (differs per distro)
#   pre-repo           distro update, systemd guard, CACHE BARRIER, systemctl mock
#   repo-stable        sets up the stable repo     \ one of the two is built, chosen
#   repo-other         sets up any other repo      / by ARG _REPO_STAGE
#   install            installs ${GCS_PACKAGE} from that repo
#   final              deployment files, ports, entrypoint  (the image users run)
#
# Each stage is a banner, saying what the stage is for, then its FROM line.
# This ARG is read by FROM lines, so it must sit above the first one.
# scripts/build sets _REPO_STAGE (stable for a default build, other for the
# rest); make export removes it.  ARG REPO and ARG REPO_CONF belong to
# repo-other.
############################################################################
ARG _REPO_STAGE=other

############################################################################
# STAGE: base
#
# The starting image.
# A distro with no Docker Hub image bootstraps a root filesystem in a stage ABOVE
# this one (see Dockerfile.centos-9); everything from here down is unchanged.
############################################################################
FROM <base-image> AS base

############################################################################
# STAGE: pre-repo
#
# Distro layers, before any Globus content; shared by every repo.  In order:
#   1. update the distro packages   2. install python3 + systemd
#   3. guard systemctl              4. cache barrier   5. install the systemctl mock
############################################################################
FROM base AS pre-repo

# --- 1. Distro package update -----------------------------------------
# Docker Hub images lag the distro's security updates, sometimes by months.
# _BASE_CACHEBUST re-runs this step (use it with 'docker build --pull').
ARG _BASE_CACHEBUST=0
RUN echo "_BASE_CACHEBUST=${_BASE_CACHEBUST}" \
 && <update every installed package>

# --- 2. systemctl mock prerequisites ----------------------------------
# Installed now, before step 3 stops package updates from replacing /bin/systemctl.
RUN <install python3 and systemd>

# --- 3. Protect /bin/systemctl from package updates -------------------
# <how this family stops package updates from replacing /bin/systemctl>, so
# installing or upgrading systemd leaves our mock (step 5) in place.
RUN <guard /bin/systemctl>

# --- 4. CACHE BARRIER -------------------------------------------------
# Above: distro-provided, safe to cache.  Below: ours and Globus's, never cached.
# _CACHEBUST changes on every build, so every layer from here down always runs.
# The echo is deliberate: the build log shows whether this layer ran or was CACHED.
# To iterate with everything cached, pass a fixed --build-arg _CACHEBUST=<value>.
ARG _CACHEBUST=0
RUN echo "_CACHEBUST=${_CACHEBUST}"

# --- 5. Install systemctl mock ----------------------------------------
# Must be in place before GCS so the mock answers the systemctl calls the
# package's install scripts make.
COPY systemctl/systemctl_mock.py /gcs-deploy/systemctl-mock
RUN chmod +x /gcs-deploy/systemctl-mock \
 && ln -sf /gcs-deploy/systemctl-mock /bin/systemctl

############################################################################
# STAGE: repo-stable
#
# Sets up the stable GCS package repository.  GCS itself is installed
# later, in stage install.
############################################################################
FROM pre-repo AS repo-stable

# --- Prerequisites (deb, suse) ----------------------------------------
RUN <install curl>

# --- Globus repository ------------------------------------------------
RUN <install the stable repo definition; deb and suse also refresh the index>

############################################################################
# STAGE: repo-other
#
# Sets up every repo that repo-stable does not: unstable, testing, the
# internal pre-stable, pre-unstable and pre-testing (they need the Globus
# VPN), or stable with its definitions taken from somewhere else.  A default
# build uses repo-stable, which is all that make export keeps for one.  Every
# combination here is one piece of shell, so this stage is busier.
#
# Two settings drive it.  REPO is the repo the packages come from.
# REPO_CONF is the repo whose globus-repo package supplies the definitions
# (the signing key and one stanza per repo); empty means the same as REPO.
# They differ when a new distro or key is only in a pre- repo's package:
# REPO=unstable REPO_CONF=pre-stable.  A pre- REPO derives its stanza from
# the public one with builds.globus.org/ in front of the URL, whatever
# REPO_CONF is.
#
# In order: 1. prerequisites (deb, suse), 2. install globus-repo, 3. switch to REPO.
# Step 3 disables the stable repo before it refreshes anything, so a
# non-stable build never reads the stable index.  The ARGs below are read
# only here.
############################################################################
FROM pre-repo AS repo-other

ARG REPO=stable
ARG REPO_CONF=

# --- 1. Prerequisites (deb, suse) -------------------------------------
RUN <install curl>

# --- 2. Globus repository ---------------------------------------------
# Turn REPO_CONF (default: REPO) into a download URL and install the package from
# it.  The shell for that is the same in every file; copy it from a sibling.
RUN <download and install the globus-repo package; refresh nothing>

# --- 3. Switch to REPO ------------------------------------------------
# Copy this step from a sibling too.  It enables the repo REPO names, deriving a
# pre- stanza from the public one with the builds.globus.org prefix, and disables
# stable first.  deb and suse then refresh the index.
RUN <switch to REPO>

############################################################################
# STAGE: install
#
# Installs GCS from the selected repo.
############################################################################
FROM repo-${_REPO_STAGE} AS install

# GCS_VERSION pins the GCS version, as 'globus-connect-server --version' prints
# it (5.4.99, 5.4.100-rc1).  Empty installs the newest in the repo.  The packages
# spell a pre-release 5.4.100~rc1, which is what the tr in the install step is for.
ARG GCS_PACKAGE=globus-connect-server54
ARG GCS_VERSION=

# --- Install GCS ------------------------------------------------------
# If a dependency has to come from another distro's repo, this RUN also prints
# 'GCS-DEPLOY-NOTICE: <what comes from where, and why>'; see
# docker-files/README.md, "Notices".
RUN <install ${GCS_PACKAGE}, pinned to ${GCS_VERSION} when it is set: copy from a sibling>

############################################################################
# STAGE: final
#
# The image users run: GCS installed, deployment files, ports, entrypoint.
# For a shell instead of GCS: docker run -it --entrypoint /bin/bash <image>
############################################################################
FROM install AS final

# --- GCS deployment files ---------------------------------------------
COPY entrypoint/entrypoint.sh /gcs-deploy/entrypoint.sh
COPY entrypoint/gcs_manager.service.d/ /gcs-deploy/gcs_manager.service.d/
COPY entrypoint/globus-oidc.service.d/ /gcs-deploy/globus-oidc.service.d/
RUN chmod +x /gcs-deploy/entrypoint.sh \
 && mkdir -p /etc/systemd/system \
 && ln -sf /gcs-deploy/gcs_manager.service.d \
           /etc/systemd/system/gcs_manager.service.d \
 && ln -sf /gcs-deploy/globus-oidc.service.d \
           /etc/systemd/system/globus-oidc.service.d

# 443        : GCS Manager API + HTTPS collection access
# 50000-51000: Default inbound data transfer port range
EXPOSE 443/tcp 50000-51000/tcp

ENTRYPOINT ["/gcs-deploy/entrypoint.sh"]
