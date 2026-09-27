FROM ubuntu:26.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git cmake make gcc g++ clang libssl-dev libbz2-dev libreadline-dev libncurses-dev \
      libboost-all-dev default-libmysqlclient-dev libstdc++-16-dev default-mysql-client ca-certificates \
 && rm -rf /var/lib/apt/lists/*
