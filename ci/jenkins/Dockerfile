# CI build image for attention_copilot Linux desktop builds.
#
# Mirrors the toolchain of the GitHub Actions linux job (ci.yml):
# same apt package list, same pinned Flutter version (docs/DECISIONS.md).
# Built once on the Jenkins agent as attention-copilot-flutter:3.47.4.
# Image runs as uid 1000 on the agent, matching the sysop user, so files
# created inside the mounted workspace stay owned by the agent user.

FROM ubuntu:24.04

ARG FLUTTER_VERSION=3.47.4

ENV DEBIAN_FRONTEND=noninteractive \
    FLUTTER_HOME=/opt/flutter \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:$PATH

# Base toolchain: git/curl/xz for the SDK fetch, build-essential to match the
# ubuntu-latest runner, and the exact Flutter Linux desktop dependency list
# from .github/workflows/ci.yml.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils file \
    build-essential \
    libgtk-3-dev ninja-build clang cmake pkg-config \
    libglib2.0-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libsecret-1-dev libayatana-appindicator3-dev \
    libdbus-1-dev \
    && rm -rf /var/lib/apt/lists/*

# Extraction stays root-owned on disk, but the tarball itself carries the
# SDK under its build user (uid 1000). Running the steps below as that same
# user keeps every file the tool creates owned by it - no chown pass needed.
RUN curl -fsSL \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar -xJ -C /opt

USER 1000:1000
ENV HOME=/home/ubuntu

# The tarball's ownership trips git's dubious-ownership check; whitelist the
# SDK dir, then warm the Linux engine so builds do not download at runtime.
RUN git config --global --add safe.directory /opt/flutter \
    && flutter --version \
    && flutter precache --linux

WORKDIR /workspace
