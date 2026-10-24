#!/bin/bash
# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC2016,SC2034  # eval in single quotes on purpose; the sourced code reads PROJECT and json
# Быстрые тесты логики zapret.sh: без root, без сети, за пару секунд. Запуск: tests/unit.sh
# Скрипт подключается как библиотека (ZAPRET_LIB_ONLY), /opt подменяется временными папками.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/rt" "$TMP/z/ipset" "$TMP/project/lists"
export ZAPRET_LIB_ONLY=1 ZAPRET_TEST_RT="$TMP/rt" ZAPRET_TEST_Z="$TMP/z"
# shellcheck source=src/zapret.sh
. "$ROOT/src/zapret.sh"
PROJECT="$TMP/project"
chown() { :; }
install_sudoers() { :; }
sync_runtime
write_lists

passed=0 failed=0
check() {
	local what=$1
	shift
	if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $what"; fi
}
eq() { [ "$1" = "$2" ] || { echo "  получено «$1», ожидалось «$2»"; return 1; }; }
has() { printf '%s' "$1" | grep -qF -- "$2" || { echo "  нет «$2»"; return 1; }; }
lacks() { ! printf '%s' "$1" | grep -qF -- "$2" || { echo "  лишнее «$2»"; return 1; }; }
json() { python3 -I -c 'import json, sys; json.loads(sys.stdin.read())' <<<"$1" || { echo "  не JSON: $1"; return 1; }; }

# strategies and engines
check "nfqws по префиксу" eq "$(engine_of "nfqws general (ALT13)")" nfqws
check "tpws без префикса" eq "$(engine_of "general (ALT6)")" tpws
check "файл стратегии nfqws" eq "$(nfqws_file "nfqws general (SIMPLE FAKE)")" general-simple-fake
check "неизвестная стратегия nfqws" eq "$(nfqws_file "nfqws нет такой")" ""
check "стратегии Windows-версии первыми" eq "$(strategy_names | head -1)" "nfqws general"
check "37 стратегий" eq "$(strategy_names | wc -l | tr -d ' ')" 37
check "параметры tpws по имени" has "$(strategy_opts "general (ALT6)")" "--disorder"
check "чужое имя — без параметров" eq "$(strategy_opts "general; rm -rf /")" ""

# host names: only these go into curl, tpws lists and strategy names
check "адрес из ссылки" eq "$(host_of "https://www.Example.COM/page?x=1")" example.com
check "порт отрезается" eq "$(host_of "site.ru:443")" site.ru
check "поддомены остаются" eq "$(host_of "rr3---sn-abc.googlevideo.com")" rr3---sn-abc.googlevideo.com
check "пробелы — не адрес" eq "$(host_of "not a site")" ""
check "кавычки — не адрес" eq "$(host_of 'a.com"; touch /tmp/x; "')" ""
check "перевод строки — не адрес" eq "$(host_of $'a.com\nb.com')" ""
check "без точки — не адрес" eq "$(host_of localhost)" ""

# tpws options for each scope
echo all > "$RT/scope"
o=$(tpws_opt "--split-pos=1")
check "все сайты: без hostlist" lacks "$o" "--hostlist=$Z/ipset/zapret-hosts-user.txt"
check "все сайты: исключения" has "$o" "--hostlist-exclude="
echo smart > "$RT/scope"
o=$(tpws_opt "--split-pos=1")
check "умный: автосписок" has "$o" "--hostlist-auto=$AUTO_LIST"
check "умный: порог 2" has "$o" "--hostlist-auto-fail-threshold=2"
echo lists > "$RT/scope"
o=$(tpws_opt "--split-pos=1")
check "по спискам: свой список" has "$o" "--hostlist=$Z/ipset/zapret-hosts-user.txt"
check "по спискам: без автосписка" lacks "$o" "--hostlist-auto"
printf 'example.com\tgeneral (ALT3)\n' > "$SITES"
o=$(tpws_opt "--split-pos=1")
check "своя стратегия сайта — отдельный профиль" has "$o" "--hostlist=$RT/lists/site-1.txt"
check "профиль сайта раньше основного" eq "$(printf '%s\n' "$o" | grep -n site-1 | cut -d: -f1)" 2
: > "$SITES"

# nfqws configs for each scope and game filter
c="$TMP/n.conf"
echo all > "$RT/scope"; rm -f "$RT/game"
nfqws_conf "nfqws general (ALT13)" "$c"
check "nfqws все сайты: ipset-any" has "$(cat "$c")" "ipset-any.txt"
check "nfqws без игр: нет игровых портов" lacks "$(cat "$c")" "1024-65535"
echo smart > "$RT/scope"
nfqws_conf "nfqws general (ALT13)" "$c"
check "nfqws умный: автосписок" has "$(cat "$c")" "--hostlist-auto="
check "nfqws умный: ipset-none" has "$(cat "$c")" "ipset-none.txt"
echo all > "$RT/scope"; echo all > "$RT/game"
nfqws_conf "nfqws general (ALT13)" "$c"
check "игры TCP и UDP" eq "$(grep -c -- '"1024-65535"' "$c")" 2
check "игры: свой IP-список" has "$(cat "$c")" "ipset-game.txt"
check "плейсхолдеров не осталось" lacks "$(cat "$c")" "@"
rm -f "$RT/game" "$RT/scope"
check "неизвестная стратегия nfqws — ошибка" eval '! nfqws_conf "nfqws нет такой" "$c"'

# versions
check "2.10.0 новее 2.9.0" newer 2.10.0 2.9.0
check "одинаковые — не новее" eval '! newer 2.1.0 2.1.0'
check "2.0.9 не новее 2.1.0" eval '! newer 2.0.9 2.1.0'
check "пустая — не новее" eval '! newer "" 2.1.0'

# JSON for the app
check "jstr экранирует" json "$(jstr 'кавычка " и \ слеш')"
json=1
check "событие — JSON" json "$(event result name 'nfqws general "x"' ok 1)"
json=0
check "событие молчит без --json" eq "$(event result name x)" ""
check "status --json" json "$(cmd_status --json)"

# lists
printf '# комментарий\n\na.com\nb.com\n' > "$TMP/list.txt"
check "записи без комментариев" eq "$(count_entries "$TMP/list.txt")" 2
check "нет файла — 0" eq "$(count_entries "$TMP/нет")" 0
check "свой список читается" has "$(user_cat "$TMP/list.txt")" "a.com"

# the best strategy
check "первая — лучшая" better "general" 100 0 "" 0 -1
check "голос важнее скорости" better "general (ALT)" 100 1 "general" 900 0
check "без голоса не обгоняет с голосом" eval '! better "general (ALT)" 900 0 "general" 100 1'
check "заметно быстрее — лучше" better "general (ALT)" 160 1 "general" 100 1
check "чуть быстрее — нет" eval '! better "general (ALT)" 120 1 "general" 100 1'
check "nfqws обгоняет tpws на равных" better "nfqws general" 90 1 "general" 100 1
check "tpws не обгоняет nfqws на равных" eval '! better "general" 110 1 "nfqws general" 100 1'
check "nfqws не обгоняет заметно быстрый tpws" eval '! better "nfqws general" 50 1 "general" 100 1'

echo "unit: $passed прошло, $failed не прошло"
[ $failed = 0 ]
