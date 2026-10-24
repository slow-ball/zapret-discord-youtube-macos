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
