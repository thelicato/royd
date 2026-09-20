FROM ubuntu:22.04

ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bc \
    bison \
    build-essential \
    ca-certificates \
    ccache \
    curl \
    file \
    flex \
    fontconfig \
    g++-multilib \
    gcc-multilib \
    git \
    git-lfs \
    gnupg \
    lib32z1-dev \
    libc6-dev-i386 \
    libgl1-mesa-dev \
    liblz4-tool \
    libx11-dev \
    libssl-dev \
    libxml2-utils \
    lzop \
    python3 \
    repo \
    rsync \
    unzip \
    x11proto-core-dev \
    xsltproc \
    zip \
    zlib1g-dev \
  && rm -rf /var/lib/apt/lists/*

RUN git lfs install --system \
  && git config --system user.name royd-builder \
  && git config --system user.email royd-builder@localhost

RUN groupadd --gid "$GID" builder \
  && useradd --uid "$UID" --gid "$GID" --create-home --shell /bin/bash builder

USER builder
WORKDIR /workspace/royd

CMD ["/bin/bash"]
