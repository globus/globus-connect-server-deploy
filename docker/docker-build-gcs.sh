#!/usr/bin/bash

set -e
#set -x

BASE_IMAGE=$1
[ -n "$BASE_IMAGE" ] || (echo "Usage: $0 <base_image>" && exit 1)

ANSIBLE_ROLES_DIR="$(realpath $(dirname ${BASH_SOURCE})/../ansible/roles)"

TMP_IMAGE_PREFIX="globus/tmp/${BASE_IMAGE//:/-}"
ANSIBLE_IMAGE_NAME="globus/tmp/ansible"
FINAL_IMAGE_NAME="globus/globus-connect-server:${BASE_IMAGE//:/-}"
TMP_CONTAINER_NAME="globus-tmp-${BASE_IMAGE//:/-}.install_gcs.$$"

DISTROS_YAML="$(realpath $(dirname ${BASH_SOURCE})/data/distros.yaml)"
SHYAML="$(realpath $(dirname ${BASH_SOURCE})/venv/bin/shyaml)"
DOCKER=docker

################################################################################
################################################################################

# Like normal realpath but uses cygpath if it is available.
_realpath() {
    path=$1

    path=$(realpath $path)
    type cygpath > /dev/null 2>&1 && path=$(cygpath -w $path)

    echo $path
}

################################################################################
################################################################################

_shyaml() {
    ${SHYAML} $* < "${DISTROS_YAML}"
}

find_shyaml() {
    local shyaml=$(type shyaml 2> /dev/null)

    # Use the version we installed in a previous run, if it exists
    [[ -e ${SHYAML} ]] && return 0

    # Use the local version when available
    if [ -n "${shyaml}" ]; then
        SHYAML="${shyaml}"
        return
    fi

    # Install shyaml
    type python3 > /dev/null 2>&1 || (echo "python3 not installed." && exit 1)
    python3 -m venv $(dirname ${BASH_SOURCE})/venv
    $(dirname ${BASH_SOURCE})/venv/bin/pip install --upgrade pip
    $(dirname ${BASH_SOURCE})/venv/bin/pip install shyaml
}

key_exists() {
    local path=$1
    local key=$2

    ${SHYAML} keys ${path} < ${DISTROS_YAML} 2> /dev/null | grep "^${key}$" > /dev/null
}

find_key_by_tag() {
    local tag=$1
    # $2 is the return value for the value of key

    for _key in $(_shyaml keys); do
        if key_exists ${_key}.tags ${tag}; then
            eval "$2=\"${_key}\""
            return
        fi
    done
}

find_image_from_tag() {
    local key=$1
    local tag=$2
    # $3 is the return value for the image

    # Escape '.' in tag names for use in shyaml look ups
    local _tag=${tag//\./\\.}

    if key_exists ${key}.tags.${_tag} 'alias'; then
        find_image_from_tag ${key} $(_shyaml get-value ${key}.tags.${_tag}.alias) $3
        return
    fi

    if key_exists ${key}.tags.${_tag} 'image'; then
        eval "$3=\"$(_shyaml get-value ${key}.tags.${_tag}.image)\""
        return
    fi

    eval "$3=\"${tag}\""
}

find_var_from_tag() {
    local key=$1
    local tag=$2
    local var=$3
    # $4 is the returned value for var

    # Escape '.' in tag names
    local _tag=${tag//\./\\.}

    if key_exists ${key}.tags.${_tag}.vars "${var}"; then
        eval "$4=\"$(_shyaml get-value ${key}.tags.${_tag}.vars.${var})\""
        return
    fi

    if key_exists ${key}.tags.${_tag} 'alias'; then
        find_var_from_tag ${key} $(_shyaml get-value ${key}.tags.${_tag}.alias) ${var} $4
        return
    fi

    echo "${var} missing from ${key}.tags.${tag}.vars. Exitting."
    exit 1
}

################################################################################
################################################################################

process_stage() {
    local key=$1
    local tag=$2
    local stage_index=$3
    local base_image=$4
    # $5 is the return value for the new image

    local docker_build_cmd=""
    for k in $(_shyaml keys ${key}.stages.${stage_index}); do
        process_$k ${key}.stages.${stage_index}.$k docker_build_cmd base_image
    done

    # Perform any vars substitutions
    if key_exists ${key}.stages.${stage_index} 'replace'; then
        for v in $(_shyaml get-values ${key}.stages.${stage_index}.replace); do
            find_var_from_tag ${key} ${tag} $v value
            docker_build_cmd=${docker_build_cmd//%${v}%//${value}}
        done
    fi

    local _new_tag="${TMP_IMAGE_PREFIX}.stage.${stage_index}"

    eval ${DOCKER} build \
      --progress plain \
      $docker_build_cmd \
      --build-arg "BASE_IMAGE=${base_image}" \
      --tag "${_new_tag}" .

    eval "$5=\"${_new_tag}\""
}

# Called from process_stage()
process_replace() {
    :
}

# Called from process_stage()
process_dockerfile() {
    # $2 is return value for the docker build command line
    local key=$1

    eval "$2+=\"-f $(_shyaml get-value ${key}) \""
}

# Called from process_stage()
process_vars() {
    local key=$1
    # $2 is return value for the docker build command line
    # $3 is return value for the base image (if any)

    for k in $(_shyaml keys ${key}); do
        value=$(_shyaml get-value ${key}.$k)
        if [ "$k" == "BASE_IMAGE" ]; then
            eval "$3=${value}"
        else
            eval "$2+=\"--build-arg \\\"$k=${value}\\\" \""
        fi
    done
}

process_stages() {
    local key=$1
    local tag=$2
    local image=$3
    # $4 is return value for the new image

    num_stages=$(_shyaml get-length ${key}.stages)
    for i in $(seq 1 $num_stages); do
        process_stage "${key}" "${tag}" $(( i-1 )) "${image}" image
    done

    eval "$4=\"${image}\""
}

################################################################################
################################################################################

build_ansible_image() {

    ${DOCKER} build \
        --progress plain \
        --build-arg "BASE_IMAGE=fedora:37" \
        -f data/Dockerfile.ansible \
        --tag "${ANSIBLE_IMAGE_NAME}" \
        .
}

launch_install_target() {
    local image=$1
    local name=$2

    # Run for upto 10 mins then timeout and exit
    ${DOCKER} run \
        --rm --detach \
        --name ${name} \
        ${image} \
        /bin/bash -c "
            for i in \$(seq 0 600); do
                if [ -f /done ]; then
                    break
                fi
                sleep 1
            done
            rm -f /done"
}

install_gcs_on_target() {
    local target=$1

    # We launch the ansible container with the local Ansible roles directory mounted
    # and access to our docker service so that the Ansible container can connect to
    # the target container and run the installation.
    ${DOCKER} run \
        -i --rm \
        --workdir /ansible \
        --volume //var/run/docker.sock:/var/run/docker.sock \
        --volume $(_realpath ${ANSIBLE_ROLES_DIR}):/ansible/roles:ro \
        --env "VENV=/venv" \
        "${ANSIBLE_IMAGE_NAME}" \
        /venv/bin/ansible-playbook \
            --connection=community.docker.docker \
            --inventory=${target}, \
            --user=root \
            playbook.yml \
            ${GLOBUS_ANSIBLE_OPTIONS};
}

stop_install_target() {
    local tag=$1

    ${DOCKER} exec ${tag} /bin/touch /done
}

commit_new_gcs_image() {
    local container=$1
    local tag=$2

    ${DOCKER} commit ${container} "${tag}"
}

install_gcs() {
    local image=$1
    # $2 is the return value for the new image

    local tag="${TMP_IMAGE_PREFIX}.gcs"

    build_ansible_image
    launch_install_target ${image} ${TMP_CONTAINER_NAME}
    install_gcs_on_target ${TMP_CONTAINER_NAME}
    commit_new_gcs_image ${TMP_CONTAINER_NAME} ${tag}
    stop_install_target ${TMP_CONTAINER_NAME}

    eval "$2=\"${tag}\""
}

################################################################################
################################################################################

finalize_image() {
    local image=$1
    # $2 is the return value for the new image

    # Get the version of GCS installed in this image
    local version=$(
        ${DOCKER} run \
            -it --rm \
            ${target_build_image} \
            /usr/sbin/globus-connect-server --version |
        awk '{print $3}' | sed 's/,//g')

    local tag="${FINAL_IMAGE_NAME}-${version}"

    ${DOCKER} build \
        --progress plain \
        --build-arg "BASE_IMAGE=${image}" \
        -f data/Dockerfile.gcs \
        --tag ${tag} \
        .

    eval "$2=\"${tag}\""
}

################################################################################
################################################################################

# Make sure we have the commands we'll need
find_shyaml
type docker > /dev/null 2>&1 || (echo "docker not installed." && exit 1)

# Start by looking up BASE_IMAGE under 'tags:' in the distro.yaml file and
# return the top-level key which may have build instructions.
key=
tag=${BASE_IMAGE}

find_key_by_tag ${tag} key

# We'll make several different layers during this process. This variable will
# track the most recent layer.
target_build_image=${tag}

if [[ -n "$key" ]]; then
    # Resolve any aliases
    find_image_from_tag ${key} ${tag} target_build_image

    # Process any instructions necessary for the base image before we move onto
    # installing GCS.
    if key_exists "${key}" stages; then
        process_stages "${key}" "${tag}" ${target_build_image} target_build_image
    fi
fi

install_gcs "${target_build_image}" target_build_image
finalize_image "${target_build_image}" target_build_image

echo The final image is ${target_build_image}

