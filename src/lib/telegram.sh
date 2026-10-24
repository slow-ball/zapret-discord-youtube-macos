# shellcheck shell=bash
# zapret.sh: Telegram: local MTProto proxy (Flowseal tg-ws-proxy). Sourced by src/zapret.sh, which defines the constants.

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
	say "%sСкачиваю прокси для Telegram (Flowseal tg-ws-proxy %s)…%s" "${B}" "$TGVER" "${N}"
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
		say "  ставлю зависимости…"
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
				ok "прокси для Telegram уже работает: 127.0.0.1:%s" "$(telegram_port)"
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
			[ "$p" != 1443 ] && warn "порт 1443 занят%s — прокси на порту %s" "$(flowseal_tg_running && say " приложением TG WS Proxy")" "$p"
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
				ok "прокси для Telegram работает: 127.0.0.1:%s" "$(telegram_port)"
				say "  Подключить Telegram Desktop — открыть ссылку (или кнопка в приложении):"
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
				vpn_active || running || say "  zapret остановлен: без него провайдер может резать соединения прокси"
				return 1
			fi
			;;
		*)
			if telegram_on; then cmd_telegram off; else cmd_telegram on; fi
			;;
	esac
}
