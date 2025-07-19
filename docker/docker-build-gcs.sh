#!/usr/bin/bash

set -e
#set -x

DISTRO=$1

if [ -z $DISTRO ] || [ ! -f docker-files/templates/$DISTRO ]; then
    echo "Usage: $0 <distro>"
    echo "Supported distros are:"
    ls docker-files/templates/
    exit 1
fi

if [ ! -f docker-files/Dockerfile.$DISTRO ]; then
    (cd docker-files; make docker-files)
fi

docker_build_args=""

# Environment variable that tells Ansible which GCS repository to use.
# Values: stable | unstable | testing | pre-stable
# Default: stable
if [ -n "${GCS_REPO}" ]
then
    docker_build_args="${docker_build_args} --build-arg=GCS_REPO=${GCS_REPO}"
fi

# GCS_PROXY=HOST:PORT of socks5 PROXY
# Typically used for the pre-stable repository for pre-release testing.
if [ -n "${GCS_PROXY}" ]
then
    docker_build_args="${docker_build_args} --build-arg=GCS_PROXY=${GCS_PROXY}"
fi

UNVERSIONED_TAG="globus/globus-connect-server:${DISTRO}"
docker build \
    --progress plain \
    --tag $UNVERSIONED_TAG \
    ${docker_build_args} \
    --build-arg CACHEBUST=$(date +%s) \
    - < docker-files/Dockerfile.$DISTRO


# Get the version of GCS installed in this image
version=$(
    docker run \
        -it --rm \
        --entrypoint /usr/sbin/globus-connect-server \
        $UNVERSIONED_TAG \
        --version |
    awk '{print $3}' | sed 's/,//g')

VERSIONED_TAG="${UNVERSIONED_TAG}-${version}"

docker tag $UNVERSIONED_TAG $VERSIONED_TAG
