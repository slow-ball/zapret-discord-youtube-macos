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

# one engine, nfqws, and three kinds of strategies: the Windows version's (Flowseal's files listed in
# nfqws/strategies.tsv, named "nfqws <name>"), our own for macOS (lines of nfqws/macos.conf) and the ones
# the deep search found (lines of $DSTRATS). own and found ones are options for TCP put into a template
windows_names() { awk -F'\t' 'NF == 2 { print "nfqws " $2 }' "$NQ_STRATS"; }
own_names()     { grep -hvE '^\s*(#|$)' "$OWN_STRATS" "$DSTRATS" 2>/dev/null | cut -d'|' -f1; }

# the Windows version's first: they are the main ones
strategy_names()
{
	windows_names
	own_names
}

is_windows()  { case "$1" in "nfqws "*) return 0 ;; *) return 1 ;; esac; }
nfqws_file()  { awk -F'\t' -v n="${1#nfqws }" '$2 == n { print $1; exit }' "$NQ_STRATS"; }
known_name()  { strategy_names | grep -qxF -- "$1"; }

# options of an own or found strategy, nothing for others
strategy_opts()
{
	grep -hvE '^\s*(#|$)' "$OWN_STRATS" "$DSTRATS" 2>/dev/null | awk -F'|' -v n="$1" '$1 == n { print $2; exit }'
}

installed()  { [ -f "$RT/zapret.sh" ] && [ -d "$RT/lib" ]; }

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

running()    { pgrep -qx utunws; }
current()    { head -1 "$CURRENT" 2>/dev/null; }
vpn_active() { netstat -rn -f inet | grep -qE '^(0/1|default) +[^ ]+ +[^ ]+ +utun'; }
autostart_on()  { ! launchctl print-disabled system 2>/dev/null | grep -qE "\"$NQ_LABEL\" => (true|disabled)"; }
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

# the latest release: github.com/…/releases/latest redirects to …/releases/tag/vX.Y.Z.
# only released versions reach users, not every change of main
remote_version()
{
	curl -fsSI -m 6 "https://github.com/$REPO/releases/latest" 2>/dev/null | release_of
}

# the version from the headers of that redirect, nothing if there is none
release_of()
{
	awk 'tolower($1) == "location:" { n = split($2, a, "/"); print a[n] }' | tr -d '\r' | sed 's/^v//' |
		grep -xE '[0-9]+(\.[0-9]+){1,3}'
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
	cp "$SRC/zapret.sh" "$SRC/menubar.sh" "$SRC/VERSION" \
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
		for c in start stop check scope game autostart watchdog autoupdate learn found diag telegram site dns deep repair; do
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
# only such names go into curl, the lists nfqws reads and the names of strategies
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

# the lists nfqws reads, in $RT/lists
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
}

# before 3.0 zapret of bol-van in /opt/zapret ran the second engine, tpws. it goes away: its service
# stops, and the folder is removed if it holds the default config, that is, nobody set it up by hand.
# the running strategy's name moves to $CURRENT; tpws ones and what was found with them are dropped
migrate_legacy()
{
	local z=$LEGACY t
	[ -d "$z" ] || return 0
	[ "$z" = "$RT" ] && return 0
	[ -f "$CURRENT" ] || sed -nE 's/^# zapret-mac(os)?: //p' "$z/config" 2>/dev/null | head -1 > "$CURRENT"
	# autostart belonged to zapret's own job while a tpws strategy ran
	if ! is_windows "$(current)" && ! launchctl print-disabled system 2>/dev/null | grep -qE '"zapret" => (true|disabled)'; then
		launchctl enable system/$NQ_LABEL
	fi
	known_name "$(current)" || rm -f "$CURRENT"
	"$z/init.d/macos/zapret" stop >/dev/null 2>&1
	pkill -f -- '--pidfile=/var/run/tpws1.pid'
	launchctl bootout system/zapret 2>/dev/null
	rm -f "$z/init.d/macos/custom.d/90-block-quic"
	if [ ! -f "$z/config.bak-before-macos" ] || cmp -s "$z/config.bak-before-macos" "$z/config.default"; then
		[ -L "$LEGACY_PLIST" ] && rm -f "$LEGACY_PLIST"
		rm -rf "$z"
		log "migrate: zapret от bol-van и tpws удалены"
	else
		# someone's own zapret: their config comes back, its service stays off so the engines don't clash
		cp "$z/config.bak-before-macos" "$z/config"
		rm -f "$z/config.bak-before-macos"
		launchctl disable system/zapret
		log "migrate: свой zapret в $z оставлен с исходным конфигом, его служба выключена"
	fi
	rm -f "$RT/strategies.conf" "$RT/90-block-quic" "$RT/strategies-user.conf"
	if [ -s "$SITES" ]; then
		t=$(mktemp)
		while IFS=$'\t' read -r d n; do
			if known_name "$n"; then printf '%s\t%s\n' "$d" "$n"; else grep -vxF "$d" "$SITES_TESTED" > "$t.t"; cat "$t.t" > "$SITES_TESTED"; fi
		done < "$SITES" > "$t"
		cat "$t" > "$SITES"
		rm -f "$t" "$t.t"
	fi
}

# logs are kept small: the last ~300 KB of each once it grows past 1 MB
trim_logs()
{
	local f
	for f in "$LOG" /var/log/zapret-macos-nfqws.log /var/log/zapret-macos-telegram.log; do
		[ -f "$f" ] && [ "$(stat -f %z "$f")" -gt 1048576 ] || continue
		tail -c 300000 "$f" | tail -n +2 > "$f.tmp" && cat "$f.tmp" > "$f"
		rm -f "$f.tmp"
	done
}
