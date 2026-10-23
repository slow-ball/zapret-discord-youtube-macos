#!/bin/bash
# Движок nfqws: utunws из сборки Flowseal (zapret-mac-discord-youtube, MIT).
# Трафик пользователей (не root) заворачивается pf в utun50, utunws применяет стратегию
# и отправляет пакеты сам через BPF на физический интерфейс. IPv4 и, если работает, IPv6.
# Запускается launchd (com.zapret-macos.nfqws) или автоподбором. Выходит при смене сети,
# launchd запускает заново.
# Аргумент: файл стратегии (по умолчанию /opt/zapret-macos/nfqws.conf).

RT=/opt/zapret-macos
CONF=${1:-$RT/nfqws.conf}
ENGINE=$RT/nfqws/bin/utunws
ANCHOR=com.apple/zapret-macos
TOKEN_FILE=/var/run/zapret-macos.pf-token
KEEPINIT_FILE=/var/db/zapret-macos.keepinit
ENGINE_PID=
GUARD_PID=

flush_pf()
{
	rm -f /var/run/zapret-macos.nfqws-ready /var/run/zapret-macos.nfqws-ipv6
	/sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
	if [ -s "$TOKEN_FILE" ]; then
		/sbin/pfctl -X "$(cat "$TOKEN_FILE")" >/dev/null 2>&1
		rm -f "$TOKEN_FILE"
	fi
}

# shellcheck disable=SC2317  # called by trap
cleanup()
{
	trap - EXIT INT TERM HUP
	flush_pf
	[ -n "$GUARD_PID" ] && kill "$GUARD_PID" 2>/dev/null
	if [ -s "$KEEPINIT_FILE" ]; then
		/usr/sbin/sysctl -w net.inet.tcp.keepinit="$(cat "$KEEPINIT_FILE")" >/dev/null
		rm -f "$KEEPINIT_FILE"
	fi
	[ -n "$ENGINE_PID" ] && kill "$ENGINE_PID" 2>/dev/null && wait "$ENGINE_PID" 2>/dev/null
}

trap cleanup EXIT INT TERM HUP
[ -x "$ENGINE" ] && [ -f "$CONF" ] || exit 1
flush_pf
pkill -9 -x utunws 2>/dev/null

# a connection the DPI silently drops hangs for 75 seconds before the app tries again; 7 seconds, as in
# Flowseal's port, so a video player recovers quickly. the old value comes back on exit
[ -s "$KEEPINIT_FILE" ] || /usr/sbin/sysctl -n net.inet.tcp.keepinit > "$KEEPINIT_FILE"
/usr/sbin/sysctl -w net.inet.tcp.keepinit=7000 >/dev/null

route_get() { /sbin/route -n get "$@" default 2>/dev/null; }
IFACE=$(route_get | awk '/interface:/{print $2; exit}')
GATEWAY=$(route_get | awk '/gateway:/{print $2; exit}')
[ -n "$IFACE" ] && [ -n "$GATEWAY" ] || exit 1
/sbin/ping -c 1 -t 1 "$GATEWAY" >/dev/null 2>&1
GATEWAY_MAC=$(/usr/sbin/arp -n "$GATEWAY" | awk '/ at /{print $4; exit}')
case "$GATEWAY_MAC" in *:*:*:*:*:*) ;; *) exit 1 ;; esac
GATEWAY6=$(route_get -inet6 | awk '/gateway:/{print $2; exit}')
GATEWAY6_MAC=
[ -n "$GATEWAY6" ] && GATEWAY6_MAC=$(/usr/sbin/ndp -n "$GATEWAY6" 2>/dev/null |
	awk '{for (i = 1; i <= NF; i++) if ($i ~ /^([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}$/) { print $i; exit }}')

# @file is read only when it is the first argument
ZAPRET_IFACE=$IFACE ZAPRET_GATEWAY_MAC=$GATEWAY_MAC ZAPRET_GATEWAY6_MAC=$GATEWAY6_MAC ZAPRET_UTUN_UNIT=51 \
	"$ENGINE" "@$CONF" &
ENGINE_PID=$!

i=0
until /sbin/ifconfig utun50 >/dev/null 2>&1; do
	i=$((i + 1))
	kill -0 "$ENGINE_PID" 2>/dev/null && [ $i -le 100 ] || exit 1
	sleep 0.1
done
/sbin/ifconfig utun50 10.77.0.1 10.77.0.2 netmask 255.255.255.255 up

# if this script is killed with -9, drop the pf rules anyway: without utunws they would cut the traffic off
(
	while kill -0 $$ 2>/dev/null && kill -0 "$ENGINE_PID" 2>/dev/null; do sleep 0.2; done
	/sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
	kill "$ENGINE_PID" 2>/dev/null
) &
GUARD_PID=$!

if /sbin/pfctl -s info 2>/dev/null | grep -q '^Status: Disabled'; then
	/sbin/pfctl -E 2>&1 | awk '/Token :/ { print $3 }' > "$TOKEN_FILE"
fi

PORTS_TCP="{80,443,2053,2083,2087,2096,8443}"
PORTS_UDP="{443,19294:19344,50000:50100}"
# game filter (zapret.sh game): ports of game servers go to utunws too
case "$(cat "$RT/game" 2>/dev/null)" in
	tcp) PORTS_TCP="{80,443,1024:65535}" ;;
	udp) PORTS_UDP="{443,1024:65535}" ;;
	all) PORTS_TCP="{80,443,1024:65535}"; PORTS_UDP="{443,1024:65535}" ;;
esac

# only packets with the address of the physical interface: a VPN that routes 0/1 and 128.0/1 through
# its tunnel keeps the default route, and its packets sent past the tunnel would be dropped.
# $1=1: IPv6 goes to utunws too; otherwise IPv6 web traffic is rejected and browsers fall back to IPv4 at once.
# pfctl -f warns about the main ruleset on every load
load_rules()
{
	{
		echo "pass out quick route-to (utun50 10.77.0.2) inet proto tcp from ($IFACE) to any port $PORTS_TCP user { >root } no state"
		echo "pass out quick route-to (utun50 10.77.0.2) inet proto udp from ($IFACE) to any port $PORTS_UDP user { >root } no state"
		if [ "$1" = 1 ]; then
			echo "pass out quick route-to (utun50 fd00:7a70::2) inet6 proto tcp from ($IFACE) to any port $PORTS_TCP user { >root } no state"
			echo "pass out quick route-to (utun50 fd00:7a70::2) inet6 proto udp from ($IFACE) to any port $PORTS_UDP user { >root } no state"
		else
			echo "block return out quick inet6 proto tcp from ($IFACE) to any port {80,443} user { >root }"
			echo "block return out quick inet6 proto udp from ($IFACE) to any port 443 user { >root }"
		fi
	} | /sbin/pfctl -a "$ANCHOR" -f - 2>/dev/null
}

v6_ok() { "$@" curl -6 -s -o /dev/null -m 5 https://www.google.com/generate_204; }

# IPv6 through utunws when there is IPv6 at all and a test request as an ordinary user passes
V6=0
if [ -n "$GATEWAY6_MAC" ] && v6_ok &&
	/sbin/ifconfig utun50 inet6 fd00:7a70::1 fd00:7a70::2 prefixlen 128 2>/dev/null; then
	V6=1
fi
load_rules $V6 || exit 1
if [ $V6 = 1 ] && ! v6_ok sudo -u nobody; then
	echo "IPv6 через utunws не работает, IPv6-сайты пойдут по IPv4" >&2
	V6=0
	load_rules 0 || exit 1
fi
echo $V6 > /var/run/zapret-macos.nfqws-ipv6
touch /var/run/zapret-macos.nfqws-ready

while kill -0 "$ENGINE_PID" 2>/dev/null; do
	sleep 2
	[ "$(route_get | awk '/interface:/{print $2; exit}')" = "$IFACE" ] &&
		[ "$(route_get | awk '/gateway:/{print $2; exit}')" = "$GATEWAY" ] || exit 1
done
exit 1
