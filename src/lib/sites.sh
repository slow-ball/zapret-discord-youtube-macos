# shellcheck shell=bash
# zapret.sh: smart mode: found sites and per-site strategies. Sourced by src/zapret.sh, which defines the constants.

# true if https://$2 answers at all; $1 as in probe (empty or a socks port)
site_ok()
{
	local proxy=() code
	[ -n "$1" ] && proxy=(--socks5-hostname "127.0.0.1:$1")
	code=$(curl -s -o /dev/null -m 6 "${proxy[@]}" -w "%{http_code}" "https://$2/")
	[ "${code:-000}" != 000 ]
}

# looks for a tpws strategy for sites the main strategy doesn't open. every tpws strategy runs
# as a socks instance, like in check, so nothing is stopped and it can run in the background.
# no arguments: found sites and the user's list that were not looked at yet; --all: all of them again
cmd_learn()
{
	need_root learn "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local quiet=0 all=0 norestart=0 a domains=() d names=() n i main="" tp pids=() probes=() changed=0 res
	for a in "$@"; do
		case "$a" in --quiet) quiet=1 ;; --all) all=1 ;; --no-restart) norestart=1 ;; *) domains+=("$a") ;; esac
	done
	vpn_active && { [ $quiet = 1 ] && return 1; die "Включён VPN — его нужно выключить."; }
	touch "$SITES" "$SITES_TESTED"
	if [ ${#domains[@]} = 0 ]; then
		while IFS= read -r d; do
			[ $all = 1 ] || ! grep -qxF "$d" "$SITES_TESTED" && domains+=("$d")
		done < <({ cat "$AUTO_LIST" 2>/dev/null; echo; user_cat "$PROJECT/lists/list-user.txt"; } |
			grep -vE '^[[:space:]]*(#|$)' | tr -d '\r' | sort -u)
	fi
	if [ ${#domains[@]} = 0 ]; then
		[ $quiet = 1 ] || ok "Новых сайтов для подбора нет"
		return 0
	fi

	while IFS= read -r n; do names+=("$n"); done < <(tpws_names)
	[ "$(engine_of "$(current)")" = tpws ] && main=$(current)
	for i in "${!names[@]}"; do
		# shellcheck disable=SC2046
		"$Z/tpws/tpws" --socks --user=root --bind-addr=127.0.0.1 --port=$((TEST_PORT + 1 + i)) \
			$(strategy_opts "${names[$i]}") >/dev/null 2>&1 &
		pids+=($!)
	done
	sleep 0.5
	tp=$(mktemp -d)

	for d in "${domains[@]}"; do
		# only host names: they go into curl and into the lists tpws reads
		[ -n "$(host_of "$d")" ] || continue
		# the old choice is dropped: the site is looked at from scratch
		if awk -F'\t' -v d="$d" '$1 == d { f = 1 } END { exit !f }' "$SITES"; then
			awk -F'\t' -v d="$d" '$1 != d' "$SITES" > "$tp/s"; cat "$tp/s" > "$SITES"
			changed=1
		fi
		grep -qxF "$d" "$SITES_TESTED" || echo "$d" >> "$SITES_TESTED"
		if site_ok "" "$d"; then
			[ $quiet = 1 ] || echo "  ${D}· $d — открывается и без обхода${N}"
			continue
		fi
		probes=()
		for i in "${!names[@]}"; do
			( site_ok $((TEST_PORT + 1 + i)) "$d" && touch "$tp/ok$i" ) &
			probes+=($!)
		done
		wait "${probes[@]}"
		res=""
		for i in "${!names[@]}"; do
			if [ -f "$tp/ok$i" ]; then
				[ -z "$res" ] && res=${names[$i]}
				[ "${names[$i]}" = "$main" ] && res=$main
			fi
		done
		rm -f "$tp"/ok*
		if [ -z "$res" ]; then
			[ $quiet = 1 ] || bad "$d — ни одна стратегия tpws не помогла"
		elif [ "$res" = "$main" ]; then
			[ $quiet = 1 ] || ok "$d — работает с основной стратегией"
		else
			printf '%s\t%s\n' "$d" "$res" >> "$SITES"
			changed=1
			[ $quiet = 1 ] || ok "$d — своя стратегия: ${B}$res${N}"
			log "learn: $d → $res"
		fi
	done
	kill "${pids[@]}" 2>/dev/null
	wait "${pids[@]}" 2>/dev/null
	rm -rf "$tp"
	[ $changed = 1 ] || return 0
	if [ -z "$main" ]; then
		[ $quiet = 1 ] || warn "стратегии для сайтов работают только с движком tpws, сейчас выбран nfqws"
	elif running && [ $norestart = 0 ]; then
		[ $quiet = 1 ] || echo "Перезапускаю zapret со стратегиями для сайтов…"
		cmd_start >/dev/null && { [ $quiet = 1 ] || ok "готово"; }
	fi
	return 0
}

# a site that doesn't open: it goes into the user's list, gets its own tpws strategy if the main one
# doesn't open it, and is checked the way a browser opens it. --json: the result for the app
cmd_site()
{
	need_root site "$@"
	local d json=0 added=0 direct=0 works=0 strategy list="$PROJECT/lists/list-user.txt"
	[ "$2" = --json ] && json=1
	# https://www.example.com/page → example.com (subdomains are covered anyway)
	d=$(host_of "$1")
	if [ -z "$d" ]; then
		[ $json = 1 ] && { echo "{\"error\":$(jstr "Не похоже на адрес сайта")}"; return 1; }
		die "Не похоже на адрес сайта: $1"
	fi
	if ! user_cat "$list" | grep -qxF "$d"; then
		user_append "$list" "$d"
		added=1
	fi
	site_ok "" "$d" && direct=1
	cmd_learn --quiet --no-restart "$d" >/dev/null
	strategy=$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$SITES" 2>/dev/null)
	# the lists changed: the engines read them on start
	if running; then cmd_start >/dev/null 2>&1; sleep 1; fi
	as_user curl -s -o /dev/null -m 8 "https://$d/" && works=1
	log "site $d: direct=$direct works=$works strategy=${strategy:-main}"
	if [ $json = 1 ]; then
		printf '{"site":%s,"added":%s,"direct":%s,"works":%s,"strategy":%s}\n' "$(jstr "$d")" \
			"$([ $added = 1 ] && echo true || echo false)" "$([ $direct = 1 ] && echo true || echo false)" \
			"$([ $works = 1 ] && echo true || echo false)" "$(jstr "$strategy")"
		return 0
	fi
	[ $added = 1 ] && ok "$d добавлен в свой список"
	[ $direct = 1 ] && echo "  ${D}· без обхода тоже открывается — значит, мешает не провайдер, а что-то ещё${N}"
	[ -n "$strategy" ] && ok "для $d своя стратегия: ${B}$strategy${N}"
	if [ $works = 1 ]; then ok "$d открывается"; else bad "$d всё ещё не открывается — попробовать подобрать стратегию (пункт меню 3)"; fi
}

# when no strategy helps: blockcheck of bol-van tries hundreds of tpws options on one site (5-15 minutes)
# and the first working one becomes a strategy of its own. on macOS it reloads pf, so zapret is stopped
# meanwhile and comes back afterwards. --json: events for the app
cmd_deep()
{
	need_root deep "$@"
	local d=${1:-www.youtube.com} json=0 out was was_running=0 n=0 line found name
	[ "$2" = --json ] && json=1
	d=$(host_of "$d")
	if [ -z "$d" ]; then
		event error message "Не похоже на адрес сайта"
		die "Не похоже на адрес сайта: $1"
	fi
	[ -x "$Z/blockcheck.sh" ] || die "Нет blockcheck в $Z"
	vpn_active && { event error message "Включён VPN — его нужно выключить"; die "Включён VPN — его нужно выключить"; }
	was=$(current)
	running && was_running=1
	event start site "$d"
	[ $json = 1 ] || echo "${B}Глубокий подбор для $d: 5–15 минут, интернет на это время может пропадать…${N}"
	zapret_stop
	nfqws_stop
	out=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$out'; [ $was_running = 1 ] && '$SELF' start '$was' >/dev/null; exit 130" INT TERM
	BATCH=1 DOMAINS="$d" IPVS=4 ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=1 ENABLE_HTTPS_TLS13=0 ENABLE_HTTP3=0 \
		REPEATS=1 PARALLEL=0 SCANLEVEL=standard SKIP_DNSCHECK=1 SKIP_IPBLOCK=1 SKIP_PKTWS=1 \
		"$Z/blockcheck.sh" 2>&1 | while IFS= read -r line; do
			echo "$line" >> "$out"
			case "$line" in
				"- curl_test"*": tpws "*)
					n=$((n + 1))
					if [ $json = 1 ]; then event progress tested "$n" option "${line#*: tpws }"; else echo "  $n) ${line#*: tpws }"; fi
					;;
			esac
		done
	trap - INT TERM
	found=$(sed -n '/^\* SUMMARY/,$p' "$out" | grep -m1 ' : tpws ' | sed 's/.* : tpws //')
	if [ -n "$found" ]; then
		name="Глубокий подбор: $d"
		touch "$USTRATS"
		grep -vF "$name|" "$USTRATS" > "$out.new"
		echo "$name|$found" >> "$out.new"
		install -m 644 -o root -g wheel "$out.new" "$USTRATS"
		rm -f "$out.new"
		log "deep $d: $found"
		cmd_start "$name" >/dev/null
		event finish strategy "$name" options "$found"
		[ $json = 1 ] || ok "найдено и включено: ${B}$name${N} ($found)"
	else
		[ $was_running = 1 ] && cmd_start "$was" >/dev/null
		if grep -q "working without bypass" "$out"; then
			event finish strategy "" reason "open"
			[ $json = 1 ] || ok "$d открывается и без обхода — дело не в провайдере"
		else
			event finish strategy "" reason "none"
			[ $json = 1 ] || bad "ничего не нашлось: провайдер, похоже, режет $d не так, как умеет обходить tpws"
		fi
	fi
	rm -f "$out"
}

# shows or clears what the smart mode has found
cmd_found()
{
	if [ "$1" = --json ]; then
		local d s first=1
		printf '['
		while IFS= read -r d; do
			s=$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$SITES" 2>/dev/null)
			[ $first = 1 ] || printf ','
			first=0
			printf '{"site":%s,"strategy":%s}' "$(jstr "$d")" "$(jstr "$s")"
		done < <(grep -vE '^[[:space:]]*(#|$)' "$AUTO_LIST" 2>/dev/null)
		echo ']'
		return
	fi
	if [ "$1" = clear ]; then
		need_root found clear
		: > "$AUTO_LIST"; : > "$SITES"; : > "$SITES_TESTED"
		ok "найденные сайты и стратегии для них очищены"
		if running; then cmd_start >/dev/null; fi
		return
	fi
	local d s
	echo "${B}Найденные сайты${N} ${D}(умный режим)${N}"
	if [ -s "$AUTO_LIST" ]; then
		while IFS= read -r d; do
			s=$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$SITES" 2>/dev/null)
			echo "  $d${s:+  ${D}→ $s${N}}"
		done < <(grep -vE '^[[:space:]]*(#|$)' "$AUTO_LIST")
	else
		echo "  ${D}пока ничего${N}"
	fi
	if [ -s "$SITES" ]; then
		echo; echo "${B}Свои стратегии для сайтов${N}"
		awk -F'\t' '{ printf "  %s → %s\n", $1, $2 }' "$SITES"
	fi
}
