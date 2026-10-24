# shellcheck shell=bash
# zapret.sh: diagnostics. Sourced by src/zapret.sh, which defines the constants.

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
