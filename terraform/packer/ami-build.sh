#!/usr/bin/env bash

export DEBIAN_FRONTEND=noninteractive

function apt() {
  apt-get -y -qq -o=Dpkg::Use-Pty=0 -o=DPkg::Lock::Timeout=60 "$@"
}

function logger() {
  printf "[%s] [INFO] %s\n" "$(date +'%F %T')" "${1}"
}

function main() {
  apt update

  logger "Install awscli"
  apt install unzip
  curl -fsSL -o /tmp/awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
  unzip -qd /tmp /tmp/awscli.zip
  /tmp/aws/install
  rm -r /tmp/aws && rm -f /tmp/awscli.zip

  logger "Installing GCS Repo"
  curl -LOs https://downloads.globus.org/globus-connect-server/stable/installers/repo/deb/globus-repo_latest_all.deb
  dpkg -i globus-repo_latest_all.deb
  apt update

  logger "Installing Packages"
  apt install globus-connect-server54 jq sqlite3
}

main