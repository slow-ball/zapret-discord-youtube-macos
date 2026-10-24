#!/bin/bash
# Подписанный архив релиза: build/release.sh 3.1.0 — архив тега v3.1.0 и его подпись
# (zapret-macos-3.1.0.tar.gz и .sig) прикрепляются к релизу v3.1.0. Только их ставит обновление.
# Ключ: $ZAPRET_RELEASE_KEY или ~/.config/zapret-release/key (запасной — тот, что вне компьютера).
# В репозитории их нет и быть не должно.

set -euo pipefail

v=${1:?версия, например 3.1.0}
key=${ZAPRET_RELEASE_KEY:-$HOME/.config/zapret-release/key}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
a=$TMP/zapret-macos-$v.tar.gz

git -C "$ROOT" archive --format=tar.gz --prefix=zapret-macos/ -o "$a" "v$v"
[ "$(tar -xzOf "$a" zapret-macos/src/VERSION)" = "$v" ] || { echo "в теге v$v другая версия" >&2; exit 1; }
ssh-keygen -q -Y sign -f "$key" -n zapret-release "$a"

# the same check the macs do, with the key of the archive itself
tar -xzOf "$a" zapret-macos/src/zapret.sh | sed -n 's/^RELEASE_KEY\(_BACKUP\)\{0,1\}="\(.*\)"$/zapret \2/p' > "$TMP/keys"
ssh-keygen -Y verify -f "$TMP/keys" -I zapret -n zapret-release -s "$a.sig" < "$a"

gh release upload "v$v" "$a" "$a.sig" --clobber -R slow-ball/zapret-discord-youtube-macos
echo "подписано и прикреплено: $(basename "$a")"
