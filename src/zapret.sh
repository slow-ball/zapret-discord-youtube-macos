#!/bin/bash
# zapret-discord-youtube-macos — управление zapret (bol-van, режим tpws) на macOS.
# Запуск без аргументов открывает меню. Команды: см. usage().

SRC=$(cd "$(dirname "$0")" && pwd)
SELF="$SRC/$(basename "$0")"
Z=/opt/zapret
RT=/opt/zapret-macos          # копия скриптов, принадлежащая root: её вызывают launchd и иконка в меню
REPO=slow-ball/zapret-discord-youtube-macos
ZVER=v72.13
ZSHA256=25c74e6c5f48963fa244c2955e76694a07c39447245a0457e2efdc74b3317e68
WD_LABEL=com.zapret-macos.watchdog
WD_PLIST=/Library/LaunchDaemons/$WD_LABEL.plist
LOG=/var/log/zapret-macos.log
TEST_PORT=19870

if [ "$SRC" = "$RT" ]; then
	PROJECT=$(cat "$RT/project" 2>/dev/null)
else
	PROJECT=$(dirname "$SRC")
fi
STRATS="$SRC/strategies.conf"
VERSION=$(cat "$SRC/VERSION" 2>/dev/null)

TESTS="https://www.youtube.com/
https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg
https://redirector.googlevideo.com/generate_204
https://discord.com/"

if [ -t 1 ]; then
	B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
fi
ok()   { echo "  ${G}✓${N} $*"; }
bad()  { echo "  ${R}✗${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
die()  { echo "${R}$*${N}" >&2; exit 1; }
log()  { echo "$(date '+%F %T') $*" >> "$LOG"; }

# ---------- helpers ----------

need_root()
{
	[ "$(id -u)" = 0 ] || exec sudo "$SELF" "$@"
}

console_user()
{
	local u=${SUDO_USER:-$(stat -f %Su /dev/console)}
	[ "$u" = root ] && u=$(stat -f %Su /dev/console)
	echo "$u"
}

# run a command as the logged in user (inside their GUI session when we are root)
as_user()
{
	local u
	if [ "$(id -u)" = 0 ]; then
		u=$(console_user)
		[ -n "$u" ] && [ "$u" != root ] || return 1
		launchctl asuser "$(id -u "$u")" sudo -H -u "$u" "$@"
	else
		"$@"
	fi
}

notify()
{
	as_user osascript -e "display notification \"$1\" with title \"zapret\"" >/dev/null 2>&1
}

strategy_names()
{
	grep -vE '^\s*(#|$)' "$STRATS" | cut -d'|' -f1
}

strategy_opts()
{
	grep -vE '^\s*(#|$)' "$STRATS" | awk -F'|' -v n="$1" '$1 == n { print $2; exit }'
}

installed()  { [ -x "$Z/tpws/tpws" ] && [ -f "$Z/init.d/macos/zapret" ]; }

# stops zapret and kills a tpws that lost its pidfile: it would keep the port and the old options
zapret_stop()
{
	"$Z/init.d/macos/zapret" stop >/dev/null 2>&1
	pkill -f -- '--pidfile=/var/run/tpws1.pid'
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do running || return 0; sleep 0.2; done
	pkill -9 -f -- '--pidfile=/var/run/tpws1.pid'
}
running()    { pgrep -qf -- '--pidfile=/var/run/tpws1.pid'; }
current()    { sed -nE 's/^# zapret-mac(os)?: //p' "$Z/config" 2>/dev/null | head -1; }
vpn_active() { netstat -rn -f inet | grep -qE '^(0/1|default) +[^ ]+ +[^ ]+ +utun'; }
autostart_on()  { ! launchctl print-disabled system 2>/dev/null | grep -qE '"zapret" => (true|disabled)'; }
watchdog_on()   { [ -f "$WD_PLIST" ]; }
menubar_dir()   { as_user defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null; }
menubar_on()    { local d; d=$(menubar_dir); [ -n "$d" ] && [ -L "$d/zapret.10s.sh" ]; }
all_sites()     { [ "$(cat "$RT/scope" 2>/dev/null)" != lists ]; }

remote_version()
{
	curl -fsSL -m 4 "https://raw.githubusercontent.com/$REPO/main/src/VERSION" 2>/dev/null | head -1
}

# true if $1 is a newer version than $2
newer()
{
	[ -n "$1" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# copy scripts into the root-owned runtime dir used by launchd and the menu bar icon
sync_runtime()
{
	[ "$SRC" = "$RT" ] && return
	mkdir -p "$RT"
	cp "$SRC/zapret.sh" "$SRC/strategies.conf" "$SRC/90-block-quic" "$SRC/menubar.sh" "$SRC/VERSION" \
		"$SRC/list-general.txt" "$SRC/list-exclude.txt" "$RT/"
	echo "$PROJECT" > "$RT/project"
	chown -R root:wheel "$RT"
	chmod 755 "$RT" "$RT/zapret.sh" "$RT/menubar.sh"
}

# test URLs through an optional socks proxy port. prints "passed/total youtube_bytes_per_sec"
probe()
{
	local port=$1 url out code size speed pass=0 total=0 yt=0 proxy=()
	[ -n "$port" ] && proxy=(--socks5-hostname "127.0.0.1:$port")
	for url in $TESTS; do
		total=$((total + 1))
		out=$(curl -s -o /dev/null -m 8 "${proxy[@]}" -w "%{http_code} %{size_download} %{speed_download}" "$url")
		read -r code size speed <<<"$out"
		size=${size%.*}; speed=${speed%.*}
		[ "${code:-000}" = 000 ] && continue
		if [ "$url" = "https://www.youtube.com/" ]; then
			# DPI often lets the first ~16 KB through and then stalls the connection
			[ "${size:-0}" -lt 300000 ] && continue
			yt=${speed:-0}
		fi
		pass=$((pass + 1))
	done
	echo "$pass/$total $yt"
}

# ---------- install / apply ----------

cmd_install()
{
	need_root install "$@"
	if installed; then
		echo "zapret уже установлен в $Z."
		[ -f "$Z/config.bak-before-macos" ] || cp "$Z/config" "$Z/config.bak-before-macos"
	else
		echo "${B}Скачиваю zapret $ZVER (bol-van)…${N}"
		local tmp
		tmp=$(mktemp -d)
		trap 'rm -rf "$tmp"' EXIT
		curl -fL --progress-bar -o "$tmp/z.tar.gz" \
			"https://github.com/bol-van/zapret/releases/download/$ZVER/zapret-$ZVER.tar.gz" || die "Не удалось скачать zapret"
		echo "$ZSHA256  $tmp/z.tar.gz" | shasum -a 256 -c --status || die "Контрольная сумма не совпала, установка отменена"
		tar -xzf "$tmp/z.tar.gz" -C "$tmp" || die "Не удалось распаковать архив"
		mkdir -p /opt
		cp -R "$tmp/zapret-$ZVER" "$Z" || die "Не удалось скопировать в $Z"
		chown -R root:wheel "$Z"
		"$Z/install_bin.sh" >/dev/null || die "install_bin.sh не смог подобрать бинарники"
		cp "$Z/config.default" "$Z/config"
		ln -fs "$Z/init.d/macos/zapret.plist" /Library/LaunchDaemons/zapret.plist
		ok "zapret установлен, автозапуск включён"
	fi
	# files from a browser-downloaded ZIP are quarantined; one approval of zapret.command is enough
	xattr -dr com.apple.quarantine "$PROJECT" 2>/dev/null
	cmd_start general
}

cmd_start()
{
	need_root start "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local name=${1:-$(current)} opts
	name=${name:-general}
	opts=$(strategy_opts "$name")
	[ -n "$opts" ] || die "Нет стратегии «$name»"
	# shellcheck disable=SC2086
	"$Z/tpws/tpws" --port=$TEST_PORT --dry-run $opts >/dev/null 2>&1 || die "tpws не принимает: $opts"

	sync_runtime
	[ -f "$Z/config.bak-before-macos" ] || cp "$Z/config" "$Z/config.bak-before-macos"
	[ -d "$PROJECT/lists" ] || warn "папка проекта не найдена ($PROJECT) — свои списки не подключены. Запустить zapret.command из новой папки."
	{ cat "$RT/list-general.txt"; echo; cat "$PROJECT/lists/list-user.txt" 2>/dev/null; } > "$Z/ipset/zapret-hosts-user.txt"
	{ cat "$RT/list-exclude.txt"; echo; cat "$PROJECT/lists/list-exclude-user.txt" 2>/dev/null; } > "$Z/ipset/zapret-hosts-user-exclude.txt"
	cp "$RT/90-block-quic" "$Z/init.d/macos/custom.d/90-block-quic"

	# all sites: no hostlist filter, but the exclude list still applies
	local hl="<HOSTLIST>" filter=hostlist
	if all_sites; then
		hl="--hostlist-exclude=$Z/ipset/zapret-hosts-user-exclude.txt"
		filter=none
	fi
	OPT="
--filter-tcp=80 --methodeol $hl --new
--filter-tcp=443 $opts $hl
" NAME="$name" FILTER="$filter" /usr/bin/python3 -I - "$Z/config" <<'EOF' || die "Не удалось изменить $Z/config"
import os, re, sys
path = sys.argv[1]
opt = os.environ["OPT"]
text = open(path).read()
# hostlist mode adds the exclude list itself
text = re.sub(r'^TPWS_OPT="\$TPWS_OPT --hostlist-exclude=.*\n', '', text, flags=re.M)
for var in ("TPWS_OPT", "TPWS_SOCKS_OPT"):
    text = re.sub(r'^%s="[^"$]*"' % var, lambda m: '%s="%s"' % (var, opt), text, flags=re.M)
for var, val in (("MODE_FILTER", os.environ["FILTER"]), ("TPWS_ENABLE", "1"),
                 ("GZIP_LISTS", "0"),      # pf can't read gzipped lists
                 ("DISABLE_IPV6", "0")):   # otherwise YouTube over IPv6 bypasses tpws
    text = re.sub(r'^%s=.*$' % var, '%s=%s' % (var, val), text, flags=re.M)
text = re.sub(r'^# zapret-(mac|macos): .*\n', '', text, flags=re.M)
text = "# zapret-macos: %s\n" % os.environ["NAME"] + text
open(path, "w").write(text)
EOF

	zapret_stop
	"$Z/init.d/macos/zapret" start >/dev/null 2>&1
	sleep 0.5
	if running; then
		ok "zapret запущен: ${B}$name${N}"
		echo "  ${D}Перезапустить браузер (Cmd+Q), чтобы сбросились старые соединения.${N}"
		notify "Запущен: $name"
		log "start $name"
	else
		bad "zapret не запустился. Подробности — в диагностике."
		notify "Не удалось запустить"
		return 1
	fi
}

cmd_stop()
{
	need_root stop
	zapret_stop
	if running; then
		bad "zapret всё ещё работает"
	else
		ok "zapret остановлен"
		notify "Остановлен"
		log stop
	fi
}

# all sites or only YouTube, Discord and the user's list
cmd_scope()
{
	need_root scope "$@"
	local s=$1
	if [ -z "$s" ]; then if all_sites; then s=lists; else s=all; fi; fi
	case "$s" in
		all)   rm -f "$RT/scope"; ok "zapret обрабатывает все сайты (кроме исключений)" ;;
		lists) mkdir -p "$RT"; echo lists > "$RT/scope"; ok "zapret обрабатывает только YouTube, Discord и свои списки" ;;
		*)     die "scope: all или lists" ;;
	esac
	if running; then cmd_start; fi
}

# ---------- check (strategy search) ----------

# tests every strategy in parallel through temporary socks instances of tpws.
# both tpws (--user=root) and curl run as root, so the system pf redirect doesn't touch them
# and the running zapret can stay up.
cmd_check()
{
	need_root check "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local auto=0 quiet=0 a
	for a in "$@"; do
		case "$a" in --auto) auto=1 ;; --quiet) quiet=1; auto=1 ;; esac
	done
	if vpn_active; then
		[ $quiet = 1 ] && return 1
		die "Включён VPN — его нужно выключить, иначе проверка покажет не провайдера, а VPN."
	fi

	local tmp n=0 pids=() name base
	tmp=$(mktemp -d)
	[ $quiet = 1 ] || echo "${B}Проверка без zapret…${N}"
	base=$(probe "")
	[ $quiet = 1 ] || echo "  открылось ${base% *} — дальше проверяю стратегии параллельно"

	while IFS= read -r name; do
		n=$((n + 1))
		(
			# shellcheck disable=SC2046
			"$Z/tpws/tpws" --socks --user=root --bind-addr=127.0.0.1 --port=$((TEST_PORT + n)) \
				$(strategy_opts "$name") >/dev/null 2>&1 &
			tp=$!
			sleep 0.5
			probe $((TEST_PORT + n)) > "$tmp/$n"
			kill $tp 2>/dev/null
		) &
		pids+=($!)
	done < <(strategy_names)
	wait "${pids[@]}"

	# the parallel run decides pass/fail; speed is measured again one by one for the winners
	local best="" best_speed=-1 res pass yt
	n=0
	[ $quiet = 1 ] || echo
	while IFS= read -r name; do
		n=$((n + 1))
		res=$(cat "$tmp/$n" 2>/dev/null)
		pass=${res% *}
		if [ "${pass%/*}" = "${pass#*/}" ]; then
			# shellcheck disable=SC2046
			"$Z/tpws/tpws" --socks --user=root --bind-addr=127.0.0.1 --port=$TEST_PORT \
				$(strategy_opts "$name") >/dev/null 2>&1 &
			local tp=$!
			sleep 0.3
			yt=$(probe $TEST_PORT); yt=${yt#* }
			kill $tp 2>/dev/null; wait $tp 2>/dev/null
			[ $quiet = 1 ] || ok "$(printf '%-16s %s  %5s КБ/с' "$name" "$pass" $((yt / 1024)))"
			# speeds are noisy: prefer the earlier strategy unless another one is clearly faster
			if [ -z "$best" ] || [ "$yt" -gt $((best_speed * 3 / 2)) ]; then best=$name; best_speed=$yt; fi
		else
			[ $quiet = 1 ] || echo "  ${D}✗ $(printf '%-16s %s' "$name" "$pass")${N}"
		fi
	done < <(strategy_names)
	rm -rf "$tmp"

	if [ -z "$best" ]; then
		[ $quiet = 1 ] || { echo; bad "Ни одна стратегия не прошла все проверки."; echo "  Можно создать Issue на GitHub и приложить этот вывод и вывод диагностики."; }
		return 1
	fi
	[ $quiet = 1 ] || { echo; echo "Лучшая: ${B}$best${N} ($((best_speed / 1024)) КБ/с)"; }
	if [ $auto = 0 ]; then
		read -r -p "Применить? [Y/n] " a
		case "$a" in n|N) return 0 ;; esac
	fi
	if [ "$best" = "$(current)" ] && running; then
		[ $quiet = 1 ] || ok "Она уже включена."
	else
		cmd_start "$best"
	fi
	# watchdog reads the chosen name from the last line
	[ $quiet = 1 ] && echo "$best"
	return 0
}

# ---------- diagnostics ----------

cmd_diag()
{
	need_root diag
	local u p rv
	echo "${B}zapret-discord-youtube-macos $VERSION${N}, macOS $(sw_vers -productVersion), $(uname -m)"
	echo

	echo "${B}zapret${N}"
	if installed; then ok "установлен ($("$Z/tpws/tpws" --version 2>&1 | head -1))"; else bad "не установлен — запустить zapret.command"; fi
	if running; then ok "работает, стратегия: $(current)"; else bad "не запущен"; fi
	if autostart_on; then ok "автозапуск включён"; else warn "автозапуск выключен"; fi
	if watchdog_on; then ok "автопочинка включена"; else echo "  ${D}· автопочинка выключена${N}"; fi
	if all_sites; then ok "обрабатываются все сайты"; else ok "обрабатываются YouTube, Discord и свои списки"; fi
	if pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then ok "файрвол pf включён"; else bad "файрвол pf выключен — перезапустить стратегию"; fi
	if pfctl -a zapret-v4 -s rules 2>/dev/null | grep -q 'proto udp.*port = 443'; then
		ok "QUIC заблокирован (браузер пойдёт через TCP)"
	elif running; then
		bad "блокировка QUIC не загружена — перезапустить стратегию"
	fi
	echo

	echo "${B}Сеть${N}"
	if vpn_active; then warn "включён VPN — пока он работает, zapret не участвует"; else ok "VPN не обнаружен"; fi
	if scutil --proxy | grep -qE '(HTTP|HTTPS|SOCKS)Enable : 1'; then
		warn "в системе настроен прокси — трафик может идти мимо zapret"
	else
		ok "системный прокси не настроен"
	fi
	for p in spoofdpi ciadpi byedpi goodbyedpi warp-svc sing-box xray v2ray mihomo clash hiddify nekoray; do
		pgrep -qix "$p" && warn "запущен $p — может конфликтовать с zapret"
	done
	if ifconfig | grep -q 'inet6 2[0-9a-f]*:'; then ok "есть IPv6 — zapret обрабатывает и его"; fi
	u=$(dig +short +time=2 +tries=1 www.youtube.com 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
	case "$u" in
		"") warn "DNS не ответил на www.youtube.com" ;;
		0.0.0.0|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) bad "DNS подменяет YouTube ($u) — указать 1.1.1.1 / 8.8.8.8 в настройках сети" ;;
		*) ok "DNS отвечает нормально ($u)" ;;
	esac
	echo

	echo "${B}Доступность (как в браузере)${N}"
	for p in https://www.youtube.com/ https://redirector.googlevideo.com/generate_204 https://discord.com/; do
		if as_user curl -s -o /dev/null -m 8 "$p"; then ok "$p"; else bad "$p"; fi
	done
	echo

	rv=$(remote_version)
	if newer "$rv" "$VERSION"; then warn "доступно обновление: $rv"; elif [ -n "$rv" ]; then ok "последняя версия"; fi
	echo
	echo "${D}Если YouTube в браузере всё равно тормозит: перезапустить браузер; в Chrome выключить «Безопасный DNS»"
	echo "и QUIC (chrome://flags/#enable-quic → Disabled); в Safari выключить iCloud Private Relay.${N}"
}

# ---------- autostart / watchdog ----------

cmd_autostart()
{
	need_root autostart "$@"
	case "$1" in
		on)  launchctl enable system/zapret && ok "автозапуск включён" ;;
		off) launchctl disable system/zapret && ok "автозапуск выключен" ;;
		*)   if autostart_on; then cmd_autostart off; else cmd_autostart on; fi ;;
	esac
}

cmd_watchdog()
{
	case "$1" in
		on)
			need_root watchdog on
			sync_runtime
			cat > "$WD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$WD_LABEL</string>
	<key>ProgramArguments</key><array><string>$RT/zapret.sh</string><string>watchdog</string><string>run</string></array>
	<key>StartInterval</key><integer>300</integer>
	<key>RunAtLoad</key><false/>
</dict>
</plist>
EOF
			launchctl bootout system/$WD_LABEL 2>/dev/null
			launchctl bootstrap system "$WD_PLIST" && ok "автопочинка включена: проверка каждые 5 минут"
			;;
		off)
			need_root watchdog off
			launchctl bootout system/$WD_LABEL 2>/dev/null
			rm -f "$WD_PLIST" "$RT/watchdog.fails"
			ok "автопочинка выключена"
			;;
		run)
			watchdog_run
			;;
		*)
			if watchdog_on; then cmd_watchdog off; else cmd_watchdog on; fi
			;;
	esac
}

# called by launchd as root every 5 minutes
watchdog_run()
{
	local fails new
	running || return 0
	vpn_active && return 0
	[ "$(stat -f %Su /dev/console)" = root ] && return 0
	# check the real path: as the user, through pf and the running tpws
	if as_user curl -s -o /dev/null -m 8 https://www.youtube.com/ &&
		as_user curl -s -o /dev/null -m 8 https://redirector.googlevideo.com/generate_204; then
		rm -f "$RT/watchdog.fails"
		return 0
	fi
	# no internet at all is not our problem
	curl -s -o /dev/null -m 8 https://www.apple.com/ || return 0
	fails=$(( $(cat "$RT/watchdog.fails" 2>/dev/null || echo 0) + 1 ))
	echo $fails > "$RT/watchdog.fails"
	log "watchdog: YouTube недоступен ($fails)"
	[ $fails -ge 2 ] || return 0
	rm -f "$RT/watchdog.fails"
	local old
	old=$(current)
	new=$(cmd_check --quiet | tail -1)
	if [ -n "$new" ] && [ "$new" != "$old" ]; then
		log "watchdog: $old → $new"
		notify "«$old» перестала работать, включена «$new»"
	elif [ -z "$new" ]; then
		log "watchdog: рабочая стратегия не найдена"
		notify "YouTube недоступен, рабочая стратегия не найдена"
	fi
}

# ---------- menu bar icon (SwiftBar) ----------

cmd_menubar()
{
	if [ "$(id -u)" = 0 ]; then
		as_user "$SELF" menubar "$@"
		return
	fi
	local dir
	case "$1" in
		off)
			dir=$(menubar_dir)
			[ -n "$dir" ] && rm -f "$dir/zapret.10s.sh"
			open -g "swiftbar://refreshallplugins" 2>/dev/null
			ok "иконка убрана"
			return
			;;
	esac
	[ -x "$RT/menubar.sh" ] || die "Сначала нужно запустить zapret"
	if [ ! -d /Applications/SwiftBar.app ]; then
		echo "Ставлю SwiftBar (бесплатная программа для иконок в строке меню)…"
		local tmp url
		tmp=$(mktemp -d)
		url=$(curl -fsSL https://api.github.com/repos/swiftbar/SwiftBar/releases/latest |
			/usr/bin/python3 -I -c 'import json,sys; print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith(".zip")))') ||
			die "Не удалось найти SwiftBar. Установить вручную: https://swiftbar.app"
		curl -fL --progress-bar -o "$tmp/sb.zip" "$url" || die "Не удалось скачать SwiftBar"
		ditto -x -k "$tmp/sb.zip" /Applications || die "Не удалось распаковать SwiftBar в /Applications"
		rm -rf "$tmp"
	fi
	dir=$(menubar_dir)
	if [ -z "$dir" ]; then
		dir="$HOME/Library/Application Support/zapret-macos/menubar"
		defaults write com.ameba.SwiftBar PluginDirectory "$dir"
	fi
	mkdir -p "$dir"
	ln -sf "$RT/menubar.sh" "$dir/zapret.10s.sh"
	open -a SwiftBar
	open -g "swiftbar://refreshallplugins" 2>/dev/null
	ok "иконка добавлена в строку меню"
}

# runs a command with the macOS admin password dialog (used by the menu bar icon)
cmd_gui()
{
	if [ "$(id -u)" = 0 ]; then "$SELF" "$@"; return; fi
	osascript - "$SELF" "$@" <<'EOF' >/dev/null 2>&1
on run argv
	set cmd to ""
	repeat with a in argv
		set cmd to cmd & quoted form of (a as text) & " "
	end repeat
	do shell script cmd with administrator privileges
end run
EOF
}

# ---------- update / restore / uninstall ----------

cmd_update()
{
	local rv tmp
	rv=$(remote_version)
	[ -n "$rv" ] || die "Не удалось проверить обновления (GitHub недоступен?)"
	if ! newer "$rv" "$VERSION"; then ok "Установлена последняя версия ($VERSION)"; return; fi
	echo "Обновляю $VERSION → ${B}$rv${N}"
	if [ -d "$PROJECT/.git" ]; then
		as_user git -C "$PROJECT" pull --ff-only || die "git pull не удался"
	else
		tmp=$(as_user mktemp -d) || tmp=$(mktemp -d)
		as_user curl -fsSL -o "$tmp/u.tar.gz" "https://github.com/$REPO/archive/refs/heads/main.tar.gz" || die "Не удалось скачать"
		as_user tar -xzf "$tmp/u.tar.gz" -C "$tmp" || die "Не удалось распаковать"
		# свои списки не трогаем
		as_user rsync -a --exclude lists/list-user.txt --exclude lists/list-exclude-user.txt \
			"$tmp/zapret-discord-youtube-macos-main/" "$PROJECT/" || die "Не удалось обновить файлы"
		rm -rf "$tmp"
	fi
	ok "Файлы обновлены"
	if running; then
		echo "Перезапускаю zapret с новыми списками…"
		if [ "$(id -u)" = 0 ]; then "$PROJECT/src/zapret.sh" start "$(current)"; else sudo "$PROJECT/src/zapret.sh" start "$(current)"; fi
	fi
}

cmd_restore()
{
	need_root restore
	[ -f "$Z/config.bak-before-macos" ] || die "Резервной копии нет"
	cp "$Z/config.bak-before-macos" "$Z/config"
	rm -f "$Z/init.d/macos/custom.d/90-block-quic"
	zapret_stop
	"$Z/init.d/macos/zapret" start >/dev/null 2>&1
	ok "Исходный конфиг zapret восстановлен"
}

cmd_uninstall()
{
	need_root uninstall
	local a
	read -r -p "Удалить zapret полностью (служба, правила файрвола, /opt/zapret)? [y/N] " a
	case "$a" in y|Y) ;; *) return ;; esac
	watchdog_on && cmd_watchdog off
	cmd_menubar off >/dev/null 2>&1
	[ -x "$Z/uninstall_easy.sh" ] && "$Z/uninstall_easy.sh" >/dev/null 2>&1
	rm -f /Library/LaunchDaemons/zapret.plist
	rm -rf "$Z" "$RT"
	ok "zapret удалён. Папку проекта можно удалить вручную."
}

# ---------- status / menu ----------

cmd_status()
{
	if running; then echo "${G}●${N} работает: ${B}$(current)${N}"; else echo "${R}●${N} остановлен"; fi
	printf "  сайты: %s · автозапуск: %s · автопочинка: %s · иконка: %s\n" \
		"$(all_sites && echo все || echo по спискам)" \
		"$(autostart_on && echo вкл || echo выкл)" \
		"$(watchdog_on && echo вкл || echo выкл)" \
		"$(menubar_on && echo вкл || echo выкл)"
}

pick_strategy()
{
	local names=() n i=0 c cur
	cur=$(current)
	while IFS= read -r n; do names+=("$n"); done < <(strategy_names)
	for n in "${names[@]}"; do
		i=$((i + 1))
		if [ "$n" = "$cur" ]; then printf "  %2d) %s ${G}(сейчас)${N}\n" $i "$n"; else printf "  %2d) %s\n" $i "$n"; fi
	done
	read -r -p "Номер: " c
	[[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#names[@]} ] && cmd_start "${names[$((c - 1))]}"
}

cmd_menu()
{
	need_root
	local rv c upd=""
	rv=$(remote_version)
	newer "$rv" "$VERSION" && upd=" ${Y}(доступно обновление $rv)${N}"
	while true; do
		echo
		echo "${B}zapret-discord-youtube-macos $VERSION${N}$upd"
		cmd_status
		echo
		echo "  1) Запустить / сменить стратегию"
		echo "  2) Остановить"
		echo "  3) Подобрать стратегию автоматически"
		echo "  4) Диагностика"
		echo "  5) Автозапуск при загрузке: вкл/выкл"
		echo "  6) Автопочинка (сама меняет стратегию, если YouTube отвалился): вкл/выкл"
		echo "  7) Иконка в строке меню: вкл/выкл"
		echo "  8) Сайты: все / только YouTube, Discord и свои списки"
		echo "  9) Мои списки доменов"
		echo " 10) Обновить"
		echo " 11) Вернуть исходный конфиг zapret"
		echo " 12) Удалить zapret"
		echo "  0) Выход"
		read -r -p "> " c
		echo
		case "$c" in
			1) pick_strategy ;;
			2) cmd_stop ;;
			3) cmd_check ;;
			4) cmd_diag ;;
			5) cmd_autostart ;;
			6) cmd_watchdog ;;
			7) if menubar_on; then cmd_menubar off; else cmd_menubar on; fi ;;
			8) cmd_scope ;;
			9) as_user open -t "$PROJECT/lists/list-user.txt" "$PROJECT/lists/list-exclude-user.txt"
			   echo "Открыты list-user.txt и list-exclude-user.txt. После правки — перезапустить стратегию (пункт 1)." ;;
			10) cmd_update; upd="" ;;
			11) cmd_restore ;;
			12) cmd_uninstall; installed || exit 0 ;;
			0|"") exit 0 ;;
		esac
	done
}

usage()
{
	cat <<EOF
zapret-discord-youtube-macos $VERSION

  zapret.sh                      меню (при первом запуске — установка)
  zapret.sh install              установить zapret и запустить general
  zapret.sh start [имя]          запустить стратегию (по умолчанию — текущую)
  zapret.sh stop                 остановить
  zapret.sh status               состояние
  zapret.sh list                 список стратегий
  zapret.sh check [--auto]       подобрать стратегию (--auto — применить лучшую без вопроса)
  zapret.sh diag                 диагностика
  zapret.sh autostart [on|off]   автозапуск при загрузке
  zapret.sh watchdog [on|off]    автопочинка
  zapret.sh menubar [on|off]     иконка в строке меню
  zapret.sh scope [all|lists]    все сайты или только YouTube, Discord и свои списки
  zapret.sh update               обновить проект
  zapret.sh restore              вернуть исходный конфиг zapret
  zapret.sh uninstall            удалить zapret
EOF
}

case "$1" in
	"" | menu)  need_root; if [ -x "$RT/zapret.sh" ]; then cmd_menu; else cmd_install && cmd_menu; fi ;;
	install)    shift; cmd_install "$@" ;;
	start)      shift; cmd_start "$@" ;;
	stop)       cmd_stop ;;
	status)     cmd_status ;;
	list)       strategy_names ;;
	check)      shift; cmd_check "$@" ;;
	diag)       cmd_diag ;;
	autostart)  shift; cmd_autostart "$@" ;;
	watchdog)   shift; cmd_watchdog "$@" ;;
	menubar)    shift; cmd_menubar "$@" ;;
	scope)      shift; cmd_scope "$@" ;;
	gui)        shift; cmd_gui "$@" ;;
	update)     cmd_update ;;
	restore)    cmd_restore ;;
	uninstall)  cmd_uninstall ;;
	*)          usage; exit 1 ;;
esac
