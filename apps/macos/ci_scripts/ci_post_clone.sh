#!/bin/sh
# Xcode Cloud: runs once after the clone, before xcodebuild.
#
# The app links HyperEnv's Rust core (Scripts/build-core.sh, a build phase),
# and Xcode Cloud images ship without Rust. Install the toolchain the
# workspace pins, for both slices of the universal build. build-core.sh already
# looks in ~/.cargo/bin, so nothing else needs to change.
set -eu

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --no-modify-path
"$HOME/.cargo/bin/rustup" target add aarch64-apple-darwin x86_64-apple-darwin
"$HOME/.cargo/bin/cargo" --version
