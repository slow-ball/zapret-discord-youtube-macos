# shellcheck shell=bash
# zapret.sh: install / apply. Sourced by src/zapret.sh, which defines the constants.

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
# zapret runs this file as a script: a name must stay one comment line
name = " ".join(os.environ["NAME"].split())
text = "# zapret-macos: %s\n" % name + text
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
