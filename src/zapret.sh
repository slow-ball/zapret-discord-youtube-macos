#!/bin/bash
# zapret-discord-youtube-macos — управление zapret на macOS.
# Два движка: tpws (zapret от bol-van) и nfqws с фейками (utunws из сборки Flowseal).
# Запуск без аргументов открывает меню. Команды: см. usage().

SRC=$(cd "$(dirname "$0")" && pwd)
SELF="$SRC/$(basename "$0")"
Z=/opt/zapret
RT=/opt/zapret-macos          # копия скриптов, принадлежащая root: её вызывают launchd и иконка в меню
REPO=slow-ball/zapret-discord-youtube-macos
ZVER=v72.13
ZSHA256=25c74e6c5f48963fa244c2955e76694a07c39447245a0457e2efdc74b3317e68
NQ_TAG=utunws-1               # наша сборка utunws (build/utunws.sh, workflow «utunws»)
NQ_SHA256=f4e94bc227c28413bcd92102f836f9aced642f612ab4793634e47027f5b59703
APPTAG=utunws-4               # релиз с zapret-app.zip (workflow «utunws»); пусто — приложение собирается из исходников
APPSHA256=490a7455ae6af705f95c2f4e9f009aa8ccaa8d54e7232871b0787b19e2527083
TGVER=v1.11.2                 # Flowseal/tg-ws-proxy: прокси для Telegram Desktop
TGSHA256=d159eece1b6331a06803fd193dc0ac8406022244f961793c1441b01f4b34cfac
TG_LABEL=com.zapret-macos.telegram
TG_PLIST=/Library/LaunchDaemons/$TG_LABEL.plist
WD_LABEL=com.zapret-macos.watchdog
WD_PLIST=/Library/LaunchDaemons/$WD_LABEL.plist
NQ_LABEL=com.zapret-macos.nfqws
NQ_PLIST=/Library/LaunchDaemons/$NQ_LABEL.plist
NQ_ANCHOR=com.apple/zapret-macos
NQ_READY=/var/run/zapret-macos.nfqws-ready
AUTO_LIST=$RT/lists/list-auto.txt     # sites the smart mode found blocked
SITES=$RT/site-strategies             # site<TAB>tpws strategy, filled by learn
SITES_TESTED=$RT/site-tested          # sites learn has already looked at
LOG=/var/log/zapret-macos.log
TEST_PORT=19870

if [ "$SRC" = "$RT" ]; then
	PROJECT=$(cat "$RT/project" 2>/dev/null)
else
	PROJECT=$(dirname "$SRC")
fi
STRATS="$SRC/strategies.conf"
NQ_STRATS="$SRC/nfqws/strategies.tsv"
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
	# the app tells about changes itself, with buttons
	pgrep -qx zapret && return 0
	as_user osascript -e "display notification \"$1\" with title \"zapret\"" >/dev/null 2>&1
}

# tpws strategies are lines of strategies.conf, nfqws ones are Flowseal's files listed in nfqws/strategies.tsv
tpws_names()
{
	grep -vE '^\s*(#|$)' "$STRATS" | cut -d'|' -f1
}

nfqws_names()
{
	awk -F'\t' 'NF == 2 { print "nfqws " $2 }' "$NQ_STRATS"
}

# nfqws first: the Windows version's strategies are the main ones
strategy_names()
{
	nfqws_names
	tpws_names
}

engine_of()  { case "$1" in "nfqws "*) echo nfqws ;; *) echo tpws ;; esac; }
nfqws_file() { awk -F'\t' -v n="${1#nfqws }" '$2 == n { print $1; exit }' "$NQ_STRATS"; }

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
	for i in 1 2 3 4 5 6 7 8 9 10; do tpws_running || return 0; sleep 0.2; done
	pkill -9 -f -- '--pidfile=/var/run/tpws1.pid'
}

nfqws_stop()
{
	launchctl bootout system/$NQ_LABEL 2>/dev/null
	# bootout returns before the job is gone, and bootstrap of a job still there fails
	local i
	for i in $(seq 25); do launchctl print system/$NQ_LABEL >/dev/null 2>&1 || break; sleep 0.2; done
	pkill -f -- "$RT/nfqws/run.sh"
	pkill -9 -x utunws
	pfctl -a $NQ_ANCHOR -F all >/dev/null 2>&1
	rm -f "$NQ_READY"
	# run.sh restores the TCP connect timeout itself, unless it was killed
	if [ -s /var/db/zapret-macos.keepinit ]; then
		sysctl -w net.inet.tcp.keepinit="$(cat /var/db/zapret-macos.keepinit)" >/dev/null
		rm -f /var/db/zapret-macos.keepinit
	fi
}

tpws_running()  { pgrep -qf -- '--pidfile=/var/run/tpws1.pid'; }
nfqws_running() { pgrep -qx utunws; }
running()    { tpws_running || nfqws_running; }
current()    { sed -nE 's/^# zapret-mac(os)?: //p' "$Z/config" 2>/dev/null | head -1; }
vpn_active() { netstat -rn -f inet | grep -qE '^(0/1|default) +[^ ]+ +[^ ]+ +utun'; }
# launchd job that starts the current engine at boot
boot_job()   { if [ "$(engine_of "$(current)")" = nfqws ]; then echo $NQ_LABEL; else echo zapret; fi; }
autostart_on()  { ! launchctl print-disabled system 2>/dev/null | grep -qE "\"$(boot_job)\" => (true|disabled)"; }
# the background job (launchd, every 5 minutes) runs while autofix or autoupdate is on
watchdog_on()   { [ -f "$RT/autofix" ]; }
autoupdate_on() { [ -f "$RT/autoupdate" ]; }
menubar_dir()   { as_user defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null; }
menubar_on()    { local d; d=$(menubar_dir); [ -n "$d" ] && [ -L "$d/zapret.10s.sh" ]; }
app_installed() { [ -d /Applications/zapret.app ]; }
# which sites are processed: all, smart (lists + found blocked ones) or lists
scope()         { local s; s=$(cat "$RT/scope" 2>/dev/null); echo "${s:-all}"; }
scope_name()    { case "$(scope)" in all) echo все ;; smart) echo умный ;; *) echo по спискам ;; esac; }
# game filter of the Windows version: nfqws also handles ports 1024-65535 of game servers. off, tcp, udp or all
game_mode()     { local g; g=$(cat "$RT/game" 2>/dev/null); echo "${g:-off}"; }
game_name()     { case "$(game_mode)" in tcp) echo TCP ;; udp) echo UDP ;; all) echo "TCP и UDP" ;; *) echo выкл ;; esac; }

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
		"$SRC/list-general.txt" "$SRC/list-google.txt" "$SRC/list-exclude.txt" "$SRC/ipset-exclude.txt" "$RT/"
	mkdir -p "$RT/nfqws" "$RT/telegram"
	cp -R "$SRC/nfqws/." "$RT/nfqws/"
	cp "$SRC/telegram/requirements.txt" "$SRC/telegram/check.py" "$RT/telegram/"
	echo "$PROJECT" > "$RT/project"
	install_sudoers
	# before 2.0 the job existed only for autofix
	[ -f "$WD_PLIST" ] && [ ! -f "$RT/autofix" ] && [ ! -f "$RT/autoupdate" ] && touch "$RT/autofix"
	chown -R root:wheel "$RT"
	chmod 755 "$RT" "$RT/zapret.sh" "$RT/menubar.sh" "$RT/nfqws/run.sh"
}

# the app runs these commands of the root-owned copy without a password. update is not among them:
# it runs the script from the project folder, which any program of the user can change
install_sudoers()
{
	local f=/etc/sudoers.d/zapret-macos tmp c
	tmp=$(mktemp)
	{
		echo "# zapret-discord-youtube-macos: приложение управляет zapret без пароля"
		printf '%%admin ALL=(root) NOPASSWD:'
		for c in start stop check scope game autostart watchdog autoupdate learn found diag telegram site dns; do
			printf ' %s %s, %s %s *,' "$RT/zapret.sh" $c "$RT/zapret.sh" $c
		done | sed 's/,$//'
		echo
	} > "$tmp"
	if visudo -c -q -f "$tmp" 2>/dev/null; then
		cmp -s "$tmp" "$f" || { install -m 440 -o root -g wheel "$tmp" "$f"; }
	fi
	rm -f "$tmp"
}

# lists for both engines: tpws reads the merged files in $Z/ipset, nfqws reads $RT/lists
write_lists()
{
	local l=$RT/lists
	[ -d "$PROJECT/lists" ] || warn "папка проекта не найдена ($PROJECT) — свои списки не подключены. Запустить zapret.command из новой папки."
	mkdir -p "$l"
	cp "$RT/list-general.txt" "$RT/list-google.txt" "$RT/list-exclude.txt" "$RT/ipset-exclude.txt" "$l/"
	cat "$PROJECT/lists/list-user.txt" 2>/dev/null > "$l/list-general-user.txt"
	cat "$PROJECT/lists/list-exclude-user.txt" 2>/dev/null > "$l/list-exclude-user.txt"
	: > "$l/ipset-exclude-user.txt"
	touch "$AUTO_LIST"
	: > "$l/ipset-any.txt"                        # empty ipset: every IPv4 address
	echo 203.0.113.113/32 > "$l/ipset-none.txt"   # documentation address: nothing
	chmod 755 "$l"; chmod 644 "$l"/*
	{ cat "$l/list-general.txt"; echo; cat "$l/list-general-user.txt"; } > "$Z/ipset/zapret-hosts-user.txt"
	{ cat "$l/list-exclude.txt"; echo; cat "$l/list-exclude-user.txt"; } > "$Z/ipset/zapret-hosts-user-exclude.txt"
	# tpws checks the lists after dropping root, zapret creates them readable only by root
	chmod 644 "$Z/ipset/zapret-hosts-user.txt" "$Z/ipset/zapret-hosts-user-exclude.txt"
}

# ---------- nfqws engine ----------

nfqws_installed() { [ -x "$RT/nfqws/bin/utunws" ] && [ "$(cat "$RT/nfqws/bin/VERSION" 2>/dev/null)" = "$NQ_TAG" ]; }

# utunws comes from our own build of Flowseal's sources (build/utunws.sh), checked against
# a pinned checksum. the fake payloads are in the project (nfqws/bin), next to the strategies
nfqws_install()
{
	nfqws_installed && return 0
	echo "${B}Скачиваю движок nfqws ($NQ_TAG)…${N}"
	local tmp ret=1
	tmp=$(mktemp -d)
	if ! curl -fL --progress-bar -o "$tmp/u.tar.gz" "https://github.com/$REPO/releases/download/$NQ_TAG/utunws.tar.gz"; then
		bad "Не удалось скачать nfqws"
	elif ! echo "$NQ_SHA256  $tmp/u.tar.gz" | shasum -a 256 -c --status; then
		bad "Контрольная сумма nfqws не совпала"
	elif ! mkdir "$tmp/x" || ! tar -xzf "$tmp/u.tar.gz" -C "$tmp/x"; then
		bad "Не удалось распаковать nfqws"
	else
		mkdir -p "$RT/nfqws/bin"
		cp "$tmp/x/bin/utunws" "$RT/nfqws/bin/"
		echo "$NQ_TAG" > "$RT/nfqws/bin/VERSION"
		chown -R root:wheel "$RT/nfqws"
		chmod 755 "$RT/nfqws/bin/utunws"
		ok "nfqws установлен"
		ret=0
	fi
	rm -rf "$tmp"
	return $ret
}

# fills Flowseal's placeholders: $1 strategy name, $2 output file
nfqws_conf()
{
	local f ipset=$RT/lists/ipset-none.txt auto=""
	f=$(nfqws_file "$1")
	[ -n "$f" ] && [ -f "$RT/nfqws/strategies/$f.conf.in" ] || return 1
	case "$(scope)" in
		all) ipset=$RT/lists/ipset-any.txt ;;
		# the profiles of the user's list also learn blocked sites. utunws sees only outgoing packets,
		# so it notices retransmissions (DPI drops the connection) but not resets
		smart) auto="--hostlist-auto=\"@LISTS@/list-auto.txt\"" ;;
	esac
	local g k
	g=$(game_mode)
	{
		awk -v a="$auto" '{ print } a != "" && $0 == "--hostlist=\"@LISTS@/list-general-user.txt\"" { print a }' \
			"$RT/nfqws/strategies/$f.conf.in"
		for k in tcp udp; do
			if { [ "$g" = all ] || [ "$g" = $k ]; } && [ -f "$RT/nfqws/strategies/$f.game-$k.conf.in" ]; then
				echo --new
				cat "$RT/nfqws/strategies/$f.game-$k.conf.in"
			fi
		done
	} | sed -e "s|@BASE@|$RT/nfqws|g" -e "s|@LISTS@|$RT/lists|g" -e "s|@IPSET@|$ipset|g" \
		-e "s|@GAME_TCP@|1024-65535|g" -e "s|@GAME_UDP@|1024-65535|g" -e "s|@GAMEIPSET@|$RT/nfqws/ipset-game.txt|g" > "$2"
}

# tpws options for the current scope. sites with their own strategy (see learn) get a profile each, first
tpws_opt()
{
	local ex="--hostlist-exclude=$Z/ipset/zapret-hosts-user-exclude.txt" user="--hostlist=$Z/ipset/zapret-hosts-user.txt"
	local hl="" hl80="" s so n=0 f
	case "$(scope)" in
		lists) hl=$user; hl80=$user ;;
		smart) hl="$user --hostlist-auto=$AUTO_LIST --hostlist-auto-fail-threshold=2"; hl80="$user --hostlist=$AUTO_LIST" ;;
	esac
	echo "--filter-tcp=80 --methodeol $hl80 $ex --new"
	rm -f "$RT"/lists/site-*.txt
	if [ -s "$SITES" ]; then
		while IFS= read -r s; do
			so=$(strategy_opts "$s")
			[ -n "$so" ] || continue
			n=$((n + 1)); f=$RT/lists/site-$n.txt
			awk -F'\t' -v s="$s" '$2 == s { print $1 }' "$SITES" > "$f"
			chmod 644 "$f"
			echo "--filter-tcp=443 --hostlist=$f $ex $so --new"
		done < <(cut -f2 "$SITES" | sort -u)
	fi
	echo "--filter-tcp=443 $hl $ex $1"
}

nfqws_dry_run()
{
	local tmp ret
	tmp=$(mktemp)
	{ echo --dry-run; cat "$1"; } > "$tmp"
	# @file is read only when it is the first argument
	"$RT/nfqws/bin/utunws" "@$tmp" >/dev/null 2>&1
	ret=$?
	rm -f "$tmp"
	return $ret
}

# waits until run.sh has loaded the pf rules (its IPv6 self-test takes up to 10 seconds)
nfqws_wait_ready()
{
	local i
	for i in $(seq 150); do [ -f "$NQ_READY" ] && return 0; sleep 0.1; done
	return 1
}

nfqws_launch()
{
	cat > "$NQ_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$NQ_LABEL</string>
	<key>ProgramArguments</key><array><string>$RT/nfqws/run.sh</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ThrottleInterval</key><integer>5</integer>
	<key>StandardErrorPath</key><string>/var/log/zapret-macos-nfqws.log</string>
</dict>
</plist>
EOF
	launchctl enable system/$NQ_LABEL
	# a loaded job is restarted; a new one starts by RunAtLoad. kickstart right after bootstrap
	# would kill the first run.sh while it starts and leave the ready mark of a dead one
	if launchctl print system/$NQ_LABEL >/dev/null 2>&1; then
		launchctl kickstart -k system/$NQ_LABEL
	else
		launchctl bootstrap system "$NQ_PLIST"
	fi
	nfqws_wait_ready && pgrep -qx utunws
}

# turns the boot job of the current engine on or off and keeps the other engine's job off
set_autostart()
{
	local job=zapret other=$NQ_LABEL
	if [ "$(engine_of "$(current)")" = nfqws ]; then job=$NQ_LABEL; other=zapret; fi
	launchctl disable system/$other
	if [ "$1" = on ]; then launchctl enable system/$job; else launchctl disable system/$job; fi
}

# tests the URLs and prints "passed/total youtube_bytes_per_sec".
# $1: empty — directly as root (pf leaves root alone), a number — through that socks port,
# "user" — as nobody, through pf and the running engine. $2=1 stops at the first failure.
probe()
{
	local mode=$1 url out code size speed pass=0 total=0 yt=0 proxy=() run=()
	case "$mode" in
		"") ;;
		user) run=(sudo -u nobody) ;;
		*) proxy=(--socks5-hostname "127.0.0.1:$mode") ;;
	esac
	for url in $TESTS; do
		total=$((total + 1))
		out=$("${run[@]}" curl -s -o /dev/null -m 8 "${proxy[@]}" -w "%{http_code} %{size_download} %{speed_download}" "$url")
		read -r code size speed <<<"$out"
		size=${size%.*}; speed=${speed%.*}
		if [ "${code:-000}" = 000 ]; then [ "$2" = 1 ] && break; continue; fi
		if [ "$url" = "https://www.youtube.com/" ]; then
			# DPI often lets the first ~16 KB through and then stalls the connection
			if [ "${size:-0}" -lt 300000 ]; then [ "$2" = 1 ] && break; continue; fi
			yt=${speed:-0}
		fi
		pass=$((pass + 1))
	done
	[ "$2" = 1 ] && total=$(echo "$TESTS" | wc -l | tr -d ' ')
	echo "$pass/$total $yt"
}

# Discord voice goes over UDP, and the strategies look for STUN on ports 19294-19344.
# a STUN request to such a port shows whether that path works. $1: empty — as root, past the engine;
# "user" — as nobody, through pf and the running engine
stun_ok()
{
	local run=()
	[ "$1" = user ] && run=(sudo -u nobody)
	"${run[@]}" /usr/bin/python3 -I -c '
import os, socket, struct, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
tid = os.urandom(12)
req = struct.pack("!HHI", 1, 0, 0x2112A442) + tid
for _ in range(2):
    try:
        s.sendto(req, ("stun.l.google.com", 19302))
        if s.recv(2048)[8:20] == tid:
            sys.exit(0)
    except OSError:
        pass
sys.exit(1)' 2>/dev/null
}

# one JSON line per event of check for the app; $1 event, then key value pairs (values are strings)
event()
{
	[ "$json" = 1 ] || return 0
	local e=$1 out k v
	shift
	out="{\"event\":\"$e\""
	while [ $# -ge 2 ]; do
		k=$1; v=${2//\\/\\\\}; v=${v//\"/\\\"}
		out="$out,\"$k\":\"$v\""
		shift 2
	done
	echo "$out}"
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
	# the Windows version's general; tpws if nfqws can't be downloaded (cmd_start exits on errors)
	( cmd_start "nfqws general" ) || cmd_start general
	# --no-app: the installation runs from the app itself
	[ "$1" = --no-app ] && return 0
	cmd_app || echo "  ${D}Приложение можно поставить позже, пункт меню 7.${N}"
}

cmd_start()
{
	need_root start "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local name=${1:-$(current)} engine opts="" auto=off
	name=${name:-nfqws general}
	engine=$(engine_of "$name")
	# read before the switch: the boot job depends on the engine
	autostart_on && auto=on

	sync_runtime
	write_lists
	if [ "$engine" = nfqws ]; then
		[ -n "$(nfqws_file "$name")" ] || die "Нет стратегии «$name»"
		nfqws_install || die "Движок nfqws не установлен"
		if ! nfqws_conf "$name" "$RT/nfqws.conf" || ! nfqws_dry_run "$RT/nfqws.conf"; then
			die "nfqws не принимает стратегию «$name»"
		fi
	else
		opts=$(strategy_opts "$name")
		[ -n "$opts" ] || die "Нет стратегии «$name»"
		opts=$(tpws_opt "$opts")
		# the same user as zapret's transparent tpws: it writes the found sites
		# shellcheck disable=SC2086
		"$Z/tpws/tpws" --user=root --port=$TEST_PORT --dry-run $opts >/dev/null 2>&1 || die "tpws не принимает: $opts"
	fi
	[ -f "$Z/config.bak-before-macos" ] || cp "$Z/config" "$Z/config.bak-before-macos"
	cp "$RT/90-block-quic" "$Z/init.d/macos/custom.d/90-block-quic"

	# hostlists are in the options themselves, so zapret's own filter is off
	OPT="${opts:+
$opts
}" NAME="$name" /usr/bin/python3 -I - "$Z/config" <<'EOF' || die "Не удалось изменить $Z/config"
import os, re, sys
path = sys.argv[1]
opt = os.environ["OPT"]
text = open(path).read()
# tpws options change only for a tpws strategy; for nfqws the config just keeps the name
if opt:
    # hostlist mode adds the exclude list itself
    text = re.sub(r'^TPWS_OPT="\$TPWS_OPT --hostlist-exclude=.*\n', '', text, flags=re.M)
    for var in ("TPWS_OPT", "TPWS_SOCKS_OPT"):
        text = re.sub(r'^%s="[^"$]*"' % var, lambda m: '%s="%s"' % (var, opt), text, flags=re.M)
    for var, val in (("MODE_FILTER", "none"), ("TPWS_ENABLE", "1"),
                     ("GZIP_LISTS", "0"),      # pf can't read gzipped lists
                     ("DISABLE_IPV6", "0")):   # otherwise YouTube over IPv6 bypasses tpws
        text = re.sub(r'^%s=.*$' % var, '%s=%s' % (var, val), text, flags=re.M)
text = re.sub(r'^# zapret-(mac|macos): .*\n', '', text, flags=re.M)
text = "# zapret-macos: %s\n" % os.environ["NAME"] + text
open(path, "w").write(text)
EOF

	zapret_stop
	nfqws_stop
	local started=1
	if [ "$engine" = nfqws ]; then
		nfqws_launch && nfqws_running && started=0
	else
		"$Z/init.d/macos/zapret" start >/dev/null 2>&1
		sleep 0.5
		tpws_running && started=0
	fi
	set_autostart $auto
	# the Telegram proxy is on but its service is gone: bring it back
	if telegram_on && ! telegram_running; then cmd_telegram on >/dev/null; fi
	if [ $started = 0 ]; then
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
	nfqws_stop
	if running; then
		bad "zapret всё ещё работает"
	else
		ok "zapret остановлен"
		notify "Остановлен"
		log stop
	fi
}

# all sites, smart (lists + sites found blocked) or only YouTube, Discord and the user's list
cmd_scope()
{
	need_root scope "$@"
	local s=$1 c
	if [ -z "$s" ]; then
		echo "  1) Все сайты, кроме исключений"
		echo "  2) Умный: YouTube, Discord, свои списки и сайты, которые не открылись без обхода"
		echo "  3) Только YouTube, Discord и свои списки"
		read -r -p "Номер: " c
		case "$c" in 1) s=all ;; 2) s=smart ;; 3) s=lists ;; *) return 0 ;; esac
	fi
	case "$s" in
		all)   rm -f "$RT/scope"; ok "zapret обрабатывает все сайты (кроме исключений)" ;;
		smart) mkdir -p "$RT"; echo smart > "$RT/scope"
		       ok "умный режим: сайт, который дважды не открылся, сам попадает в обработку" ;;
		lists) mkdir -p "$RT"; echo lists > "$RT/scope"; ok "zapret обрабатывает только YouTube, Discord и свои списки" ;;
		*)     die "scope: all, smart или lists" ;;
	esac
	if running; then cmd_start; fi
}

cmd_game()
{
	need_root game "$@"
	local g=$1 c
	if [ -z "$g" ]; then
		echo "  Обход для игр, как Game Filter в Windows-версии: порты 1024–65535 серверов игр и облаков."
		echo "  Работает с движком nfqws."
		echo "  1) Выключить   2) TCP   3) UDP   4) TCP и UDP"
		read -r -p "Номер: " c
		case "$c" in 1) g=off ;; 2) g=tcp ;; 3) g=udp ;; 4) g=all ;; *) return 0 ;; esac
	fi
	case "$g" in
		off) rm -f "$RT/game" ;;
		tcp|udp|all) mkdir -p "$RT"; echo "$g" > "$RT/game" ;;
		*) die "game: off, tcp, udp или all" ;;
	esac
	ok "игровой фильтр: $(game_name)"
	[ "$g" != off ] && [ "$(engine_of "$(current)")" = tpws ] && warn "работает только с движком nfqws — выбрать стратегию nfqws"
	if running && [ "$(engine_of "$(current)")" = nfqws ]; then cmd_start; fi
}

# ---------- Telegram: local MTProto proxy (Flowseal tg-ws-proxy) ----------

# Telegram Desktop connects to it as to an MTProto proxy, and it carries the traffic over WebSocket
# to Telegram's web servers. it runs as nobody: it needs neither root nor anything of the user
telegram_on()      { [ -f "$RT/telegram/on" ]; }
telegram_port()    { local p; p=$(cat "$RT/telegram/port" 2>/dev/null); echo "${p:-1443}"; }
telegram_running() { pgrep -qf -- "proxy.tg_ws_proxy --host 127.0.0.1 --port $(telegram_port)"; }
telegram_link()    { echo "tg://proxy?server=127.0.0.1&port=$(telegram_port)&secret=dd$(cat "$RT/telegram/secret" 2>/dev/null)"; }
# Flowseal's own app listens on 1443 too
flowseal_tg_running() { pgrep -qx TgWsProxy; }

# the whole path: a handshake like Telegram Desktop's through the proxy, an answer from Telegram
telegram_test()
{
	"$RT/telegram/venv/bin/python3" -I "$RT/telegram/check.py" 127.0.0.1 "$(telegram_port)" "$(cat "$RT/telegram/secret")" 2
}

# the proxy's source from the release archive and its dependencies in a separate Python
# environment, both checked: the archive against a pinned checksum, the packages against
# the hashes in telegram/requirements.txt
telegram_install()
{
	local d=$RT/telegram tmp ret=1
	[ -x "$d/venv/bin/python3" ] && [ "$(cat "$d/VERSION" 2>/dev/null)" = "$TGVER" ] && return 0
	if ! /usr/bin/xcrun --find python3 >/dev/null 2>&1; then
		bad "нужен Python из Command Line Tools: выполнить xcode-select --install"
		return 1
	fi
	echo "${B}Скачиваю прокси для Telegram (Flowseal tg-ws-proxy $TGVER)…${N}"
	tmp=$(mktemp -d)
	if ! curl -fsSL -o "$tmp/tg.tar.gz" "https://github.com/Flowseal/tg-ws-proxy/archive/refs/tags/$TGVER.tar.gz"; then
		bad "Не удалось скачать прокси"
	elif ! echo "$TGSHA256  $tmp/tg.tar.gz" | shasum -a 256 -c --status; then
		bad "Контрольная сумма прокси не совпала"
	elif ! tar -xzf "$tmp/tg.tar.gz" -C "$tmp"; then
		bad "Не удалось распаковать прокси"
	else
		rm -rf "$d/proxy" "$d/venv"
		cp -R "$tmp"/tg-ws-proxy-*/proxy "$d/"
		cp "$tmp"/tg-ws-proxy-*/LICENSE "$d/"
		echo "  ставлю зависимости…"
		if /usr/bin/python3 -m venv "$d/venv" &&
			"$d/venv/bin/pip" install -q --disable-pip-version-check --no-input --no-cache-dir --require-hashes \
				--only-binary=:all: -r "$d/requirements.txt"; then
			echo "$TGVER" > "$d/VERSION"
			ok "прокси для Telegram установлен"
			ret=0
		else
			bad "Не удалось поставить зависимости прокси"
			rm -rf "$d/venv"
		fi
	fi
	chown -R root:wheel "$d"
	rm -rf "$tmp"
	return $ret
}

cmd_telegram()
{
	local d=$RT/telegram
	case "$1" in
		on)
			need_root telegram on
			# one at a time: two runs at once unload each other's service
			mkdir /var/run/zapret-macos.telegram.lock 2>/dev/null || die "Прокси для Telegram уже включается"
			trap 'rmdir /var/run/zapret-macos.telegram.lock 2>/dev/null' EXIT
			sync_runtime
			if telegram_on && telegram_running && launchctl print system/$TG_LABEL >/dev/null 2>&1; then
				ok "прокси для Telegram уже работает: 127.0.0.1:$(telegram_port)"
				return 0
			fi
			telegram_install || die "Прокси для Telegram не установлен"
			# one secret for good: Telegram keeps the proxy it was given
			[ -s "$d/secret" ] || od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$d/secret"
			chmod 644 "$d/secret"
			# the first free port of 1443-1453: another proxy (Flowseal's app) may hold 1443.
			# bootout returns before the job is gone, and bootstrap of a job still there fails
			launchctl bootout system/$TG_LABEL 2>/dev/null
			local p i
			for i in $(seq 25); do launchctl print system/$TG_LABEL >/dev/null 2>&1 || break; sleep 0.2; done
			for p in $(seq 1443 1453); do
				lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || break
			done
			echo "$p" > "$d/port"
			[ "$p" != 1443 ] && warn "порт 1443 занят$(flowseal_tg_running && echo " приложением TG WS Proxy") — прокси на порту $p"
			touch /var/log/zapret-macos-telegram.log
			chown nobody /var/log/zapret-macos-telegram.log
			cat > "$TG_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$TG_LABEL</string>
	<key>ProgramArguments</key><array>
		<string>$d/venv/bin/python3</string><string>-m</string><string>proxy.tg_ws_proxy</string>
		<string>--host</string><string>127.0.0.1</string><string>--port</string><string>$(cat "$d/port")</string>
		<string>--secret</string><string>$(cat "$d/secret")</string>
	</array>
	<key>WorkingDirectory</key><string>$d</string>
	<key>UserName</key><string>nobody</string>
	<key>EnvironmentVariables</key><dict><key>PYTHONDONTWRITEBYTECODE</key><string>1</string></dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>5</integer>
	<key>StandardErrorPath</key><string>/var/log/zapret-macos-telegram.log</string>
</dict>
</plist>
EOF
			launchctl bootstrap system "$TG_PLIST" || die "Не удалось запустить прокси"
			touch "$d/on"
			# the process appears before Python listens on the port
			for i in $(seq 50); do
				telegram_running && nc -z 127.0.0.1 "$(telegram_port)" 2>/dev/null && break
				sleep 0.2
			done
			if telegram_running; then
				ok "прокси для Telegram работает: 127.0.0.1:$(telegram_port)"
				echo "  Подключить Telegram Desktop — открыть ссылку (или кнопка в приложении):"
				echo "  $(telegram_link)"
				log "telegram on"
			else
				bad "прокси не запустился, подробности: /var/log/zapret-macos-telegram.log"
				return 1
			fi
			;;
		off)
			need_root telegram off
			launchctl bootout system/$TG_LABEL 2>/dev/null
			rm -f "$TG_PLIST" "$d/on"
			ok "прокси для Telegram выключен"
			log "telegram off"
			;;
		link)
			telegram_link
			;;
		test)
			telegram_running || die "Прокси для Telegram не запущен"
			if telegram_test; then
				ok "Telegram отвечает через прокси"
			else
				bad "Telegram не ответил через прокси"
				vpn_active || running || echo "  zapret остановлен: без него провайдер может резать соединения прокси"
				return 1
			fi
			;;
		*)
			if telegram_on; then cmd_telegram off; else cmd_telegram on; fi
			;;
	esac
}

# ---------- smart mode: found sites and per-site strategies ----------

# true if https://$2 answers at all; $1 as in probe (empty or a socks port)
site_ok()
{
	local proxy=() code
	[ -n "$1" ] && proxy=(--socks5-hostname "127.0.0.1:$1")
	code=$(curl -s -o /dev/null -m 6 "${proxy[@]}" -w "%{http_code}" "https://$2/")
	[ "${code:-000}" != 000 ]
}

# looks for a tpws strategy for sites the main strategy doesn't open. every tpws strategy runs
# as a socks instance, like in check, so nothing is stopped and it can run in the background.
# no arguments: found sites and the user's list that were not looked at yet; --all: all of them again
cmd_learn()
{
	need_root learn "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local quiet=0 all=0 norestart=0 a domains=() d names=() n i main="" tp pids=() probes=() changed=0 res
	for a in "$@"; do
		case "$a" in --quiet) quiet=1 ;; --all) all=1 ;; --no-restart) norestart=1 ;; *) domains+=("$a") ;; esac
	done
	vpn_active && { [ $quiet = 1 ] && return 1; die "Включён VPN — его нужно выключить."; }
	touch "$SITES" "$SITES_TESTED"
	if [ ${#domains[@]} = 0 ]; then
		while IFS= read -r d; do
			[ $all = 1 ] || ! grep -qxF "$d" "$SITES_TESTED" && domains+=("$d")
		done < <(grep -hvE '^[[:space:]]*(#|$)' "$AUTO_LIST" "$PROJECT/lists/list-user.txt" 2>/dev/null | tr -d '\r' | sort -u)
	fi
	if [ ${#domains[@]} = 0 ]; then
		[ $quiet = 1 ] || ok "Новых сайтов для подбора нет"
		return 0
	fi

	while IFS= read -r n; do names+=("$n"); done < <(tpws_names)
	[ "$(engine_of "$(current)")" = tpws ] && main=$(current)
	for i in "${!names[@]}"; do
		# shellcheck disable=SC2046
		"$Z/tpws/tpws" --socks --user=root --bind-addr=127.0.0.1 --port=$((TEST_PORT + 1 + i)) \
			$(strategy_opts "${names[$i]}") >/dev/null 2>&1 &
		pids+=($!)
	done
	sleep 0.5
	tp=$(mktemp -d)

	for d in "${domains[@]}"; do
		# the old choice is dropped: the site is looked at from scratch
		if awk -F'\t' -v d="$d" '$1 == d { f = 1 } END { exit !f }' "$SITES"; then
			awk -F'\t' -v d="$d" '$1 != d' "$SITES" > "$tp/s"; cat "$tp/s" > "$SITES"
			changed=1
		fi
		grep -qxF "$d" "$SITES_TESTED" || echo "$d" >> "$SITES_TESTED"
		if site_ok "" "$d"; then
			[ $quiet = 1 ] || echo "  ${D}· $d — открывается и без обхода${N}"
			continue
		fi
		probes=()
		for i in "${!names[@]}"; do
			( site_ok $((TEST_PORT + 1 + i)) "$d" && touch "$tp/ok$i" ) &
			probes+=($!)
		done
		wait "${probes[@]}"
		res=""
		for i in "${!names[@]}"; do
			if [ -f "$tp/ok$i" ]; then
				[ -z "$res" ] && res=${names[$i]}
				[ "${names[$i]}" = "$main" ] && res=$main
			fi
		done
		rm -f "$tp"/ok*
		if [ -z "$res" ]; then
			[ $quiet = 1 ] || bad "$d — ни одна стратегия tpws не помогла"
		elif [ "$res" = "$main" ]; then
			[ $quiet = 1 ] || ok "$d — работает с основной стратегией"
		else
			printf '%s\t%s\n' "$d" "$res" >> "$SITES"
			changed=1
			[ $quiet = 1 ] || ok "$d — своя стратегия: ${B}$res${N}"
			log "learn: $d → $res"
		fi
	done
	kill "${pids[@]}" 2>/dev/null
	wait "${pids[@]}" 2>/dev/null
	rm -rf "$tp"
	[ $changed = 1 ] || return 0
	if [ -z "$main" ]; then
		[ $quiet = 1 ] || warn "стратегии для сайтов работают только с движком tpws, сейчас выбран nfqws"
	elif running && [ $norestart = 0 ]; then
		[ $quiet = 1 ] || echo "Перезапускаю zapret со стратегиями для сайтов…"
		cmd_start >/dev/null && { [ $quiet = 1 ] || ok "готово"; }
	fi
	return 0
}

# a site that doesn't open: it goes into the user's list, gets its own tpws strategy if the main one
# doesn't open it, and is checked the way a browser opens it. --json: the result for the app
cmd_site()
{
	need_root site "$@"
	local d json=0 added=0 direct=0 works=0 strategy list="$PROJECT/lists/list-user.txt"
	[ "$2" = --json ] && json=1
	# https://www.example.com/page → example.com (subdomains are covered anyway)
	d=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^[a-z]+://##; s#[/?#:].*$##; s#^www\.##')
	if ! printf '%s' "$d" | grep -qE '^[a-z0-9-]+(\.[a-z0-9-]+)+$'; then
		[ $json = 1 ] && { echo "{\"error\":$(jstr "Не похоже на адрес сайта")}"; return 1; }
		die "Не похоже на адрес сайта: $1"
	fi
	if ! grep -qxF "$d" "$list" 2>/dev/null; then
		echo "$d" >> "$list"
		added=1
	fi
	site_ok "" "$d" && direct=1
	cmd_learn --quiet --no-restart "$d" >/dev/null
	strategy=$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$SITES" 2>/dev/null)
	# the lists changed: the engines read them on start
	if running; then cmd_start >/dev/null 2>&1; sleep 1; fi
	as_user curl -s -o /dev/null -m 8 "https://$d/" && works=1
	log "site $d: direct=$direct works=$works strategy=${strategy:-main}"
	if [ $json = 1 ]; then
		printf '{"site":%s,"added":%s,"direct":%s,"works":%s,"strategy":%s}\n' "$(jstr "$d")" \
			"$([ $added = 1 ] && echo true || echo false)" "$([ $direct = 1 ] && echo true || echo false)" \
			"$([ $works = 1 ] && echo true || echo false)" "$(jstr "$strategy")"
		return 0
	fi
	[ $added = 1 ] && ok "$d добавлен в свой список"
	[ $direct = 1 ] && echo "  ${D}· без обхода тоже открывается — значит, мешает не провайдер, а что-то ещё${N}"
	[ -n "$strategy" ] && ok "для $d своя стратегия: ${B}$strategy${N}"
	if [ $works = 1 ]; then ok "$d открывается"; else bad "$d всё ещё не открывается — попробовать подобрать стратегию (пункт меню 3)"; fi
}

# shows or clears what the smart mode has found
cmd_found()
{
	if [ "$1" = --json ]; then
		local d s first=1
		printf '['
		while IFS= read -r d; do
			s=$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$SITES" 2>/dev/null)
			[ $first = 1 ] || printf ','
			first=0
			printf '{"site":%s,"strategy":%s}' "$(jstr "$d")" "$(jstr "$s")"
		done < <(grep -vE '^[[:space:]]*(#|$)' "$AUTO_LIST" 2>/dev/null)
		echo ']'
		return
	fi
	if [ "$1" = clear ]; then
		need_root found clear
		: > "$AUTO_LIST"; : > "$SITES"; : > "$SITES_TESTED"
		ok "найденные сайты и стратегии для них очищены"
		if running; then cmd_start >/dev/null; fi
		return
	fi
	local d s
	echo "${B}Найденные сайты${N} ${D}(умный режим)${N}"
	if [ -s "$AUTO_LIST" ]; then
		while IFS= read -r d; do
			s=$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$SITES" 2>/dev/null)
			echo "  $d${s:+  ${D}→ $s${N}}"
		done < <(grep -vE '^[[:space:]]*(#|$)' "$AUTO_LIST")
	else
		echo "  ${D}пока ничего${N}"
	fi
	if [ -s "$SITES" ]; then
		echo; echo "${B}Свои стратегии для сайтов${N}"
		awk -F'\t' '{ printf "  %s → %s\n", $1, $2 }' "$SITES"
	fi
}

# ---------- check (strategy search) ----------

# tpws: every strategy is tested in parallel through temporary socks instances.
# both tpws (--user=root) and curl run as root, so the system pf redirect doesn't touch them
# and the running zapret can stay up.
# nfqws can't run as a proxy: its strategies are started one by one for real and tested as nobody,
# so the running zapret is stopped for that time. --quick skips nfqws.
cmd_check()
{
	need_root check "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local auto=0 quiet=0 quick=0 json=0 a
	for a in "$@"; do
		case "$a" in
			--auto) auto=1 ;;
			--quiet) quiet=1; auto=1 ;;
			--quick) quick=1 ;;
			# events for the app instead of text; applies the best strategy itself
			--json) json=1; quiet=1; auto=1 ;;
		esac
	done
	if vpn_active; then
		event error message "Включён VPN — его нужно выключить"
		[ $quiet = 1 ] && return 1
		die "Включён VPN — его нужно выключить, иначе проверка покажет не провайдера, а VPN."
	fi

	local tmp n=0 pids=() name base vbase=0 voice best_voice=-1 total
	total=$(tpws_names | wc -l | tr -d ' ')
	[ $quick = 0 ] && total=$((total + $(nfqws_names | wc -l | tr -d ' ')))
	event start total "$total"
	tmp=$(mktemp -d)
	[ $quiet = 1 ] || echo "${B}Проверка без zapret…${N}"
	base=$(probe "")
	# tpws doesn't touch UDP: for its strategies voice works exactly as without zapret
	stun_ok "" && vbase=1
	[ $quiet = 1 ] || echo "  открылось ${base% *}, голос Discord $([ $vbase = 1 ] && echo ✓ || echo ✗) — дальше проверяю стратегии tpws параллельно"
	event base pass "${base% *}" voice "$vbase"

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
	done < <(tpws_names)
	wait "${pids[@]}"

	# the parallel run decides pass/fail; speed is measured again one by one for the winners
	local best="" best_speed=-1 res pass yt
	# a working strategy with voice beats one without. speeds are noisy: among equals the earlier
	# strategy stays unless another one is clearly faster, and nfqws (the Windows version's
	# strategies) beats tpws unless tpws is clearly faster
	consider()
	{
		local v
		[ "$4" = 1 ] && v="голос ✓" || v="голос ✗"
		[ $quiet = 1 ] || ok "$(printf '%-36s %s  %5s КБ/с  %s' "$1" "$2" $(($3 / 1024)) "$v")"
		event result name "$1" ok 1 pass "$2" kbps "$(($3 / 1024))" voice "$4"
		if [ -z "$best" ] || [ "$4" -gt "$best_voice" ] ||
			{ [ "$4" = "$best_voice" ] && [ "$3" -gt $((best_speed * 3 / 2)) ]; } ||
			{ [ "$4" = "$best_voice" ] && [ "$(engine_of "$1")" = nfqws ] && [ "$(engine_of "$best")" = tpws ] &&
				[ $(($3 * 3 / 2)) -ge "$best_speed" ]; }; then
			best=$1; best_speed=$3; best_voice=$4
		fi
	}
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
			consider "$name" "$pass" "$yt" $vbase
		else
			[ $quiet = 1 ] || echo "  ${D}✗ $(printf '%-36s %s' "$name" "$pass")${N}"
			event result name "$name" ok 0 pass "$pass"
		fi
	done < <(tpws_names)

	local was was_running=0
	was=$(current)
	running && was_running=1
	if [ $quick = 0 ] && sync_runtime && write_lists >/dev/null && { [ $quiet = 1 ] && nfqws_install >/dev/null || nfqws_install; }; then
		[ $quiet = 1 ] || { echo; echo "${B}Стратегии nfqws проверяются по очереди, интернет на это время может пропадать…${N}"; }
		zapret_stop
		nfqws_stop
		local rp=""
		# shellcheck disable=SC2064
		trap "[ -n \"\$rp\" ] && kill \$rp 2>/dev/null; wait; rm -rf '$tmp'; [ $was_running = 1 ] && '$SELF' start '$was' >/dev/null; exit 130" INT TERM
		while IFS= read -r name; do
			nfqws_conf "$name" "$tmp/nq.conf" || continue
			"$RT/nfqws/run.sh" "$tmp/nq.conf" >/dev/null 2>&1 &
			rp=$!
			if nfqws_wait_ready; then
				sleep 0.3
				res=$(probe user 1)
			else
				res="0/0 0"
			fi
			pass=${res% *}; yt=${res#* }
			voice=0
			if [ "${pass%/*}" = "${pass#*/}" ] && [ "${pass%/*}" != 0 ]; then
				stun_ok user && voice=1
			fi
			kill $rp 2>/dev/null; wait $rp 2>/dev/null
			rp=""
			if [ "${pass%/*}" = "${pass#*/}" ] && [ "${pass%/*}" != 0 ]; then
				consider "$name" "$pass" "$yt" $voice
			else
				[ $quiet = 1 ] || echo "  ${D}✗ $(printf '%-36s %s' "$name" "$pass")${N}"
				event result name "$name" ok 0 pass "$pass"
			fi
		done < <(nfqws_names)
		trap - INT TERM
	fi
	rm -rf "$tmp"

	if [ -z "$best" ]; then
		event finish best ""
		[ $quiet = 1 ] || { echo; bad "Ни одна стратегия не прошла все проверки."; echo "  Можно создать Issue на GitHub и приложить этот вывод и вывод диагностики."; }
		[ $was_running = 1 ] && ! running && cmd_start "$was" >/dev/null
		return 1
	fi
	[ $quiet = 1 ] || { echo; echo "Лучшая: ${B}$best${N} ($((best_speed / 1024)) КБ/с, голос Discord $([ "$best_voice" = 1 ] && echo ✓ || echo ✗))"; }
	if [ $auto = 0 ]; then
		read -r -p "Применить? [Y/n] " a
		case "$a" in
			n|N) [ $was_running = 1 ] && ! running && cmd_start "$was"; return 0 ;;
		esac
	fi
	if [ "$best" = "$(current)" ] && running; then
		[ $quiet = 1 ] || ok "Она уже включена."
	elif [ $quiet = 1 ]; then
		cmd_start "$best" >/dev/null
	else
		cmd_start "$best"
	fi
	event finish best "$best" kbps "$((best_speed / 1024))" voice "$best_voice"
	# watchdog reads the chosen name from the last line
	[ $quiet = 1 ] && [ $json = 0 ] && echo "$best"
	return 0
}

# ---------- diagnostics ----------

# with diag --tags: a fix for the line above, as a button in the app (see fixes in Model.swift)
hint() { [ "$DIAG_TAGS" = 1 ] && echo "    @fix $1"; return 0; }

cmd_diag()
{
	need_root diag "$@"
	[ "$1" = --tags ] && DIAG_TAGS=1
	local u p rv
	echo "${B}zapret-discord-youtube-macos $VERSION${N}, macOS $(sw_vers -productVersion), $(uname -m)"
	echo

	echo "${B}zapret${N}"
	if installed; then ok "установлен ($("$Z/tpws/tpws" --version 2>&1 | head -1))"; else bad "не установлен — запустить zapret.command"; fi
	local eng
	eng=$(engine_of "$(current)")
	if running; then ok "работает, стратегия: $(current) (движок $eng)"; else bad "не запущен"; hint start; fi
	if [ "$eng" = nfqws ]; then
		if nfqws_installed; then ok "nfqws установлен ($NQ_TAG)"; else bad "nfqws не установлен — перезапустить стратегию"; hint restart; fi
	fi
	if autostart_on; then ok "автозапуск включён"; else warn "автозапуск выключен"; fi
	if watchdog_on; then ok "автопочинка включена"; else echo "  ${D}· автопочинка выключена${N}"; fi
	if autoupdate_on; then ok "автообновление включено"; else echo "  ${D}· автообновление выключено${N}"; fi
	if telegram_on; then
		if ! telegram_running; then
			bad "прокси для Telegram не запущен — включить заново"; hint telegram
		elif telegram_test >/dev/null 2>&1; then
			ok "Telegram отвечает через прокси (127.0.0.1:$(telegram_port))"
		else
			bad "прокси для Telegram запущен, но Telegram через него не отвечает"; hint telegram
		fi
		flowseal_tg_running && { warn "запущено приложение TG WS Proxy — его лучше закрыть, прокси уже встроен"; hint quit-flowseal; }
	fi
	case "$(scope)" in
		all)   ok "обрабатываются все сайты" ;;
		smart) ok "умный режим: найдено сайтов $(count_entries "$AUTO_LIST"), своих стратегий $(count_entries "$SITES")" ;;
		*)     ok "обрабатываются YouTube, Discord и свои списки" ;;
	esac
	if pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then ok "файрвол pf включён"; else bad "файрвол pf выключен — перезапустить стратегию"; hint restart; fi
	if [ "$eng" = nfqws ]; then
		if pfctl -a $NQ_ANCHOR -s rules 2>/dev/null | grep -q route-to; then
			ok "трафик заворачивается в nfqws (utun50)"
		elif running; then
			bad "правила pf для nfqws не загружены — перезапустить стратегию"; hint restart
		fi
	elif pfctl -a zapret-v4 -s rules 2>/dev/null | grep -q 'proto udp.*port = 443'; then
		ok "QUIC заблокирован (браузер пойдёт через TCP)"
	elif running; then
		bad "блокировка QUIC не загружена — перезапустить стратегию"; hint restart
	fi
	echo

	echo "${B}Сеть${N}"
	if vpn_active; then warn "включён VPN — пока он работает, zapret не участвует"; else ok "VPN не обнаружен"; fi
	if pfctl -a $NQ_ANCHOR -s rules 2>/dev/null | grep -q 'from any'; then
		bad "правила nfqws от версии без поддержки VPN — перезапустить стратегию"; hint restart
	fi
	if scutil --proxy | grep -qE '(HTTP|HTTPS|SOCKS)Enable : 1'; then
		warn "в системе настроен прокси — трафик может идти мимо zapret"; hint proxy-settings
	else
		ok "системный прокси не настроен"
	fi
	for p in spoofdpi ciadpi byedpi goodbyedpi warp-svc sing-box xray v2ray mihomo clash hiddify nekoray; do
		pgrep -qix "$p" && { warn "запущен $p — может конфликтовать с zapret"; hint monitor; }
	done
	if ifconfig | grep -q 'inet6 2[0-9a-f]*:'; then
		if [ "$eng" = nfqws ] && [ "$(cat /var/run/zapret-macos.nfqws-ipv6 2>/dev/null)" = 1 ]; then
			ok "есть IPv6 — nfqws обрабатывает и его"
		elif [ "$eng" = nfqws ]; then
			ok "есть IPv6 — nfqws его не обрабатывает, сайты открываются по IPv4"
		else ok "есть IPv6 — zapret обрабатывает и его"; fi
	fi
	u=$(dig +short +time=2 +tries=1 www.youtube.com 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
	case "$u" in
		"") warn "DNS не ответил на www.youtube.com" ;;
		0.0.0.0|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) bad "DNS подменяет YouTube ($u) — указать 1.1.1.1 / 8.8.8.8 в настройках сети"; hint dns ;;
		*) ok "DNS отвечает нормально ($u)" ;;
	esac
	echo

	echo "${B}Доступность (как в браузере)${N}"
	for p in https://www.youtube.com/ https://redirector.googlevideo.com/generate_204 https://discord.com/; do
		if as_user curl -s -o /dev/null -m 8 "$p"; then ok "$p"; else bad "$p"; hint check; fi
	done
	if stun_ok user; then ok "голос Discord (UDP, STUN)"; else bad "голос Discord (UDP, STUN) — попробовать стратегию nfqws"; hint check; fi
	echo

	rv=$(remote_version)
	if newer "$rv" "$VERSION"; then warn "доступно обновление: $rv"; hint update; elif [ -n "$rv" ]; then ok "последняя версия"; fi
	echo

	echo "${B}Браузеры${N} ${D}(если YouTube всё равно тормозит — и перезапустить браузер)${N}"
	if [ -d "/Applications/Google Chrome.app" ]; then
		echo "  · Chrome: выключить «Безопасный DNS» (Настройки → Конфиденциальность → Безопасность)"; hint chrome-dns
		echo "  · Chrome: выключить QUIC (chrome://flags/#enable-quic → Disabled)"; hint chrome-quic
	fi
	echo "  · Safari: выключить iCloud Private Relay"; hint relay
}

# the active network service gets public DNS: some providers answer YouTube with a stub
cmd_dns()
{
	need_root dns
	local dev svc
	dev=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')
	svc=$(networksetup -listnetworkserviceorder | awk -v dev="$dev" '
		/^\([0-9]+\) / { name = $0; sub(/^\([0-9]+\) /, "", name) }
		index($0, "Device: " dev ")") { print name; exit }')
	[ -n "$svc" ] || die "Не удалось найти активное подключение"
	networksetup -setdnsservers "$svc" 1.1.1.1 1.0.0.1 8.8.8.8 || die "Не удалось сменить DNS"
	dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null
	ok "DNS для «$svc»: 1.1.1.1, 1.0.0.1, 8.8.8.8"
}

# ---------- autostart / watchdog ----------

cmd_autostart()
{
	need_root autostart "$@"
	case "$1" in
		on)  set_autostart on && ok "автозапуск включён" ;;
		off) set_autostart off && ok "автозапуск выключен" ;;
		*)   if autostart_on; then cmd_autostart off; else cmd_autostart on; fi ;;
	esac
}

# installs the background job when autofix or autoupdate needs it and removes it otherwise
background_job()
{
	if watchdog_on || autoupdate_on; then
		[ -f "$WD_PLIST" ] && launchctl print system/$WD_LABEL >/dev/null 2>&1 && return 0
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
		launchctl bootstrap system "$WD_PLIST"
	else
		launchctl bootout system/$WD_LABEL 2>/dev/null
		rm -f "$WD_PLIST"
	fi
}

cmd_watchdog()
{
	case "$1" in
		on)
			need_root watchdog on
			sync_runtime
			touch "$RT/autofix"
			background_job && ok "автопочинка включена: проверка каждые 5 минут"
			;;
		off)
			need_root watchdog off
			rm -f "$RT/autofix" "$RT/watchdog.fails"
			background_job
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

cmd_autoupdate()
{
	case "$1" in
		on)
			need_root autoupdate on
			sync_runtime
			touch "$RT/autoupdate"
			background_job && ok "автообновление включено: проверка раз в сутки"
			;;
		off)
			need_root autoupdate off
			rm -f "$RT/autoupdate"
			background_job
			ok "автообновление выключено"
			;;
		*)
			if autoupdate_on; then cmd_autoupdate off; else cmd_autoupdate on; fi
			;;
	esac
}

# once a day: a newer version is installed and the current strategy restarted with it.
# if the new strategies don't suit the provider, autofix picks another one
auto_update()
{
	local rv
	[ -n "$(find "$RT/update-checked" -mtime -1 2>/dev/null)" ] && return 0
	touch "$RT/update-checked"
	rv=$(remote_version)
	newer "$rv" "$VERSION" || return 0
	log "autoupdate: $VERSION → $rv"
	if cmd_update >/dev/null 2>&1; then
		notify "Обновлено до $rv"
	else
		log "autoupdate: не удалось"
	fi
}

# called by launchd as root every 5 minutes
watchdog_run()
{
	local fails new
	# the project folder belongs to the user: update only while someone is logged in
	autoupdate_on && [ "$(stat -f %Su /dev/console)" != root ] && auto_update
	if telegram_on && ! telegram_running; then
		log "watchdog: прокси для Telegram не работал, запускаю"
		cmd_telegram on >/dev/null
	fi
	watchdog_on || return 0
	running || return 0
	vpn_active && return 0
	[ "$(stat -f %Su /dev/console)" = root ] && return 0
	# check the real path: as the user, through pf and the running tpws
	if as_user curl -s -o /dev/null -m 8 https://www.youtube.com/ &&
		as_user curl -s -o /dev/null -m 8 https://redirector.googlevideo.com/generate_204; then
		rm -f "$RT/watchdog.fails"
		# smart mode: while everything works, look for strategies for newly found sites
		[ "$(scope)" = smart ] && [ "$(engine_of "$(current)")" = tpws ] && cmd_learn --quiet >/dev/null
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

# ---------- the app ----------

# installs zapret.app into /Applications: from the release, checked against the pinned checksum,
# or built from the project's sources (needs Command Line Tools)
cmd_app()
{
	if [ "$(id -u)" = 0 ]; then
		as_user "$SELF" app "$@"
		return
	fi
	local tmp ok=1 have
	if [ "$1" = --if-outdated ]; then
		have=$(defaults read /Applications/zapret.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)
		[ "$have" = "$VERSION" ] && return 0
		echo "Обновляю приложение: ${have:-?} → $VERSION"
	fi
	tmp=$(mktemp -d)
	if [ -n "$APPSHA256" ]; then
		echo "${B}Скачиваю приложение…${N}"
		if curl -fL --progress-bar -o "$tmp/app.zip" "https://github.com/$REPO/releases/download/$APPTAG/zapret-app.zip" &&
			echo "$APPSHA256  $tmp/app.zip" | shasum -a 256 -c --status && ditto -x -k "$tmp/app.zip" "$tmp"; then
			ok=0
		else
			bad "Не удалось скачать приложение или контрольная сумма не совпала"
		fi
	elif xcrun --find swiftc >/dev/null 2>&1 && [ -x "$PROJECT/build/app.sh" ]; then
		echo "${B}Собираю приложение из исходников (около 20 секунд)…${N}"
		if "$PROJECT/build/app.sh" "$tmp" >/dev/null 2>&1; then ok=0; else bad "Сборка не удалась"; fi
	else
		bad "Нужны Command Line Tools: выполнить xcode-select --install"
	fi
	if [ $ok = 0 ]; then
		osascript -e 'quit app "zapret"' >/dev/null 2>&1
		pkill -x zapret 2>/dev/null
		rm -rf /Applications/zapret.app
		ditto "$tmp/zapret.app" /Applications/zapret.app && xattr -dr com.apple.quarantine /Applications/zapret.app 2>/dev/null
		# the app replaces the old SwiftBar icon
		menubar_on && cmd_menubar off >/dev/null
		open /Applications/zapret.app
		ok "приложение zapret установлено и открыто — иконка в строке меню"
	fi
	rm -rf "$tmp"
	return $ok
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
	# the rest is done by the new script: it knows the new version
	local new="$PROJECT/src/zapret.sh" root=()
	[ "$(id -u)" = 0 ] || root=(sudo)
	if running; then
		echo "Перезапускаю zapret с новыми списками…"
		"${root[@]}" "$new" start "$(current)"
	else
		# the root copy the app and launchd use must be new too
		"${root[@]}" "$new" sync
	fi
	app_installed && "$new" app --if-outdated
}

cmd_restore()
{
	need_root restore
	[ -f "$Z/config.bak-before-macos" ] || die "Резервной копии нет"
	nfqws_stop
	rm -f "$NQ_PLIST"
	launchctl enable system/zapret
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
	rm -f "$RT/autofix" "$RT/autoupdate"
	background_job
	cmd_menubar off >/dev/null 2>&1
	nfqws_stop
	rm -f "$NQ_PLIST" "$NQ_READY"
	launchctl bootout system/$TG_LABEL 2>/dev/null
	rm -f "$TG_PLIST"
	[ -x "$Z/uninstall_easy.sh" ] && "$Z/uninstall_easy.sh" >/dev/null 2>&1
	rm -f /Library/LaunchDaemons/zapret.plist /etc/sudoers.d/zapret-macos
	rm -rf "$Z" "$RT"
	ok "zapret удалён. Папку проекта можно удалить вручную."
}

# ---------- status / menu ----------

# entries in a list file (no comments and empty lines), 0 if there is no file
count_entries() { awk '!/^[[:space:]]*(#|$)/ { n++ } END { print n + 0 }' "$1" 2>/dev/null || echo 0; }

# JSON string: "value" with quotes and backslashes escaped
jstr() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v"; }
jbool() { if "$@"; then echo true; else echo false; fi; }

cmd_status()
{
	if [ "$1" = --json ]; then
		local cur
		cur=$(current)
		printf '{"version":%s,"installed":%s,"running":%s,"strategy":%s,"engine":%s,"scope":%s,"game":%s,' \
			"$(jstr "$VERSION")" "$(jbool installed)" "$(jbool running)" "$(jstr "$cur")" \
			"$(jstr "$(engine_of "$cur")")" "$(jstr "$(scope)")" "$(jstr "$(game_mode)")"
		printf '"telegram":%s,"telegramRunning":%s,"telegramLink":%s,"flowsealTelegram":%s,' \
			"$(jbool telegram_on)" "$(jbool telegram_running)" "$(jstr "$(telegram_on && telegram_link)")" \
			"$(jbool flowseal_tg_running)"
		printf '"autostart":%s,"autofix":%s,"autoupdate":%s,"vpn":%s,"ipv6":%s,"found":%s,"sites":%s,"project":%s}\n' \
			"$(jbool autostart_on)" "$(jbool watchdog_on)" "$(jbool autoupdate_on)" "$(jbool vpn_active)" \
			"$(jbool [ "$(cat /var/run/zapret-macos.nfqws-ipv6 2>/dev/null)" = 1 ])" \
			"$(count_entries "$AUTO_LIST")" "$(count_entries "$SITES")" "$(jstr "$PROJECT")"
		return
	fi
	if running; then echo "${G}●${N} работает: ${B}$(current)${N}"; else echo "${R}●${N} остановлен"; fi
	telegram_on && echo "  Telegram: $(telegram_running && echo "прокси работает" || echo "прокси не отвечает")"
	printf "  сайты: %s · игры: %s · автозапуск: %s · автопочинка: %s · автообновление: %s · приложение: %s\n" \
		"$(scope_name)" "$(game_name)" \
		"$(autostart_on && echo вкл || echo выкл)" \
		"$(watchdog_on && echo вкл || echo выкл)" "$(autoupdate_on && echo вкл || echo выкл)" \
		"$(app_installed && echo есть || echo нет)"
}

pick_strategy()
{
	local names=() n i=0 c cur first_tp
	cur=$(current)
	first_tp=$(tpws_names | head -1)
	while IFS= read -r n; do names+=("$n"); done < <(strategy_names)
	for n in "${names[@]}"; do
		i=$((i + 1))
		[ $i = 1 ] && echo "  ${B}nfqws${N} ${D}— стратегии Windows-версии: фейковые пакеты, QUIC и UDP${N}"
		[ "$n" = "$first_tp" ] && echo "  ${B}tpws${N} ${D}— разбиение пакетов, IPv4 и IPv6${N}"
		if [ "$n" = "$cur" ]; then printf "  %2d) %s ${G}(сейчас)${N}\n" $i "$n"; else printf "  %2d) %s\n" $i "$n"; fi
	done
	read -r -p "Номер: " c
	[[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#names[@]} ] && cmd_start "${names[$((c - 1))]}"
}

lists_menu()
{
	local c
	echo "  1) Открыть мои списки (list-user.txt, list-exclude-user.txt)"
	echo "  2) Показать найденные сайты"
	echo "  3) Подобрать стратегии tpws для найденных сайтов"
	echo "  4) Очистить найденные сайты"
	read -r -p "Номер: " c
	echo
	case "$c" in
		1) as_user open -t "$PROJECT/lists/list-user.txt" "$PROJECT/lists/list-exclude-user.txt"
		   echo "Открыты list-user.txt и list-exclude-user.txt. После правки — перезапустить стратегию (пункт 1)." ;;
		2) cmd_found ;;
		3) cmd_learn ;;
		4) cmd_found clear ;;
	esac
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
		echo "  7) Приложение zapret (иконка в строке меню): установить или обновить"
		echo "  8) Сайты: все / умный / только YouTube, Discord и свои списки"
		echo "  9) Списки доменов и найденные сайты"
		echo " 10) Обновить"
		echo " 11) Вернуть исходный конфиг zapret"
		echo " 12) Удалить zapret"
		echo " 13) Игровой фильтр: $(game_name)"
		echo " 14) Автообновление (раз в сутки): вкл/выкл"
		echo " 15) Прокси для Telegram: $(telegram_on && echo вкл || echo выкл)"
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
			7) cmd_app ;;
			8) cmd_scope ;;
			9) lists_menu ;;
			10) cmd_update; upd="" ;;
			11) cmd_restore ;;
			12) cmd_uninstall; installed || exit 0 ;;
			13) cmd_game ;;
			14) cmd_autoupdate ;;
			15) cmd_telegram ;;
			0|"") exit 0 ;;
		esac
	done
}

usage()
{
	cat <<EOF
zapret-discord-youtube-macos $VERSION

  zapret.sh                      меню (при первом запуске — установка)
  zapret.sh install              установить zapret и запустить nfqws general
  zapret.sh start [имя]          запустить стратегию (по умолчанию — текущую)
  zapret.sh stop                 остановить
  zapret.sh status               состояние
  zapret.sh list                 список стратегий
  zapret.sh check [--auto] [--quick]
                                 подобрать стратегию (--auto — применить лучшую без вопроса,
                                 --quick — только tpws, без перебора nfqws)
  zapret.sh diag                 диагностика
  zapret.sh dns                  поставить DNS 1.1.1.1 / 8.8.8.8 для активного подключения
  zapret.sh autostart [on|off]   автозапуск при загрузке
  zapret.sh watchdog [on|off]    автопочинка
  zapret.sh autoupdate [on|off]  автообновление раз в сутки
  zapret.sh telegram [on|off|link|test]
                                 прокси для Telegram Desktop; link — ссылка для подключения,
                                 test — проверить, что Telegram отвечает через прокси
  zapret.sh app                  установить приложение zapret в «Программы»
  zapret.sh menubar [on|off]     старая иконка в строке меню через SwiftBar
  zapret.sh scope [all|smart|lists]
                                 все сайты, умный режим или только YouTube, Discord и свои списки
  zapret.sh found [clear]        сайты, найденные умным режимом
  zapret.sh site <адрес>         сайт не открывается: в свой список, своя стратегия, проверка
  zapret.sh game [off|tcp|udp|all]
                                 игровой фильтр (порты 1024–65535, только nfqws)
  zapret.sh learn [--all|сайт…]  подобрать стратегию tpws для найденных сайтов
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
	status)     shift; cmd_status "$@" ;;
	list)       strategy_names ;;
	check)      shift; cmd_check "$@" ;;
	diag)       shift; cmd_diag "$@" ;;
	dns)        cmd_dns ;;
	autostart)  shift; cmd_autostart "$@" ;;
	watchdog)   shift; cmd_watchdog "$@" ;;
	autoupdate) shift; cmd_autoupdate "$@" ;;
	telegram)   shift; cmd_telegram "$@" ;;
	app)        shift; cmd_app "$@" ;;
	sync)       need_root sync; sync_runtime ;;
	menubar)    shift; cmd_menubar "$@" ;;
	scope)      shift; cmd_scope "$@" ;;
	found)      shift; cmd_found "$@" ;;
	site)       shift; cmd_site "$@" ;;
	game)       shift; cmd_game "$@" ;;
	learn)      shift; cmd_learn "$@" ;;
	gui)        shift; cmd_gui "$@" ;;
	update)     cmd_update ;;
	restore)    cmd_restore ;;
	uninstall)  cmd_uninstall ;;
	help|-h|--help) usage ;;
	*)          usage; exit 1 ;;
esac
