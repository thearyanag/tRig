#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision=d1085f9cebc5a62379991ae1652673954f229c1f
arch="$(uname -m)"
cache="$root/.build/telegram"
source_dir="${TDLIB_SOURCE_DIR:-$cache/source}"
build_dir="$cache/tdlib-$arch"
mkdir -p "$cache"

if [[ ! -d "$source_dir/.git" ]]; then
  if [[ -n "${TDLIB_SOURCE_DIR:-}" ]]; then
    echo 'TDLIB_SOURCE_DIR must point to a clean checkout of the pinned TDLib revision.' >&2
    exit 1
  fi
  git clone --filter=blob:none --no-checkout https://github.com/tdlib/td.git "$source_dir"
  git -C "$source_dir" checkout --detach "$revision"
fi
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$revision" || -n "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]; then
  echo "TDLib must be a clean checkout at $revision." >&2
  exit 1
fi

# Build the crypto dependency for the same minimum OS. Homebrew's prebuilt
# library can target the build machine's newer macOS version.
openssl_revision=aae016bfd52fcad2bc9657c2c782cfdf73b1ed5f
openssl_source="$cache/openssl-source"
openssl_build="$cache/openssl-build-$arch"
openssl_dir="$cache/openssl-$arch"
if [[ ! -f "$openssl_dir/revision" ]] || [[ "$(cat "$openssl_dir/revision")" != "$openssl_revision" ]]; then
  if [[ ! -d "$openssl_source/.git" ]]; then
    git clone --depth 1 --branch openssl-3.6.3 https://github.com/openssl/openssl.git "$openssl_source"
  fi
  if [[ "$(git -C "$openssl_source" rev-parse HEAD)" != "$openssl_revision" ]]; then
    echo "OpenSSL source revision does not match the pinned build." >&2
    exit 1
  fi
  case "$arch" in
    arm64) openssl_target=darwin64-arm64-cc ;;
    x86_64) openssl_target=darwin64-x86_64-cc ;;
    *) echo "Unsupported Mac architecture: $arch" >&2; exit 1 ;;
  esac
  mkdir -p "$openssl_build" "$openssl_dir"
  (
    cd "$openssl_build"
    perl "$openssl_source/Configure" "$openssl_target" no-shared no-tests no-docs no-apps \
      --prefix="$openssl_dir" --libdir=lib -mmacosx-version-min=14.0
    make -j "${TDLIB_JOBS:-4}"
    make install_sw
  )
  cp "$openssl_source/LICENSE.txt" "$openssl_dir/LICENSE.txt"
  printf '%s\n' "$openssl_revision" > "$openssl_dir/revision"
fi
cmake -S "$source_dir" -B "$build_dir" -G Ninja \
  -U 'OPENSSL_*' -U '_OPENSSL*' \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES="$arch" \
  -DOPENSSL_ROOT_DIR="$openssl_dir" \
  -DOPENSSL_USE_STATIC_LIBS=ON
cmake --build "$build_dir" --target tdjson --parallel "${TDLIB_JOBS:-4}"
cp "$source_dir/LICENSE_1_0.txt" "$build_dir/TDLib-LICENSE.txt"
cp "$openssl_dir/LICENSE.txt" "$build_dir/OpenSSL-LICENSE.txt"
printf '%s\n' "$revision" > "$build_dir/bundled-revision"
echo "TDLib is ready at $build_dir/libtdjson.dylib"
