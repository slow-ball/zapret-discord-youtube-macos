#!/bin/bash
# Проверяет, что utunws принимает каждую стратегию nfqws в самой полной сборке: автосписок
# умного режима, игровой фильтр TCP и UDP, все IP. Используется в CI и при импорте стратегий.
# Запуск: build/check-nfqws.sh <путь к utunws>

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
UTUNWS=$1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/base/bin" "$TMP/lists"
cp "$UTUNWS" "$ROOT"/src/nfqws/bin/*.bin "$TMP/base/bin/"
cp "$ROOT"/src/list-general.txt "$ROOT"/src/list-google.txt "$ROOT"/src/list-exclude.txt "$ROOT"/src/ipset-exclude.txt "$TMP/lists/"
cp "$ROOT/src/nfqws/ipset-game.txt" "$TMP/base/"
touch "$TMP"/lists/{list-general-user,list-exclude-user,ipset-exclude-user,ipset-any,list-auto}.txt

failed=0
while IFS=$'\t' read -r file name; do
	[ -n "$file" ] || continue
	s="$ROOT/src/nfqws/strategies/$file"
	{
		echo --dry-run
		awk '{ print } $0 == "--hostlist=\"@LISTS@/list-general-user.txt\"" { print "--hostlist-auto=\"@LISTS@/list-auto.txt\"" }' "$s.conf.in"
		for k in tcp udp; do
			[ -f "$s.game-$k.conf.in" ] && { echo --new; cat "$s.game-$k.conf.in"; }
		done
	} | sed -e "s|@BASE@|$TMP/base|g" -e "s|@LISTS@|$TMP/lists|g" -e "s|@IPSET@|$TMP/lists/ipset-any.txt|g" \
		-e "s|@GAME_TCP@|1024-65535|g" -e "s|@GAME_UDP@|1024-65535|g" -e "s|@GAMEIPSET@|$TMP/base/ipset-game.txt|g" > "$TMP/t.conf"
	if "$UTUNWS" "@$TMP/t.conf" >/dev/null 2>&1; then
		echo "ok   $name"
	else
		echo "FAIL $name"
		"$UTUNWS" "@$TMP/t.conf" 2>&1 | tail -3
		failed=1
	fi
done < "$ROOT/src/nfqws/strategies.tsv"
exit $failed
