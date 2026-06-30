# ============================================================================
#  Glass Cauldron — COLMAP 4.1.0 (CUDA) frozen image
#  DIGLER AI · build ONCE in the cloud, pull in minutes forever after.
# ----------------------------------------------------------------------------
#  This bakes the proven CLAUDE.md source-build into a Docker image so no pod
#  ever rebuilds COLMAP again. Drives the COLMAP *CLI* (CUDA-enabled). The
#  from-source pycolmap *bindings* are deliberately NOT built — they import-
#  abort ("Camera model does not exist"); the CLI produces identical output.
# ============================================================================
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04

# OPENBLAS_NUM_THREADS=1 is the keystone fix — without it, vocab-tree matching
# aborts on high-core boxes (the 256-core FAISS/OpenBLAS overflow). Baked in
# so it's always set, on every pod, automatically.
ENV DEBIAN_FRONTEND=noninteractive \
    OPENBLAS_NUM_THREADS=1

# ---- Build dependencies (the exact set from the proven recipe) -------------
# libopenblas-OPENMP-dev is load-bearing: FAISS links the OpenMP OpenBLAS.
# The OpenImageIO chain (openimageio-tools, libopenexr-dev, libqt5svg5-dev,
# libopencv-dev) is required by COLMAP 4.x on 22.04. Do NOT add libimath-dev
# (conflicts with libilmbase-dev that OpenImageIO pulls in).
RUN apt-get update && apt-get install -y --no-install-recommends \
      git cmake ninja-build build-essential wget ca-certificates \
      libboost-program-options-dev libboost-graph-dev libboost-system-dev \
      libboost-filesystem-dev libboost-test-dev \
      libeigen3-dev libflann-dev libfreeimage-dev libmetis-dev \
      libgoogle-glog-dev libgtest-dev libgmock-dev libsqlite3-dev \
      libglew-dev qtbase5-dev libqt5opengl5-dev libcgal-dev libceres-dev \
      libcurl4-openssl-dev liblz4-dev libopenblas-openmp-dev liblapack-dev \
      libopenimageio-dev openimageio-tools libopenexr-dev libqt5svg5-dev libopencv-dev \
    && rm -rf /var/lib/apt/lists/*

# ---- Compile + install COLMAP 4.1.0 CLI (CUDA, SHARED libs) ----------------
# BUILD_SHARED_LIBS=ON is REQUIRED (static build aborts "Camera model does not
# exist"). Arch list 80;86;89 covers the non-Blackwell pods in play:
#   80 = A100 · 86 = RTX 3090/A4000/A5000/A6000/A40/3050 · 89 = RTX 4090
# so the one image runs on any of them. Then register the shared-libs path
# (BUILD_SHARED_LIBS installs libcolmap_*.so to /usr/local/thirdparty, which
# nothing finds at runtime without this) and drop stale static libs.
RUN git clone --depth 1 --branch 4.1.0 https://github.com/colmap/colmap.git /opt/colmap-src && \
    cmake -S /opt/colmap-src -B /opt/colmap-src/build -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DCUDA_ENABLED=ON \
      -DCMAKE_CUDA_ARCHITECTURES="80;86;89" \
      -DCMAKE_INSTALL_PREFIX=/usr/local && \
    ninja -C /opt/colmap-src/build && \
    ninja -C /opt/colmap-src/build install && \
    echo /usr/local/thirdparty > /etc/ld.so.conf.d/colmap.conf && \
    rm -f /usr/local/lib/libcolmap_*.a && \
    ldconfig && \
    rm -rf /opt/colmap-src

# ---- Bake in the FAISS vocab tree so it's always present at /opt -----------
RUN wget -q -O /opt/vocab_tree.bin \
      https://github.com/colmap/colmap/releases/download/3.11.1/vocab_tree_faiss_flickr100K_words256K.bin

# ---- Build-time sanity: fail the build if COLMAP's shared libs don't resolve
# (this is the #1 thing that breaks — the thirdparty ldconfig path). This check
# needs no GPU, so it works on a GitHub runner. The "with CUDA" confirmation
# happens on first run on an actual GPU pod.
RUN command -v colmap && \
    if ldd "$(command -v colmap)" | grep -q "not found"; then \
      echo "!! UNRESOLVED LIBS:"; ldd "$(command -v colmap)" | grep "not found"; exit 1; \
    fi && \
    echo "COLMAP binary installed and all shared libs resolve."

CMD ["/bin/bash"]
