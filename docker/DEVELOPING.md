# Developing the GCS Dockerfiles

Dockerfiles for building
[Globus Connect Server 5](https://docs.globus.org/globus-connect-server/) containers
for every supported Linux distribution.

There is one static `Dockerfile.<distro>` per distro. Each has a stage for every
way to set up a Globus repo, so one file builds any repo you ask for. `make export`
writes a copy for one repo, without the stages and arguments the others need; the
default is stable.

Run `make` and the commands below from this directory (`docker/`). The user guide,
[README.md](README.md), uses paths from the top of the repository instead.

## What is where

```
docker-files/
  Dockerfile.<distro>     one per supported distro: the only thing that defines "supported"
  template.Dockerfile     annotated skeleton for a new one
  entrypoint/, systemctl/ the rest of the build context (entrypoints, systemctl mock)
  README.md               how a Dockerfile is laid out, and how to change one
scripts/
  build                   what 'make images' runs: build, name, check
  smoke.sh                what 'build' runs inside each image to check it
  check-*                 what 'make check' runs: the lint and the static checks
  export, resolve         turn a source Dockerfile into one repo
  lib.sh                  shared by the scripts above
Makefile                  the entry points; 'make help' lists them
```

## I want to...

| I want to... | Run |
|---|---|
| check my edit to a Dockerfile or script | `make check` (one distro: `make check DISTRO=fedora-44`) |
| build and verify images | `make images` (see the options below) |
| write a single-repo Dockerfile (stable unless `REPO=` says otherwise) | `make export DISTRO=ubuntu-24.04 > Dockerfile` |
| see which distros exist | `make list` |
| build one by hand, no scripts | `docker build -f docker-files/Dockerfile.ubuntu-22.04 docker-files/` |
| sign off a release | `make images REPO=pre-stable EXPECTED_GCS_VERSION=5.4.83` (needs the VPN) |
| add a distro or change a Dockerfile | [docker-files/README.md](docker-files/README.md) |
| free the disk | `make clean` (logs), `make clobber` (also the images) |

## make images

```sh
make images                                        # every distro, stable, verified
make images DISTRO='fedora-44 sles-15.7' REPO=testing
make images REPO=pre-stable EXPECTED_GCS_VERSION=5.4.83   # sign off a release (needs the VPN)
make images DISTRO=fedora-44 GCS_VERSION=5.4.83    # install that version, not the newest
make images REPO=pre-stable PROXY=socks5h://127.0.0.1:1080   # VPN via a SOCKS5 proxy
make images REPO=unstable REPO_CONF=pre-stable     # public unstable packages, definitions from pre-stable
```

| Variable | Meaning |
|---|---|
| `DISTRO` | space-separated list; default every distro |
| `REPO` | where the packages come from: `stable` (default), `unstable`, `testing`, or the internal `pre-stable`, `pre-unstable`, `pre-testing` (these need the VPN) |
| `REPO_CONF` | where the repo definitions (the `globus-repo` package) come from; the same six values; default: the same as `REPO` |
| `GCS_VERSION` | install exactly this GCS version, as `globus-connect-server --version` prints it (`5.4.99`, `5.4.100-rc1`; `~` instead of `-` is accepted too); default: the newest in the repo |
| `EXPECTED_GCS_VERSION` | the GCS version every image must contain, in the same form (`~` or `-`); an image with any other version fails the build. Defaults to `GCS_VERSION` |
| `VERIFY=0` | build only; skip the checks inside the image |
| `J` | concurrent builds (default 4); downloads are the limit, not CPU |
| `REFRESH=1` | also refresh the base image and the distro's packages |
| `PROXY` | send the build's network traffic through a proxy |
| `V=1` | `make check` only: print every assertion |

**GCS versions.** Without `EXPECTED_GCS_VERSION` or `GCS_VERSION`, `make images` only
warns, and never fails: when the images it built have different GCS versions, and when an
image is older than the newest version the repo publishes (read from the repo's deb index,
so a single-distro build is covered too; if it cannot be read, say without the VPN for a
`pre-` repo, the report says so). With either one set, a wrong version is an error, with or
without `VERIFY=0`.

`REPO` and `REPO_CONF` are separate because a new distro, or a new signing key, can
appear in a `pre-` repo's `globus-repo` package before the public one. Then
`REPO_CONF=pre-stable` takes the definitions from there while `REPO` still picks the
packages. A `pre-` `REPO` always points its repo at `builds.globus.org`; a public one
never does. Anything `pre-` needs the VPN, whichever variable it is in.

`PROXY` runs the builds with `--network=host` and passes the proxy to the build as
Docker's standard proxy build args (`ALL_PROXY`, `HTTP_PROXY`, `HTTPS_PROXY` and the
lower-case forms), so every package download goes through it. Use `socks5h://` so
the proxy resolves DNS.

**When an image passes.** `docker build` succeeds, and `scripts/smoke.sh` finds the
image correct inside: GCS installed, the systemctl mock working, the entrypoint and
both service drop-ins present and readable by the mock, and exactly the intended Globus
repo enabled. It does not start any service; only running the container does that.

**Notes.** The build log is only scanned for things that fail nothing yet but need
attention later, such as an expired signing key or a failed SELinux module. They are
listed at the end of the run and never change a result. To watch for something new,
add a `_note_def` line to `scripts/build`. A Dockerfile step that needs to say
something (a package borrowed from another distro) prints a `GCS-DEPLOY-NOTICE:` line
instead; the report repeats it (see `docker-files/README.md`).

**Image names.** Each image is named after the GCS version it contains:

| Tag | Meaning |
|---|---|
| `gcs-deploy/<distro>:5.4.98-stable` | this version, from this repo |
| `gcs-deploy/<distro>:stable` | the latest build of that repo |

A pre-release keeps its tag: `5.4.100-rc1` (as `--version` prints it) is tagged
`5.4.100-rc1-unstable`. The label keeps the exact version:
`docker inspect -f '{{index .Config.Labels "gcs-deploy.version"}}' <image>`.
`REPO_CONF` is not in the tag, only in the `gcs-deploy.repo-conf` label, so
`REPO=unstable REPO_CONF=pre-stable` reuses the tag of a plain `unstable` build.
These `gcs-deploy/` names are for checking images; the user guide tags the image it
builds `globus/globus-connect-server:<distro>`.

Images stay until `make clobber`. Logs are in `build-logs/images/<distro>-<repo>/`;
each run deletes the previous run's logs. The build prints a line as each image starts
and finishes, plus a live counter on a terminal.

## Build arguments

Args starting with `_` are the Dockerfile's own plumbing, set by `scripts/build`; the
others are the settings you choose.

| Arg | Default | What it does |
|---|---|---|
| `REPO` | `stable` | which GCS repo to install from |
| `REPO_CONF` | (the value of `REPO`) | which repo's `globus-repo` package supplies the repo definitions |
| `_REPO_STAGE` | `other` | which repo stage of the Dockerfile runs: `stable` is the plain one, `other` handles everything else. `scripts/build` sets it, and `make export` removes it; you only need it by hand to build the plain stage |
| `GCS_PACKAGE` | `globus-connect-server54` | the package the install step installs |
| `GCS_VERSION` | (empty: the newest) | install exactly this GCS version, e.g. `5.4.99` |
| `_CACHEBUST` | `0` | the cache barrier: everything of ours below it (the systemctl mock, the Globus repo, the GCS install, the entrypoint files) is rebuilt; pass a new value on every build |
| `_BASE_CACHEBUST` | `0` | invalidates the distro package update and everything below it; use with `docker build --pull` |

`--pull` and `_BASE_CACHEBUST` do different jobs and are usually wanted together.
`--pull` re-resolves the base image tag. `_BASE_CACHEBUST` re-runs the distro update
even when the base image has not changed, which is the common case: Docker Hub
images are rebuilt far less often than the distros publish updates.

```sh
# Normal build: distro layers cached, everything of ours rebuilt
docker build --build-arg _CACHEBUST="$(date +%s)" -f docker-files/Dockerfile.ubuntu-22.04 docker-files/

# Also refresh the base image and its packages
docker build --pull \
  --build-arg _BASE_CACHEBUST="$(date +%s)" \
  --build-arg _CACHEBUST="$(date +%s)" \
  -f docker-files/Dockerfile.ubuntu-22.04 docker-files/

# Another repo
docker build -f docker-files/Dockerfile.rockylinux-9 --build-arg REPO=pre-stable docker-files/
```

**A shell instead of GCS.** The image starts GCS through its entrypoint, which needs
the deployment key. To look around without starting anything, replace the entrypoint:

```sh
docker run -it --entrypoint /bin/bash gcs-deploy/ubuntu-24.04:stable
```

## Reading the scripts

Each script starts with a comment that says what it is for and how to run it. They
are small. `scripts/lib.sh` is where the list of distros comes from: the Dockerfiles
themselves.
