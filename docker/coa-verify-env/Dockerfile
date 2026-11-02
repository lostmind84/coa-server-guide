# coa-verify-env: the toolchain `tools/verify_all.py` (in the CoA server repository) needs to configure, build
# and test the server, packaged as a versioned image instead of an unversioned image built by hand on one
# workstation. See docs/tooling/verify-container.md for how to build and use it, and
# docs/adr/0018-verify-inside-a-versioned-container-image.md for why.
#
# Build:
#   docker build -t coa-verify-env:24.04 -f docker/coa-verify-env/Dockerfile docker/coa-verify-env
#
# This reproduces, package for package, the ad hoc image already in use on at least one workstation (recovered
# with `docker history --no-trunc coa-verify-env:24.04` on 2026-11-02): same base image, same env, same apt
# package list and order, same symlink. Any future change to this file is a new decision, not a silent drift
# from that baseline.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ccache libtool cmake-data ninja-build cmake clang git lsb-base curl unzip \
    default-mysql-client openssl default-libmysqlclient-dev libboost-all-dev libssl-dev libmysql++-dev \
    libreadline-dev zlib1g-dev libbz2-dev libncurses5-dev liblzma-dev python3 ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/python3 /usr/local/bin/python
