#!/bin/sh -ve

# SPDX-FileCopyrightText: 2019-Present Christian Kußowski
# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
#
# SPDX-License-Identifier: AGPL-3.0-or-later

SED=$(command -v gsed || command -v sed)

# Compile Vodozemac for web.
#
# This builds the library that handles every Matrix encryption key in the
# browser, from source, outside pubspec.lock's integrity checks. Upstream
# clones a *tag*, which is mutable: whoever can move it changes the crypto
# that ships. So we clone the tag and then assert the commit, which pins the
# build without giving up the readable version number.
#
# To bump: change both VODOZEMAC_VERSION and VODOZEMAC_COMMIT. Resolve the new
# commit with:
#   git ls-remote --tags https://github.com/famedly/dart-vodozemac.git
# and take the `refs/tags/<v>^{}` line -- the tags are annotated, so the bare
# ref is the tag object, not the commit.
VODOZEMAC_VERSION=0.8.1
VODOZEMAC_COMMIT=494dbbc732f8c1dbf8e6c07a11e9ca57f399ff7e
# Keep the pin honest against pubspec.yaml rather than letting them drift.
pubspec_version=$(yq ".dependencies.flutter_vodozemac" < pubspec.yaml | tr -d '"^')
if [ "$pubspec_version" != "$VODOZEMAC_VERSION" ]; then
  echo "prepare-web: pubspec wants flutter_vodozemac $pubspec_version but this script pins $VODOZEMAC_VERSION" >&2
  exit 1
fi
version="$VODOZEMAC_VERSION"

git clone https://github.com/famedly/dart-vodozemac.git -b "$VODOZEMAC_VERSION" .vodozemac
cd .vodozemac
actual_commit=$(git rev-parse HEAD)
if [ "$actual_commit" != "$VODOZEMAC_COMMIT" ]; then
  echo "prepare-web: tag $VODOZEMAC_VERSION resolves to $actual_commit, expected $VODOZEMAC_COMMIT" >&2
  echo "prepare-web: the tag moved -- refusing to build crypto from unverified source" >&2
  exit 1
fi

# Pinned too: this generates the Dart<->Rust bridge for the crypto above, so
# "whatever is latest on crates.io" is the same trust problem one level up.
# 2.13.0 is not a free choice: vodozemac 0.8.1 pins flutter_rust_bridge to
# "=2.13.0" exactly, so the codegen must match or the bindings will not line up.
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
# flutter_rust_bridge hard-codes RUSTUP_TOOLCHAIN=nightly for the wasm-pack
# step (see its build_web/executor.dart), so without this flag the crypto is
# compiled by whatever "nightly" happens to be today -- the Dockerfile's dated
# toolchain is bypassed entirely and the pin is silently useless.
# RUST_NIGHTLY is exported by the Dockerfile; fall back for local runs.
flutter_rust_bridge_codegen build-web --dart-root dart --rust-root $(readlink -f rust) --release \
  --wasm-pack-rustup-toolchain "${RUST_NIGHTLY:-nightly}"
cd ..
rm -f ./assets/vodozemac/vodozemac_bindings_dart*
mkdir -p "./assets/vodozemac/$version/"
mv .vodozemac/dart/web/pkg/vodozemac_bindings_dart* "./assets/vodozemac/$version/"
rm -rf .vodozemac
grep -qF "assets/vodozemac/${version}/" pubspec.yaml || "$SED" -i "\|- assets/sounds/|a\\    - assets/vodozemac/${version}/" pubspec.yaml
"$SED" -i "s/vodozemacVersion = '.*';/vodozemacVersion = '${version}';/" lib/config/app_config.dart

flutter pub get
dart compile js ./web/native_executor.dart -o ./web/native_executor.js -m

# Download native_imaging for web.
#
# This JavaScript is copied into web/ and therefore executes in our origin
# alongside the app, so verify it rather than trusting that a release asset is
# never re-uploaded. Update the checksum when bumping the version:
#   curl -sSL <url> | shasum -a 256
NATIVE_IMAGING_SHA256=35a4786bf91c48fc500af724fc6191bd7ecc5a4dc67a7b5e8a1ab745dad4252c
version=$(yq ".dependencies.native_imaging" < pubspec.yaml)
version=$(printf "%s" "$version" | tr -d '"^')
curl -L "https://github.com/famedly/dart_native_imaging/releases/download/v${version}/native_imaging.zip" > native_imaging.zip
echo "${NATIVE_IMAGING_SHA256}  native_imaging.zip" | sha256sum -c - || {
  echo "prepare-web: native_imaging.zip does not match the pinned checksum" >&2
  exit 1
}
unzip native_imaging.zip
mv js/* web/
rmdir js
rm native_imaging.zip
