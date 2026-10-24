# shellcheck shell=bash
# zapret.sh: autostart / watchdog. Sourced by src/zapret.sh, which defines the constants.

cmd_autostart()
{
	need_root autostart "$@"
	case "$1" in
		on)  set_autostart on && ok "автозапуск включён" ;;
		off) set_autostart off && ok "автозапуск выключен" ;;
		*)   if autostart_on; then cmd_autostart off; else cmd_autostart on; fi ;;
	esac
}

# installs the background job when autofix or autoupdate needs it and removes it otherwise
background_job()
{
	if watchdog_on || autoupdate_on; then
		[ -f "$WD_PLIST" ] && launchctl print system/$WD_LABEL >/dev/null 2>&1 && return 0
		cat > "$WD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$WD_LABEL</string>
	<key>ProgramArguments</key><array><string>$RT/zapret.sh</string><string>watchdog</string><string>run</string></array>
	<key>StartInterval</key><integer>300</integer>
	<key>RunAtLoad</key><false/>
</dict>
</plist>
EOF
		launchctl bootout system/$WD_LABEL 2>/dev/null
		launchctl bootstrap system "$WD_PLIST"
	else
		launchctl bootout system/$WD_LABEL 2>/dev/null
		rm -f "$WD_PLIST"
	fi
}

cmd_watchdog()
{
	case "$1" in
		on)
			need_root watchdog on
			sync_runtime
			touch "$RT/autofix"
			background_job && ok "автопочинка включена: проверка каждые 5 минут"
			;;
		off)
			need_root watchdog off
			rm -f "$RT/autofix" "$RT/watchdog.fails"
			background_job
			ok "автопочинка выключена"
			;;
		run)
			watchdog_run
			;;
		*)
			if watchdog_on; then cmd_watchdog off; else cmd_watchdog on; fi
			;;
	esac
}

cmd_autoupdate()
{
	case "$1" in
		on)
			need_root autoupdate on
			sync_runtime
			touch "$RT/autoupdate"
			background_job && ok "автообновление включено: проверка раз в сутки"
			;;
		off)
			need_root autoupdate off
			rm -f "$RT/autoupdate"
			background_job
			ok "автообновление выключено"
			;;
		*)
			if autoupdate_on; then cmd_autoupdate off; else cmd_autoupdate on; fi
			;;
	esac
}

# once a day: a newer version is installed and the current strategy restarted with it.
# if the new strategies don't suit the provider, autofix picks another one
auto_update()
{
	local rv
	[ -n "$(find "$RT/update-checked" -mtime -1 2>/dev/null)" ] && return 0
	touch "$RT/update-checked"
	rv=$(remote_version)
	newer "$rv" "$VERSION" || return 0
	# the user went back from this version
	newer "$rv" "$(cat "$RT/skip-version" 2>/dev/null)" || return 0
	log "autoupdate: $VERSION → $rv"
	if cmd_update >/dev/null 2>&1; then
		notify "$(msg "Обновлено до %s" "$rv")"
	else
		log "$(msg "autoupdate: не удалось")"
	fi
}

# called by launchd as root every 5 minutes
watchdog_run()
{
	local fails new
	# a macOS update may have reset what zapret set up
	[ "$(os_build)" = "$(cat "$RT/os-build" 2>/dev/null)" ] || cmd_repair --quiet
	# the project folder belongs to the user: update only while someone is logged in
	autoupdate_on && [ "$(stat -f %Su /dev/console)" != root ] && auto_update
	if telegram_on && ! telegram_running; then
		log "$(msg "watchdog: прокси для Telegram не работал, запускаю")"
		cmd_telegram on >/dev/null
	fi
	watchdog_on || return 0
	running || return 0
	vpn_active && return 0
	[ "$(stat -f %Su /dev/console)" = root ] && return 0
	# check the real path: as the user, through pf and the running engine
	if as_user curl -s -o /dev/null -m 8 https://www.youtube.com/ &&
		as_user curl -s -o /dev/null -m 8 https://redirector.googlevideo.com/generate_204; then
		rm -f "$RT/watchdog.fails"
		return 0
	fi
	# no internet at all is not our problem
	curl -s -o /dev/null -m 8 https://www.apple.com/ || return 0
	fails=$(( $(cat "$RT/watchdog.fails" 2>/dev/null || echo 0) + 1 ))
	echo $fails > "$RT/watchdog.fails"
	log "$(msg "watchdog: YouTube недоступен (%s)" "$fails")"
	[ $fails -ge 2 ] || return 0
	rm -f "$RT/watchdog.fails"
	local old
	old=$(current)
	new=$(cmd_check --quiet | tail -1)
	if [ -n "$new" ] && [ "$new" != "$old" ]; then
		log "watchdog: $old → $new"
		notify "$(msg "«%s» перестала работать, включена «%s»" "$old" "$new")"
	elif [ -z "$new" ]; then
		log "$(msg "watchdog: рабочая стратегия не найдена")"
		notify "$(msg "YouTube недоступен, рабочая стратегия не найдена")"
	fi
}

os_build() { sw_vers -buildVersion 2>/dev/null; }

# after a macOS update (or anything else that broke the setup): puts back the sudoers rule, the
# services and the firewall rules, and starts zapret if it should run. the app calls it when the
# system's build changed, the background job does too. --json: what was fixed, for the app
cmd_repair()
{
	need_root repair "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local json=0 quiet=0 fixed=() a i f=/etc/sudoers.d/zapret-macos
	for a in "$@"; do case "$a" in --json) json=1 ;; --quiet) quiet=1 ;; esac; done
	if ! visudo -c -q -f "$f" >/dev/null 2>&1; then
		install_sudoers
		fixed+=("$(msg "правило sudo для приложения")")
	fi
	if { watchdog_on || autoupdate_on; } && ! launchctl print system/$WD_LABEL >/dev/null 2>&1; then
		rm -f "$WD_PLIST"
		background_job
		fixed+=("$(msg "фоновая проверка")")
	fi
	# not when the user stopped it
	if [ -n "$(current)" ] && [ ! -f "$RT/stopped" ] && autostart_on && ! running; then
		cmd_start >/dev/null 2>&1 && fixed+=("$(msg "zapret запущен")")
	elif running && ! pfctl -a $NQ_ANCHOR -s rules 2>/dev/null | grep -q route-to; then
		cmd_start >/dev/null 2>&1 && fixed+=("$(msg "правила файрвола")")
	fi
	if telegram_on && ! telegram_running; then
		cmd_telegram on >/dev/null 2>&1 && fixed+=("$(msg "прокси для Telegram")")
	fi
	os_build > "$RT/os-build"
	[ ${#fixed[@]} -gt 0 ] && log "repair: ${fixed[*]}"
	if [ $json = 1 ]; then
		local out=""
		for i in "${fixed[@]}"; do out="$out${out:+,}$(jstr "$i")"; done
		echo "{\"fixed\":[$out]}"
	elif [ $quiet = 0 ]; then
		if [ ${#fixed[@]} = 0 ]; then ok "всё на месте"; else for i in "${fixed[@]}"; do ok "восстановлено: %s" "$i"; done; fi
	fi
	[ $quiet = 1 ] && [ ${#fixed[@]} -gt 0 ] && notify "$(msg "macOS обновилась — zapret восстановлен")"
	return 0
}
