# shellcheck shell=bash
# zapret.sh: helpers. Sourced by src/zapret.sh, which defines the constants.

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
	grep -hvE '^\s*(#|$)' "$STRATS" "$USTRATS" 2>/dev/null | cut -d'|' -f1
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
	grep -hvE '^\s*(#|$)' "$STRATS" "$USTRATS" 2>/dev/null | awk -F'|' -v n="$1" '$1 == n { print $2; exit }'
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
	mkdir -p "$RT/nfqws" "$RT/telegram" "$RT/lib"
	cp "$SRC"/lib/*.sh "$RT/lib/"
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
		for c in start stop check scope game autostart watchdog autoupdate learn found diag telegram site dns deep; do
			printf ' %s %s, %s %s *,' "$RT/zapret.sh" $c "$RT/zapret.sh" $c
		done | sed 's/,$//'
		echo
	} > "$tmp"
	if visudo -c -q -f "$tmp" 2>/dev/null; then
		cmp -s "$tmp" "$f" || { install -m 440 -o root -g wheel "$tmp" "$f"; }
	fi
	rm -f "$tmp"
}

# https://www.Example.com/page → example.com; prints nothing if it is not a host name.
# only such names go into curl, the lists tpws reads and the names of strategies
host_of()
{
	local d
	d=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^[a-z]+://##; s#[/?#:].*$##; s#^www\.##')
	# the whole string, not line by line: a second line would get into names that end up in the
	# config zapret runs as a script
	[[ $d =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] && printf '%s\n' "$d"
}

# the user's files are read and written with the rights of the project folder's owner. as root,
# a symlink there would let any program read or change a system file: the sudoers rule asks no password
project_owner() { stat -f %Su "$PROJECT" 2>/dev/null; }

user_cat()
{
	local u
	u=$(project_owner)
	if [ "$(id -u)" = 0 ] && [ -n "$u" ] && [ "$u" != root ]; then
		sudo -u "$u" cat "$@" 2>/dev/null
	else
		cat "$@" 2>/dev/null
	fi
}

# $1 file, $2 line
user_append()
{
	local u
	u=$(project_owner)
	if [ "$(id -u)" = 0 ] && [ -n "$u" ] && [ "$u" != root ]; then
		sudo -u "$u" /bin/sh -c 'printf "%s\n" "$2" >> "$1"' sh "$1" "$2"
	else
		printf '%s\n' "$2" >> "$1"
	fi
}

# lists for both engines: tpws reads the merged files in $Z/ipset, nfqws reads $RT/lists
write_lists()
{
	local l=$RT/lists
	[ -d "$PROJECT/lists" ] || warn "папка проекта не найдена ($PROJECT) — свои списки не подключены. Запустить zapret.command из новой папки."
	mkdir -p "$l"
	cp "$RT/list-general.txt" "$RT/list-google.txt" "$RT/list-exclude.txt" "$RT/ipset-exclude.txt" "$l/"
	user_cat "$PROJECT/lists/list-user.txt" > "$l/list-general-user.txt"
	user_cat "$PROJECT/lists/list-exclude-user.txt" > "$l/list-exclude-user.txt"
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
