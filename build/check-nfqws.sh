#!/bin/bash
# shellcheck source-path=SCRIPTDIR/..
# Проверяет, что utunws принимает каждую стратегию в самой полной сборке (автосписок умного режима,
# игровой фильтр TCP и UDP, все IP, профиль для своего сайта) и каждый вариант глубокого подбора.
# Конфиги собирает тот же код, что у пользователя. Используется в CI и при импорте стратегий.
# Запуск: build/check-nfqws.sh <путь к utunws>

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
UTUNWS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/rt" "$TMP/project/lists"

export ZAPRET_LIB_ONLY=1 ZAPRET_TEST_RT="$TMP/rt" ZAPRET_TEST_LEGACY="$TMP/legacy" ZAPRET_TEST_LEGACY_PLIST="$TMP/zapret.plist"
# shellcheck source=src/zapret.sh
. "$ROOT/src/zapret.sh"
PROJECT="$TMP/project"
LOG="$TMP/log"
chown() { :; }
install_sudoers() { :; }
launchctl() { :; }
sync_runtime
write_lists
echo smart > "$RT/scope"
echo all > "$RT/game"
printf 'example.com\tmacos (ALT3)\n' > "$SITES"

failed=0
try() {
	if "$UTUNWS" "@$TMP/t.conf" >/dev/null 2>&1; then
		echo "ok   $1"
	else
		echo "FAIL $1"
		"$UTUNWS" "@$TMP/t.conf" 2>&1 | tail -3
		failed=1
	fi
}

while IFS= read -r name; do
	nfqws_conf "$name" "$TMP/c.conf" || { echo "FAIL $name: нет конфига"; failed=1; continue; }
	{ echo --dry-run; cat "$TMP/c.conf"; } > "$TMP/t.conf"
	try "$name"
done < <(strategy_names)

n=0
while IFS= read -r o; do
	n=$((n + 1))
	nfqws_site_conf "$o" "$RT/lists/list-general.txt" "$TMP/c.conf"
	{ echo --dry-run; cat "$TMP/c.conf"; } > "$TMP/t.conf"
	try "глубокий подбор $n: $o"
done < <(deep_candidates)
exit $failed
