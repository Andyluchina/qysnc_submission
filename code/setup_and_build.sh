#!/bin/bash
# Install deps (Fedora-specific) and build Asterisk MPC natively on a DS machine.
# Assumes we're running as root on a Fedora DS machine.
set -e

SRC_DIR="/tmp/mpc-native"
BUILD_DIR="$SRC_DIR/build"
DEPS_DIR="/tmp/mpc-deps"

echo "=== Installing system packages ==="
dnf install -y gcc-c++ cmake git gmp-devel openssl-devel boost-devel make \
               openssl libgomp python3

# NTL — not in Fedora default; build from source
if [ ! -f /usr/local/lib/libntl.a ]; then
    echo "=== Building NTL from source ==="
    mkdir -p "$DEPS_DIR" && cd "$DEPS_DIR"
    if [ ! -d ntl-11.5.1 ]; then
        curl -L -o ntl.tar.gz https://libntl.org/ntl-11.5.1.tar.gz
        tar xzf ntl.tar.gz
    fi
    cd ntl-11.5.1/src
    ./configure NTL_GMP_LIP=on SHARED=on
    make -j$(nproc)
    make install
    ldconfig
fi

# nlohmann/json
if [ ! -f /usr/local/include/nlohmann/json.hpp ]; then
    echo "=== Installing nlohmann/json ==="
    cd "$DEPS_DIR"
    if [ ! -d json ]; then
        git clone --depth=1 --branch v3.11.3 https://github.com/nlohmann/json.git
    fi
    cd json && mkdir -p build && cd build
    cmake -DCMAKE_BUILD_TYPE=Release -DJSON_BuildTests=OFF ..
    make -j$(nproc)
    make install
fi

# emp-tool
if [ ! -f /usr/local/lib64/libemp-tool.so ] && [ ! -f /usr/local/lib/libemp-tool.so ]; then
    echo "=== Installing emp-tool ==="
    cd "$DEPS_DIR"
    if [ ! -d emp-tool ]; then
        git clone --depth=1 https://github.com/emp-toolkit/emp-tool.git
    fi
    cd emp-tool
    cmake -DCMAKE_BUILD_TYPE=Release .
    make -j$(nproc)
    make install
    ldconfig
fi

echo "=== Building Asterisk MPC ==="
cd "$SRC_DIR"
mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc) asterisk_mpc

echo ""
echo "=== Built binary ==="
ls -la "$BUILD_DIR/benchmark/asterisk_mpc"
ldd "$BUILD_DIR/benchmark/asterisk_mpc" | head
