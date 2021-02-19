FROM ubuntu:20.04

LABEL maintainer="support@globus.org"

RUN \
    apt-get update; \
    apt-get install -y curl gnupg dialog apt-utils; \
    DEBIAN_FRONTEND="noninteractive" apt-get -y install tzdata; \
    curl -LOs http://downloads.globus.org/toolkit/gt6/stable/installers/repo/deb/globus-toolkit-repo_latest_all.deb; \
    dpkg -i globus-toolkit-repo_latest_all.deb; \
    sed -i /etc/apt/sources.list.d/globus-toolkit-6-stable*.list -e 's/\^# deb /deb /'; \
    sed -i /etc/apt/sources.list.d/globus-connect-server-stable*.list -e 's/^# deb /deb /'; \
    apt-key add /usr/share/globus-toolkit-repo/RPM-GPG-KEY-Globus; \
    apt-get update; \
    apt-get install -y globus-connect-server54
