# shellcheck shell=bash
# zapret.sh: install / apply. Sourced by src/zapret.sh, which defines the constants.

cmd_install()
{
	need_root install "$@"
	# files from a browser-downloaded ZIP are quarantined; one approval of zapret.command is enough
	xattr -dr com.apple.quarantine "$PROJECT" 2>/dev/null
	sync_runtime
	nfqws_install || die "Не удалось установить движок nfqws"
	ok "zapret установлен в $RT"
	cmd_start "nfqws general" || exit 1
	set_autostart on
	# --no-app: the installation runs from the app itself
	[ "$1" = --no-app ] && return 0
	cmd_app || echo "  ${D}Приложение можно поставить позже, пункт меню 7.${N}"
}

cmd_start()
{
	need_root start "$@"
	installed || [ "$SRC" != "$RT" ] || die "zapret не установлен. Запустить zapret.command"
	local name=$1 auto=off
	sync_runtime
	migrate_legacy
	trim_logs
	[ -n "$name" ] || name=$(current)
	# a strategy that is gone (tpws before 3.0, an older Windows version) gives way to general.
	# the updater of 2.x passes the running one by name
	if ! known_name "$name"; then
		[ -n "$name" ] && warn "стратегии «$name» больше нет — включаю nfqws general"
		name="nfqws general"
	fi
	autostart_on && auto=on
	write_lists
	nfqws_install || die "Движок nfqws не установлен"
	if ! nfqws_conf "$name" "$RT/nfqws.conf" || ! nfqws_dry_run "$RT/nfqws.conf"; then
		die "nfqws не принимает стратегию «$name»"
	fi
	# one line, even if a name had more: the app and the scripts read the first
	printf '%s\n' "$name" | head -1 > "$CURRENT"
	rm -f "$RT/stopped"

	nfqws_stop
	local started=1
	nfqws_launch && running && started=0
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
		log "start $name: не запустился"
		return 1
	fi
}

cmd_stop()
{
	need_root stop
	nfqws_stop
	touch "$RT/stopped"
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
	if running; then cmd_start; fi
}
