DISTROS=\
    almalinux:8 \
    almalinux:9 \
    centos:7 \
    centos:8 \
    centos:9 \
    debian:10 \
    debian:11 \
    fedora:35 \
    fedora:36 \
    fedora:37 \
    oraclelinux:7 \
    oraclelinux:8 \
    oraclelinux:9 \
    redhat:7 \
    redhat:8 \
    redhat:9 \
    rockylinux:8 \
    rockylinux:9 \
    springdale:8 \
    springdale:9 \
    ubuntu:bionic \
    ubuntu:focal \
    ubuntu:jammy \
    ubuntu:kinetic

all:
	for d in $(DISTROS); do\
	    (cd ../docker; ./docker-build-gcs.sh $$d) | tee $$d.log;\
	done

%:
	(cd ../docker; ./docker-build-gcs.sh $@) | tee $@.log;\
