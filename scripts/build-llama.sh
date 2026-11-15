#!/bin/bash
# Build llama.cpp as static libraries (Metal GPU, shader source embedded and compiled at runtime, so no Xcode needed)
# from a pinned, checksum-verified source archive. Output: build/llama/{include,lib}. Re-running is a no-op.
#   CMAKE=/path/to/cmake scripts/build-llama.sh
set -euo pipefail
VERSION=b12383
SHA256=20566a281df9047ea6c8d96213c6da8e225fb30d7fb32c00208531da9a13ddb6
URL="https://github.com/ggml-org/llama.cpp/archive/refs/tags/$VERSION.tar.gz"
OUT="${LLAMA_OUT:-build/llama}"
CMAKE="${CMAKE:-cmake}"

if [[ -f "$OUT/.version" && "$(cat "$OUT/.version")" == "$VERSION" ]]; then
  exit 0
fi
command -v "$CMAKE" >/dev/null || { echo "cmake is needed to build llama.cpp (set CMAKE=/path/to/cmake)" >&2; exit 1; }

WORK="$OUT/src"
rm -rf "$OUT" && mkdir -p "$WORK"
curl -fsSL "$URL" -o "$WORK/llama.tar.gz"
actual=$(shasum -a 256 "$WORK/llama.tar.gz" | cut -d' ' -f1)
[[ "$actual" == "$SHA256" ]] || { echo "llama.cpp archive checksum mismatch: $actual" >&2; exit 1; }
tar -xzf "$WORK/llama.tar.gz" -C "$WORK"
SRC="$WORK/llama.cpp-$VERSION"

"$CMAKE" -S "$SRC" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=OFF -DGGML_NATIVE=OFF \
  -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_COMMON=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
"$CMAKE" --build "$WORK/build" --target llama -j 8 >/dev/null

mkdir -p "$OUT/lib" "$OUT/include"
find "$WORK/build" -name '*.a' -exec cp {} "$OUT/lib/" \;
cp "$SRC/include/llama.h" "$SRC"/ggml/include/*.h "$OUT/include/"
cp "$SRC/LICENSE" "$OUT/LICENSE"
rm -rf "$WORK"
echo "$VERSION" > "$OUT/.version"
echo "Built llama.cpp $VERSION into $OUT"
