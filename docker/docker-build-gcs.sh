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

UNVERSIONED_TAG="globus/globus-connect-server:${DISTRO}"
docker build \
    --progress plain \
    --tag $UNVERSIONED_TAG \
    --build-arg="GLOBUS_ANSIBLE_OPTIONS=${GLOBUS_ANSIBLE_OPTIONS}" \
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
