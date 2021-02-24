FROM ubuntu:20.04

LABEL maintainer="support@globus.org"

RUN \
    apt-get update; \
    apt-get install -y curl gnupg dialog apt-utils sudo psmisc; \
    DEBIAN_FRONTEND="noninteractive" apt-get -y install tzdata; \
    curl -LOs http://downloads.globus.org/toolkit/gt6/stable/installers/repo/deb/globus-toolkit-repo_latest_all.deb; \
    dpkg -i globus-toolkit-repo_latest_all.deb; \
    sed -i /etc/apt/sources.list.d/globus-toolkit-6-stable*.list -e 's/\^# deb /deb /'; \
    sed -i /etc/apt/sources.list.d/globus-connect-server-stable*.list -e 's/^# deb /deb /'; \
    apt-key add /usr/share/globus-toolkit-repo/RPM-GPG-KEY-Globus; \
    apt-get update; \
    apt-get install -y globus-connect-server54

COPY entrypoint.sh /entrypoint.sh

# These are the default ports in use by GCSv5.4. Currently, they can not be changed.
#   443 : HTTPD service for GCS Manager API and HTTPS access to collections
#  50000-51000 : Default port range for incoming data transfer tasks
EXPOSE 443/tcp 50000-51000/tcp

# Default command unless overriden with 'docker run --entrypoint'
ENTRYPOINT ["/entrypoint.sh"]
# Default options to ENTRYPOINT unless overriden with 'docker run arg1...'
CMD []
