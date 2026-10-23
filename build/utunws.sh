#!/bin/bash
# Собирает движок nfqws для macOS (utunws) из исходников Flowseal/zapret-mac-discord-youtube (MIT)
# на зафиксированном коммите, с нашими патчами из build/patches.
# Результат: <выходная папка>/utunws.tar.gz — bin/utunws, LICENSE, SOURCE.
# Файлы фейков лежат в проекте (src/nfqws/bin) вместе со стратегиями.
# Запуск: build/utunws.sh [выходная папка, по умолчанию dist]

set -euo pipefail

FS_COMMIT=94c3b5125b4904ce2f6aec0e2197fe17f2fadf14
FS_SHA256=6885b4966496410320a9c4982a402ea0a3c3ea3f3c92788458c939b143155ede

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "${1:-dist}" && cd "${1:-dist}" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/src.tar.gz" "https://github.com/Flowseal/zapret-mac-discord-youtube/archive/$FS_COMMIT.tar.gz"
echo "$FS_SHA256  $TMP/src.tar.gz" | shasum -a 256 -c
tar -xzf "$TMP/src.tar.gz" -C "$TMP"
SRC="$TMP/zapret-mac-discord-youtube-$FS_COMMIT"

for p in "$ROOT"/build/patches/*.patch; do
	[ -e "$p" ] || continue
	echo "patch: $(basename "$p")"
	patch -d "$SRC" -p1 --forward < "$p"
done

make -C "$SRC/nfq" mac CC="$(xcrun -f clang)" SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
# strip and lipo leave the x86_64 part unsigned, and Apple Silicon runs only signed code
codesign --force -s - -i utunws "$SRC/nfq/utunws"
codesign -v "$SRC/nfq/utunws"

mkdir -p "$TMP/pkg/bin"
cp "$SRC/nfq/utunws" "$TMP/pkg/bin/"
cp "$SRC/LICENSE" "$TMP/pkg/"
{
	echo "Flowseal/zapret-mac-discord-youtube $FS_COMMIT"
	for p in "$ROOT"/build/patches/*.patch; do [ -e "$p" ] && echo "patch $(basename "$p")"; done
} > "$TMP/pkg/SOURCE"
tar -czf "$OUT/utunws.tar.gz" -C "$TMP/pkg" .
shasum -a 256 "$OUT/utunws.tar.gz"
