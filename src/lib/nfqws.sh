# shellcheck shell=bash
# zapret.sh: nfqws engine. Sourced by src/zapret.sh, which defines the constants.

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
		# a new file in place of the old one, never over it: macOS kills every later start of a signed
		# binary that was overwritten while it ran
		cp "$tmp/x/bin/utunws" "$RT/nfqws/bin/utunws.new"
		chown root:wheel "$RT/nfqws/bin/utunws.new"
		chmod 755 "$RT/nfqws/bin/utunws.new"
		mv -f "$RT/nfqws/bin/utunws.new" "$RT/nfqws/bin/utunws"
		echo "$NQ_TAG" > "$RT/nfqws/bin/VERSION"
		chown -R root:wheel "$RT/nfqws"
		ok "nfqws установлен"
		ret=0
	fi
	rm -rf "$tmp"
	return $ret
}

# the template of a strategy: Flowseal's file, or ours with @DESYNC@ for own and found ones. $1 name, $2 game-tcp/game-udp/empty
strategy_template()
{
	local f
	if is_windows "$1"; then
		f=$(nfqws_file "$1")
		[ -n "$f" ] || return 1
		f=$RT/nfqws/strategies/$f${2:+.$2}.conf.in
	else
		f=$RT/nfqws/macos/${2:-main}.conf.in
	fi
	[ -f "$f" ] && echo "$f"
}

# options one per line in place of @DESYNC@; $1 the options. a name that is neither ours nor found fails
put_desync()
{
	awk -v o="$1" '$0 == "@DESYNC@" { n = split(o, a, " "); for (i = 1; i <= n; i++) print a[i]; next } { print }'
}

# options of a strategy for one site's own profile: own and found ones as they are, the Windows version's
# from its profile for HTTP and HTTPS of the general list
site_opts()
{
	if is_windows "$1"; then
		local f
		f=$(strategy_template "$1") || return 1
		awk '
			$0 == "--new" { if (hit) exit; delete p; n = 0; next }
			$0 == "--filter-tcp=80,443" { tcp = 1 }
			$0 ~ /list-general\.txt"$/ { gen = 1 }
			$0 !~ /^--(filter|hostlist|ipset|new)/ { p[++n] = $0 }
			tcp && gen { hit = 1 }
			END { if (hit) for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? " " : ""), p[i]; print "" }
		' "$f" | tr -d '"'
	else
		strategy_opts "$1"
	fi
}

# fills the placeholders: $1 strategy name, $2 output file. sites with their own strategy (see learn)
# get a profile each, first: nfqws takes the first profile that fits
nfqws_conf()
{
	local t ipset=$RT/lists/ipset-none.txt auto="" opts=""
	known_name "$1" || return 1
	t=$(strategy_template "$1") || return 1
	is_windows "$1" || { opts=$(strategy_opts "$1"); [ -n "$opts" ] || return 1; }
	case "$(scope)" in
		all) ipset=$RT/lists/ipset-any.txt ;;
		# the profiles of the user's list also learn blocked sites. utunws sees only outgoing packets,
		# so it notices retransmissions (DPI drops the connection) but not resets
		smart) auto="--hostlist-auto=\"@LISTS@/list-auto.txt\"" ;;
	esac
	local g k s so n=0 f
	g=$(game_mode)
	rm -f "$RT"/lists/site-*.txt
	{
		if [ -s "$SITES" ]; then
			while IFS= read -r s; do
				so=$(site_opts "$s")
				[ -n "$so" ] || continue
				n=$((n + 1)); f=$RT/lists/site-$n.txt
				awk -F'\t' -v s="$s" '$2 == s { print $1 }' "$SITES" > "$f"
				chmod 644 "$f"
				printf '%s\n' --filter-tcp=80,443 "--hostlist=$f"
				printf '%s\n' "$so" | tr ' ' '\n'
				echo --new
			done < <(cut -f2 "$SITES" | sort -u)
		fi
		awk -v a="$auto" '{ print } a != "" && $0 == "--hostlist=\"@LISTS@/list-general-user.txt\"" { print a }' "$t" |
			put_desync "$opts"
		for k in tcp udp; do
			if { [ "$g" = all ] || [ "$g" = $k ]; } && f=$(strategy_template "$1" game-$k); then
				echo --new
				cat "$f"
			fi
		done
	} | sed -e "s|@BASE@|$RT/nfqws|g" -e "s|@LISTS@|$RT/lists|g" -e "s|@IPSET@|$ipset|g" \
		-e "s|@GAME_TCP@|1024-65535|g" -e "s|@GAME_UDP@|1024-65535|g" -e "s|@GAMEIPSET@|$RT/nfqws/ipset-game.txt|g" > "$2"
}

# a config for trying options on some sites only (learn, deep): $1 options, $2 file with the sites, $3 output
nfqws_site_conf()
{
	{
		printf '%s\n' --filter-tcp=80,443 "--hostlist=$2"
		printf '%s\n' "$1" | tr ' ' '\n'
	} | sed -e "s|@BASE@|$RT/nfqws|g" > "$3"
}

# runs a config ($1) for a test until nfqws_untry. the first call starts the engine, the next ones
# make it read the file again (SIGHUP to run.sh): a strategy takes a fraction of a second instead of
# the whole setup. IPv4 only: the IPv6 self-test takes seconds and test requests fall back to IPv4 at
# once. true when the engine is up
nfqws_try()
{
	rm -f "$NQ_READY"
	if [ -n "$TRY_PID" ] && kill -0 "$TRY_PID" 2>/dev/null && [ "$1" = "$TRY_CONF" ]; then
		kill -HUP "$TRY_PID"
	else
		nfqws_untry
		ZAPRET_NO_V6=1 "$RT/nfqws/run.sh" "$1" >/dev/null 2>&1 &
		TRY_PID=$!
		TRY_CONF=$1
	fi
	nfqws_wait_ready "$TRY_PID"
}

nfqws_untry()
{
	[ -n "$TRY_PID" ] && { kill "$TRY_PID" 2>/dev/null; wait "$TRY_PID" 2>/dev/null; }
	TRY_PID=""
}

nfqws_dry_run()
{
	local tmp ret
	tmp=$(mktemp)
	{ echo --dry-run; cat "$1"; } > "$tmp"
	# @file is read only when it is the first argument
	# in a subshell: bash would report a start macOS killed (see cmd_start)
	( "$RT/nfqws/bin/utunws" "@$tmp" ) >/dev/null 2>&1
	ret=$?
	rm -f "$tmp"
	return $ret
}

# waits until run.sh has loaded the pf rules (its IPv6 self-test takes up to 10 seconds);
# $1: the pid of run.sh, if it ends there is nothing to wait for
nfqws_wait_ready()
{
	local i
	for i in $(seq 150); do
		[ -f "$NQ_READY" ] && return 0
		[ -n "$1" ] && ! kill -0 "$1" 2>/dev/null && return 1
		sleep 0.1
	done
	return 1
}

# the running service takes the new $RT/nfqws.conf without a restart of the network setup and the
# firewall. not when the game filter changed: its ports are in the pf rules
nfqws_reload()
{
	[ -f "$NQ_READY" ] && launchctl print system/$NQ_LABEL >/dev/null 2>&1 || return 1
	[ "$(cat /var/run/zapret-macos.nfqws-game 2>/dev/null)" = "$(game_mode)" ] || return 1
	rm -f "$NQ_READY"
	launchctl kill SIGHUP system/$NQ_LABEL >/dev/null 2>&1 || return 1
	nfqws_wait_ready && running
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

set_autostart()
{
	if [ "$1" = on ]; then launchctl enable system/$NQ_LABEL; else launchctl disable system/$NQ_LABEL; fi
}

# tests the URLs and prints "passed/total youtube_bytes_per_sec".
# $1: empty — directly as root (pf leaves root alone), "user" — as nobody, through pf and the running
# engine. $2=1 stops at the first failure.
probe()
{
	local url out code size speed pass=0 total=0 yt=0 run=()
	[ "$1" = user ] && run=(sudo -u nobody)
	for url in $TESTS; do
		total=$((total + 1))
		out=$("${run[@]}" curl -s -o /dev/null -m 8 -w "%{http_code} %{size_download} %{speed_download}" "$url")
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
