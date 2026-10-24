# shellcheck shell=bash
# zapret.sh: status / menu. Sourced by src/zapret.sh, which defines the constants.

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
		printf '{"version":%s,"previous":%s,"installed":%s,"running":%s,"strategy":%s,"engine":"nfqws","scope":%s,"game":%s,' \
			"$(jstr "$VERSION")" "$(jstr "$(previous_version)")" "$(jbool installed)" "$(jbool running)" "$(jstr "$cur")" \
			"$(jstr "$(scope)")" "$(jstr "$(game_mode)")"
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
	local names=() n i=0 c cur first_own
	cur=$(current)
	first_own=$(own_names | head -1)
	while IFS= read -r n; do names+=("$n"); done < <(strategy_names)
	for n in "${names[@]}"; do
		i=$((i + 1))
		[ $i = 1 ] && echo "  ${B}Windows-версия${N} ${D}— стратегии Flowseal${N}"
		[ "$n" = "$first_own" ] && echo "  ${B}macOS${N} ${D}— свои стратегии и найденные глубоким подбором${N}"
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
	echo "  3) Подобрать стратегии для найденных сайтов"
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
		echo " 11) Вернуть предыдущую версию$(p=$(previous_version) && echo " ($p)")"
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
			11) if p=$(previous_version); then cmd_update --to "$p"; else echo "Предыдущей версии 3.0 или новее нет"; fi ;;
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
  zapret.sh check [--auto] [--all] [--quick]
                                 подобрать стратегию: сначала вероятные, до первой хорошей
                                 (--all — проверить все и выбрать самую быструю,
                                 --auto — применить без вопроса, --quick — только Windows-версии)
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
  zapret.sh deep [адрес]         глубокий подбор для сайта (5–15 минут), по умолчанию YouTube
  zapret.sh game [off|tcp|udp|all]
                                 игровой фильтр (порты 1024–65535)
  zapret.sh learn [--all|сайт…]  подобрать стратегию для найденных сайтов
  zapret.sh update [--to версия] обновить до последнего релиза или вернуть версию (3.0 и новее)
  zapret.sh repair               восстановить службы, правила и sudo (после обновления macOS)
  zapret.sh uninstall [--yes]    удалить zapret (--yes — без вопроса)
EOF
}
