# docker-files/

One static `Dockerfile.<distro>` per supported distro, plus the build context they
share. Edit them directly; nothing is generated except the single-repo form
(`make export`).

```
docker-files/
  Dockerfile.<distro>      one per distro
  template.Dockerfile      annotated skeleton for a new one (not built or checked)
  systemctl/               systemctl mock       } with the Dockerfiles, the build
  entrypoint/              entrypoint scripts   } context they all COPY from
                           and service drop-ins
```

## How a Dockerfile is laid out

Every Dockerfile is the same sequence of **stages**. A stage is one `FROM ... AS name`
and everything under it. Each stage starts with a banner comment saying what it is
for; its `FROM` line follows directly. (A file also has a **family**, `deb`, `el`,
`fedora` or `suse`, named in its first lines; it decides which package-manager
commands the file uses. See "Families".)

```
############################################################################
# STAGE: pre-repo
#
# What this stage is for, in a line or two.
############################################################################
FROM base AS pre-repo
```

The comment block directly above a `FROM` always belongs to that stage (`make export`
drops them together).

```
                      +--> repo-stable --+
  base --> pre-repo --+                  +--> install --> final
  (image)  (distro    +--> repo-other  --+    (GCS)         (deployment files,
            layers)    one of the two,                       ports, entrypoint)
                       chosen by _REPO_STAGE

  The last stage, final, is what gets built.
```

Read a file top to bottom with this table beside it:

| Stage | What it does | Differs between files? |
|---|---|---|
| (header) | `# family:` and the layout map, then `ARG _REPO_STAGE` | no (family aside) |
| `base` | the starting image | **yes**: the one line you change for a new distro |
| `pre-repo` | 1. distro update, 2. python3 + systemd, 3. systemd guard, 4. cache barrier, 5. systemctl mock | by family |
| `repo-stable` | the plain stable setup: install the Globus repo definition (deb and suse install curl first and also refresh the index). **This is all `make export` keeps for a default build** | by family |
| `repo-other` | every other repo: unstable, testing, `pre-stable`, `pre-unstable`, `pre-testing`, or stable with its definitions from elsewhere. One piece of shell driven by `REPO` and `REPO_CONF`: 1. prerequisites (deb, suse only), 2. install `globus-repo`, 3. switch to `REPO` (stable disabled before any index refresh) | by family |
| `install` | `FROM repo-${_REPO_STAGE}`, the chosen repo stage; installs `${GCS_PACKAGE}` | by family |
| `final` | deployment files, ports, entrypoint: the image users run | no |

BuildKit builds only the stages on the path from the last stage back to `base`, so the
repo stage you did not pick costs nothing. Inside a stage, sections are headed
`# --- Title ---...` (lighter, so the stages stand out); in `pre-repo` and `repo-other` they are numbered, because their order matters.

`scripts/check-dockerfiles` verifies this structure, including that each stage's banner sits directly above its `FROM`; `scripts/check-content` verifies
what is in each stage.

### Two ordering rules that are load-bearing

- **The systemd guard (3) comes before the systemctl mock (5).** The guard (`dpkg-divert`,
  `excludepkgs=systemd`, or `zypper addlock`, by family) has to be applied to the
  real `systemctl` before the mock replaces it.
- **The mock comes before the repo.** The `globus-repo` package and GCS's own install
  scripts (`%post` in an rpm, `postinst` in a deb) call `systemctl`, and must hit the mock.

### The cache barrier

`ARG _CACHEBUST` (step 4 of `pre-repo`) splits the file. Above it is distro-provided and
cacheable; below it is ours and Globus's, and must never come from cache. Pass a new
`_CACHEBUST` value on every build. `_BASE_CACHEBUST` (step 1) re-runs the distro update
without a full `--no-cache`; use it together with `docker build --pull`.

### Build args

| Arg | Values | Default | |
|---|---|---|---|
| `_REPO_STAGE` | `stable`, `other` | `other` | which repo stage to build; `scripts/build` sets it and `make export` removes it, so you rarely set it |
| `REPO` | `stable`, `unstable`, `testing`, `pre-stable`, `pre-unstable`, `pre-testing` | `stable` | which GCS repo to install from (read by `repo-other`); `pre-` repos are internal and need the VPN |
| `REPO_CONF` | the same six | the value of `REPO` | where the `globus-repo` package (the repo definitions) comes from (read by `repo-other`) |
| `GCS_PACKAGE` | package name | `globus-connect-server54` | what the install step installs |
| `GCS_VERSION` | e.g. `5.4.99`, `5.4.100-rc1` | empty: the newest | pins the GCS version the install step installs; apt needs the full version with its revision, so deb files look it up in the index first; the packages spell a pre-release with `~` and `--version` with `-`; either is accepted and the install step converts |
| `_CACHEBUST` | any value | `0` | pass a new value on every build |
| `_BASE_CACHEBUST` | any value | `0` | re-runs the distro update |

An ARG starting with `_` is the Dockerfile's own plumbing, set by `scripts/build`;
the others are the settings you choose.

`_REPO_STAGE` is declared above the first `FROM`, because a `FROM` line reads
it; `make export` fills it in. `REPO` and `REPO_CONF` are declared in `repo-other`,
the only stage that reads them. `_REPO_STAGE` is `stable` for a default build (`REPO`
stable, definitions from stable too) and `other` for anything else, and the default
is `other` so a plain `docker build --build-arg REPO=unstable ...` works.

**`REPO` and `REPO_CONF` are separate on purpose.** `REPO` says where the packages
come from, `REPO_CONF` where the repo definitions come from. Usually they are the
same. They differ when a new distro or signing key is only in a `pre-` repo's
`globus-repo` package: `REPO=unstable REPO_CONF=pre-stable` takes the definitions
from there and the packages from public unstable. A `pre-` `REPO` rewrites its
stanza's URLs to `builds.globus.org/...` whatever `REPO_CONF` is; a public `REPO`
never does. Anything `pre-` needs the VPN, in either variable.

## Where do I change...

| I want to... | Edit |
|---|---|
| add a package every image needs | `pre-repo` step 2 (before the guard), or `install` if it needs the Globus repo |
| change how the stable repo is set up | `repo-stable` **and** `repo-other` step 2 and 3, which cover stable with `REPO_CONF` set |
| change how any other repo is set up, or where its definitions come from | `repo-other`: steps 2 and 3 |
| change what the user's image contains | `final` |
| change ports, entrypoint, service drop-ins | `final` and `entrypoint/` |
| support a new distro | copy the closest sibling, see below |
| understand why a file differs from its family | "Known differences", below |

Most changes apply to every file of a family, so make the edit in each (`sed` over
`Dockerfile.*` works), then `make check`. Nothing flags a file you missed: grep for the
old text afterwards, and build one distro from each family:
`make images DISTRO='ubuntu-24.04 rockylinux-9 fedora-44 sles-15.7'`.

Consistency is not correctness: the files can all be wrong in the same way. The image
builds (`make images`) are what prove a change works.

## Notices: packages from another distro

A step that takes a package from another distro's repo (libnice from openSUSE Leap
on SLES, from AlmaLinux on redhat-8, and so on) must say so in the build output:

```
RUN echo "GCS-DEPLOY-NOTICE: libnice, a GCS dependency, comes from ..." \
 && dnf install -y --repofrompath=... libnice
```

`make images` repeats each notice in its report, so whoever reads the results
knows the image is not a clean test of that distro. The wording lives in the
step it describes, so that whoever changes the step sees it: when you change the
step, change the notice. `check-dockerfiles` fails a file that adds a repo
(`add-repo`, `addrepo`, `zypper ar`, `repofrompath`) and prints no notice on a line
that runs.

## Families

Files in a family are the same apart from the base image and a few known one-offs.
`# family:` decides which commands the checks expect.

| Family | Distros | Package manager |
|---|---|---|
| `deb` | ubuntu, debian | apt |
| `el` | almalinux, rockylinux, oraclelinux, centos, redhat, springdale | dnf |
| `fedora` | fedora | dnf (shares EL's install and update steps) |
| `suse` | sles, opensuse | zypper |

### Known differences within a family

Everything else in a family should be identical. These differences are on purpose,
and each one has a comment in its file:

- **almalinux-8, oraclelinux-8, redhat-8, rockylinux-8, springdale-8**: `selinux-policy-targeted` is installed in the same transaction as GCS, so the solver cannot pick a policy with no targeted store.
- **redhat-8**: libnice is not in EPEL 8 or UBI 8, so it comes from AlmaLinux 8 AppStream before GCS.
- **springdale-9**: Springdale 9's selinux-policy is older than GCS needs, so it is upgraded from AlmaLinux 9 BaseOS first.
- **sles-15.7, sles-16.0**: libnice is not in the SLES BCI repos, so GCS is installed with the openSUSE Leap OSS repo as a libnice source.
- **sles-16.0, opensuse-16.0**: python313 instead of python311, and `selinux-policy-targeted` installed in a step of its own before GCS. opensuse-16.0 also installs GCS plainly, with no libnice workaround.
- **centos, springdale**: bootstrapped from a scratch root (next section). Their first line is `# syntax=docker/dockerfile:1`, which the `COPY <<EOF` heredocs of the bootstrap need. centos-10 also installs `gzip` there.

## Distros with no Docker Hub image

centos and springdale build their own root filesystem in a `bootstrap` stage **above**
`base`, then copy it into `FROM scratch AS base`. From `FROM base AS pre-repo` down they look
like any other EL file. Those bootstrap stages are always kept, whatever you export.

## What `make export` writes

The source file holds every repo so it can be built any way (`REPO`, `REPO_CONF`).
`make export` writes the Dockerfile for one repo: it keeps only the stages that build
would use and fills in the `FROM repo-${_REPO_STAGE}` selector. It drops
`ARG _REPO_STAGE` together with the layout map above it. For the default (stable)
the stages are `base`, `pre-repo`,
`repo-stable`, `install`, `final`, and nothing in it mentions repos or `REPO_CONF` (`scripts/check-dockerfiles`
asserts that). Any other repo, or `REPO_CONF`, keeps `repo-other` instead, with the
`ARG REPO` and `ARG REPO_CONF` it declares set to the chosen values.

A plain `docker build` of a source file, as the user guide describes, runs
`repo-other` with `REPO=stable` (`_REPO_STAGE` defaults to `other`), not
`repo-stable`. `make images` sets `_REPO_STAGE=stable` for a default build, so it
does build `repo-stable`, but from the source file: no image build covers the
exported file itself. `check-syntax` lints it and `check-dockerfiles` checks its stages.
