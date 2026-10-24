#!/bin/bash
# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC2016,SC2034  # eval in single quotes on purpose; the sourced code reads PROJECT and json
# Быстрые тесты логики zapret.sh: без root, без сети, за пару секунд. Запуск: tests/unit.sh
# Скрипт подключается как библиотека (ZAPRET_LIB_ONLY), /opt подменяется временными папками.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
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
pkill() { :; }
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

# strategies
check "Windows-версия по префиксу" is_windows "nfqws general (ALT13)"
check "свои — не Windows" eval '! is_windows "macos (ALT5)"'
check "файл стратегии Windows" eq "$(nfqws_file "nfqws general (SIMPLE FAKE)")" general-simple-fake
check "неизвестная стратегия Windows" eq "$(nfqws_file "nfqws нет такой")" ""
check "стратегии Windows-версии первыми" eq "$(strategy_names | head -1)" "nfqws general"
check "свои после них" eq "$(own_names | head -1)" "macos"
check "37 стратегий" eq "$(strategy_names | wc -l | tr -d ' ')" 37
check "параметры своей по имени" has "$(strategy_opts "macos (ALT5)")" "--dpi-desync=multisplit"
check "чужое имя — без параметров" eq "$(strategy_opts "macos; rm -rf /")" ""
check "известное имя" known_name "macos (ALT14)"
check "имя tpws из 2.x — неизвестное" eval '! known_name "general (ALT6)"'

# host names: only these go into curl, nfqws lists and strategy names
check "адрес из ссылки" eq "$(host_of "https://www.Example.COM/page?x=1")" example.com
check "порт отрезается" eq "$(host_of "site.ru:443")" site.ru
check "поддомены остаются" eq "$(host_of "rr3---sn-abc.googlevideo.com")" rr3---sn-abc.googlevideo.com
check "пробелы — не адрес" eq "$(host_of "not a site")" ""
check "кавычки — не адрес" eq "$(host_of 'a.com"; touch /tmp/x; "')" ""
check "перевод строки — не адрес" eq "$(host_of $'a.com\nb.com')" ""
check "без точки — не адрес" eq "$(host_of localhost)" ""

# configs for each scope, kind of strategy and game filter
c="$TMP/n.conf"
echo all > "$RT/scope"; rm -f "$RT/game"
nfqws_conf "nfqws general (ALT13)" "$c"
check "все сайты: ipset-any" has "$(cat "$c")" "ipset-any.txt"
check "без игр: нет игровых портов" lacks "$(cat "$c")" "1024-65535"
echo smart > "$RT/scope"
nfqws_conf "nfqws general (ALT13)" "$c"
check "умный: автосписок" has "$(cat "$c")" "--hostlist-auto="
check "умный: ipset-none" has "$(cat "$c")" "ipset-none.txt"
echo all > "$RT/scope"; echo all > "$RT/game"
nfqws_conf "nfqws general (ALT13)" "$c"
check "игры TCP и UDP" eq "$(grep -c -- '"1024-65535"' "$c")" 2
check "игры: свой IP-список" has "$(cat "$c")" "ipset-game.txt"
check "плейсхолдеров не осталось" lacks "$(cat "$c")" "@"
nfqws_conf "macos (ALT5)" "$c"
check "своя: параметры вместо @DESYNC@" eq "$(grep -c -- '--dpi-desync=multisplit' "$c")" 5
check "своя: QUIC как в general" has "$(cat "$c")" "quic_initial_www_google_com.bin"
check "своя: игры из шаблона" eq "$(grep -c -- '"1024-65535"' "$c")" 2
check "своя: плейсхолдеров не осталось" lacks "$(cat "$c")" "@"
check "своя: путь к фейкам" has "$(nfqws_conf "macos (ALT8)" "$c"; cat "$c")" "--dpi-desync-split-seqovl-pattern=$RT/nfqws/bin/tls_clienthello_www_google_com.bin"
rm -f "$RT/game" "$RT/scope"
check "неизвестная стратегия — ошибка" eval '! nfqws_conf "nfqws нет такой" "$c"'
check "стратегия tpws из 2.x — ошибка" eval '! nfqws_conf "general (ALT6)" "$c"'

# sites with their own strategy get the first profile
check "параметры Windows-стратегии для сайта" has "$(site_opts "nfqws general (ALT13)")" "--dpi-desync=fake,hostfakesplit"
check "без фильтров и списков" lacks "$(site_opts "nfqws general (ALT13)")" "--hostlist"
check "без кавычек" lacks "$(site_opts "nfqws general (ALT13)")" '"'
check "параметры своей для сайта" eq "$(site_opts "macos (ALT2)")" "--dpi-desync=multidisorder --dpi-desync-split-pos=1"
printf 'example.com\tmacos (ALT3)\n' > "$SITES"
nfqws_conf "nfqws general" "$c"
check "профиль сайта первый" eq "$(head -2 "$c" | tr '\n' ' ')" "--filter-tcp=80,443 --hostlist=$RT/lists/site-1.txt "
check "в профиле сайта — его стратегия" eq "$(sed -n 3,4p "$c" | tr '\n' ' ')" "--dpi-desync=multidisorder --dpi-desync-split-pos=2,sniext+1 "
check "список сайта" eq "$(cat "$RT/lists/site-1.txt")" example.com
: > "$SITES"
nfqws_site_conf "--dpi-desync=fake --dpi-desync-fake-tls=@BASE@/bin/x.bin" "$TMP/s.txt" "$c"
check "конфиг для пробы сайта" eq "$(tr '\n' ' ' < "$c")" "--filter-tcp=80,443 --hostlist=$TMP/s.txt --dpi-desync=fake --dpi-desync-fake-tls=$RT/nfqws/bin/x.bin "

# deep search
check "глубокий подбор: больше 80 вариантов" eval '[ "$(deep_candidates | wc -l)" -gt 80 ]'
check "глубокий подбор: без повторов" eq "$(deep_candidates | sort | uniq -d)" ""
check "глубокий подбор: без кавычек и пробелов в путях" eval '! deep_candidates | grep -q "[\"'"'"']"'

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

# releases
check "версия из редиректа" eq "$(printf 'HTTP/2 302\r\nLocation: https://github.com/a/b/releases/tag/v3.1.0\r\n\r\n' | release_of)" 3.1.0
check "без релиза — пусто" eq "$(printf 'HTTP/2 302\r\nlocation: https://github.com/a/b/releases\r\n' | release_of)" ""
check "номер версии" valid_version 3.0.0
check "не номер версии" eval '! valid_version "3.0; rm -rf /"'
echo 3.1.0 > "$RT/previous"
check "предыдущая 3.1" eq "$(VERSION=3.1.1 previous_version)" 3.1.0
echo 3.0.0 > "$RT/previous"
check "к неподписанной 3.0 не вернуться" eq "$(VERSION=3.1.1 previous_version)" ""
rm -f "$RT/previous"

# signed releases
ssh-keygen -q -t ed25519 -N "" -C test -f "$TMP/key"
RELEASE_KEY=$(cut -d' ' -f1,2 "$TMP/key.pub")
echo "архив" > "$TMP/a.tar.gz"
ssh-keygen -q -Y sign -f "$TMP/key" -n zapret-release "$TMP/a.tar.gz"
check "подпись сходится" verify_release "$TMP/a.tar.gz" "$TMP/a.tar.gz.sig"
echo "подмена" >> "$TMP/a.tar.gz"
check "подменённый архив не проходит" eval '! verify_release "$TMP/a.tar.gz" "$TMP/a.tar.gz.sig"'
ssh-keygen -q -t ed25519 -N "" -C other -f "$TMP/other"
echo "архив" > "$TMP/b.tar.gz"
ssh-keygen -q -Y sign -f "$TMP/other" -n zapret-release "$TMP/b.tar.gz"
check "чужой ключ не проходит" eval '! verify_release "$TMP/b.tar.gz" "$TMP/b.tar.gz.sig"'
rm -f "$TMP/b.tar.gz.sig"
ssh-keygen -q -Y sign -f "$TMP/key" -n file "$TMP/b.tar.gz" </dev/null
check "подпись для другого назначения не проходит" eval '! verify_release "$TMP/b.tar.gz" "$TMP/b.tar.gz.sig"'
check "3.0 не подписана" eval '! signed_version 3.0.0'
check "3.1 подписана" signed_version 3.1.0

# moving from 2.x: zapret of bol-van that we installed goes away, the strategy name moves
mkdir -p "$LEGACY/init.d/macos/custom.d"
ln -s "$LEGACY/init.d/macos/zapret.plist" "$LEGACY_PLIST"
printf '# zapret-macos: nfqws general (ALT6)\nMODE_FILTER=none\n' > "$LEGACY/config"
echo MODE_FILTER=none > "$LEGACY/config.default"
cp "$LEGACY/config.default" "$LEGACY/config.bak-before-macos"
printf 'a.com\tgeneral (ALT3)\nb.com\tmacos\n' > "$SITES"
printf 'a.com\nb.com\n' > "$SITES_TESTED"
rm -f "$CURRENT" "$RT/legacy-done"
migrate_legacy
check "переезд: стратегия перенесена" eq "$(current)" "nfqws general (ALT6)"
check "переезд: свой zapret удалён" eval '[ ! -d "$LEGACY" ]'
check "переезд: его служба удалена" eval '[ ! -L "$LEGACY_PLIST" ]'
check "переезд: стратегии tpws для сайтов убраны" eq "$(cat "$SITES")" $'b.com\tmacos'
check "переезд: такие сайты подберутся заново" eq "$(cat "$SITES_TESTED")" b.com
mkdir -p "$LEGACY"
printf '# zapret-macos: general (ALT6)\nMODE_FILTER=hostlist\n' > "$LEGACY/config"
echo MODE_FILTER=none > "$LEGACY/config.default"
echo MODE_FILTER=ipset > "$LEGACY/config.bak-before-macos"
rm -f "$CURRENT" "$RT/legacy-done"
migrate_legacy
check "переезд: стратегия tpws не переносится" eq "$(current)" ""
check "переезд: чужой zapret остаётся" eval '[ -d "$LEGACY" ]'
check "переезд: его конфиг возвращается" eq "$(cat "$LEGACY/config")" MODE_FILTER=ipset
rm -rf "$LEGACY"; mkdir -p "$LEGACY"
echo MODE_FILTER=none > "$LEGACY/config.default"
echo MODE_FILTER=hostlist > "$LEGACY/config.bak-before-flowseal"
echo TPWS_ENABLE=1 > "$LEGACY/config.bak-before-macos"
echo TPWS_ENABLE=1 > "$LEGACY/config"
rm -f "$RT/legacy-done"
migrate_legacy
check "переезд: возвращается самая ранняя копия" eq "$(cat "$LEGACY/config")" MODE_FILTER=hostlist
check "переезд: копии убраны" eval '[ ! -e "$LEGACY/config.bak-before-flowseal" ] && [ ! -e "$LEGACY/config.bak-before-macos" ]'
rm -f "$RT/legacy-done"
migrate_legacy
check "переезд второй раз: свой zapret остаётся" eval '[ -d "$LEGACY" ]'
check "переезд второй раз: его конфиг не тронут" eq "$(cat "$LEGACY/config")" MODE_FILTER=hostlist
cp "$LEGACY/config.default" "$LEGACY/config.bak-before-macos"
migrate_legacy
check "переезд только один раз" eval '[ -d "$LEGACY" ]'
rm -rf "$LEGACY"; : > "$SITES"; : > "$SITES_TESTED"

# the order of a check: the running one, those that worked, the rest
echo "macos (ALT3)" > "$CURRENT"
printf 'nfqws general (ALT5)\ngeneral (ALT6)\nmacos (ALT3)\n' > "$WORKED"
o=$(strategy_names | check_order)
check "порядок: сначала текущая" eq "$(sed -n 1p <<<"$o")" "macos (ALT3)"
check "порядок: потом сработавшие" eq "$(sed -n 2p <<<"$o")" "nfqws general (ALT5)"
check "порядок: потом остальные" eq "$(sed -n 3p <<<"$o")" "nfqws general"
check "порядок: каждая один раз, исчезнувших нет" eq "$(wc -l <<<"$o" | tr -d ' ')" 37
o=$(windows_names | check_order)
check "порядок --quick: только Windows-версии" eq "$(sed -n 1p <<<"$o")" "nfqws general (ALT5)"
rm -f "$CURRENT" "$WORKED"
check "хорошая: всё, голос, 2 МБ/с" good_enough 4/4 2097152 1
check "без голоса — ищем дальше" eval '! good_enough 4/4 2097152 0'
check "медленная — ищем дальше" eval '! good_enough 4/4 300000 1'
check "не всё открылось — ищем дальше" eval '! good_enough 3/4 2097152 1'

# messages in the user's language
check "по-русски" eq "$(msg "Обновлено до %s" 3.1.0)" "Обновлено до 3.1.0"
UI=en
check "по-английски" eq "$(msg "Обновлено до %s" 3.1.0)" "Updated to 3.1.0"
check "без перевода — как есть" eq "$(msg "Такой строки нет %s" x)" "Такой строки нет x"
check "русские строки не равны в английской локали" eq "$(LANG=en_US.UTF-8 msg "Такой строки нет %s" x)" "Такой строки нет x"
check "ok по-английски" has "$(ok "%s открывается" example.com)" "example.com opens"
check "аргумент с процентом не ломает формат" has "$(ok "%s открывается" "100%s")" "100%s opens"
UI=ru

# the best strategy
check "первая — лучшая" better "general" 100 0 "" 0 -1
check "голос важнее скорости" better "general (ALT)" 100 1 "general" 900 0
check "без голоса не обгоняет с голосом" eval '! better "general (ALT)" 900 0 "general" 100 1'
check "заметно быстрее — лучше" better "general (ALT)" 160 1 "general" 100 1
check "чуть быстрее — нет" eval '! better "general (ALT)" 120 1 "general" 100 1'
check "Windows-версия обгоняет свою на равных" better "nfqws general" 90 1 "macos" 100 1
check "своя не обгоняет Windows-версию на равных" eval '! better "macos" 110 1 "nfqws general" 100 1'
check "Windows-версия не обгоняет заметно быструю свою" eval '! better "nfqws general" 50 1 "macos" 100 1'

echo "unit: $passed прошло, $failed не прошло"
[ $failed = 0 ]
