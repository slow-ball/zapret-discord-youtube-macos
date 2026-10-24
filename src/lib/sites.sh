# shellcheck shell=bash
# zapret.sh: smart mode: found sites and per-site strategies. Sourced by src/zapret.sh, which defines the constants.

# true if https://$2 answers at all; $1: empty — as root, past the engine, "user" — as nobody, through
# pf and the running engine. $3: seconds to wait
site_ok()
{
	local run=() code
	[ "$1" = user ] && run=(sudo -u nobody)
	code=$("${run[@]}" curl -s -o /dev/null -m "${3:-6}" -w "%{http_code}" "https://$2/")
	[ "${code:-000}" != 000 ]
}

# stops zapret for tests (learn, deep) and brings it back when they end, even if they are interrupted
tests_begin()
{
	TESTS_WAS=$(current)
	TESTS_RUNNING=0
	running && TESTS_RUNNING=1
	TESTS_TMP=$(mktemp -d)
	nfqws_stop
	trap 'tests_end; exit 130' INT TERM
}

tests_end()
{
	trap - INT TERM
	nfqws_untry
	rm -rf "$TESTS_TMP"
	[ "$TESTS_RUNNING" = 1 ] && cmd_start "$TESTS_WAS" >/dev/null
	TESTS_RUNNING=0
}

# true if options $1 open https://$2: the engine runs them for this site only
try_opts()
{
	local ok=1
	printf '%s\n' "$2" > "$TESTS_TMP/site.txt"
	nfqws_site_conf "$1" "$TESTS_TMP/site.txt" "$TESTS_TMP/t.conf"
	nfqws_dry_run "$TESTS_TMP/t.conf" || return 1
	if nfqws_try "$TESTS_TMP/t.conf"; then
		sleep 0.2
		site_ok user "$2" 5 && ok=0
	fi
	nfqws_untry
	return $ok
}

# looks for a strategy for sites the main one doesn't open. a site that opens as it is costs nothing;
# for the others zapret stops for a minute or two and every strategy is tried on them.
# no arguments: found sites and the user's list that were not looked at yet; --all: all of them again
cmd_learn()
{
	need_root learn "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local quiet=0 all=0 norestart=0 a domains=() d need=() tp changed=0 had n so res seen=()
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
	tp=$(mktemp)
	for d in "${domains[@]}"; do
		# only host names: they go into curl and into the lists nfqws reads
		[ -n "$(host_of "$d")" ] || continue
		# the old choice is dropped: the site is looked at from scratch
		had=0
		if awk -F'\t' -v d="$d" '$1 == d { f = 1 } END { exit !f }' "$SITES"; then
			awk -F'\t' -v d="$d" '$1 != d' "$SITES" > "$tp"; cat "$tp" > "$SITES"
			changed=1; had=1
		fi
		grep -qxF "$d" "$SITES_TESTED" || echo "$d" >> "$SITES_TESTED"
		if site_ok "" "$d"; then
			[ $quiet = 1 ] || echo "  ${D}· $d — открывается и без обхода${N}"
		# the running engine still has the dropped profile of the site
		elif running && [ $had = 0 ] && site_ok user "$d"; then
			[ $quiet = 1 ] || ok "$d — работает с основной стратегией"
		else
			need+=("$d")
		fi
	done
	rm -f "$tp"
	if [ ${#need[@]} -gt 0 ]; then
		[ $quiet = 1 ] || echo "${B}Подбираю стратегии для ${#need[@]} сайтов, интернет может ненадолго пропадать…${N}"
		tests_begin
		for d in "${need[@]}"; do
			res=""
			seen=()
			while IFS= read -r n; do
				so=$(site_opts "$n")
				# many strategies share the options for HTTPS: each set is tried once
				[ -n "$so" ] || continue
				[[ " ${seen[*]} " == *" |$so| "* ]] && continue
				seen+=("|$so|")
				if try_opts "$so" "$d"; then res=$n; break; fi
			done < <(strategy_names)
			if [ -z "$res" ]; then
				[ $quiet = 1 ] || bad "$d — ни одна стратегия не помогла, попробовать глубокий подбор"
			else
				printf '%s\t%s\n' "$d" "$res" >> "$SITES"
				changed=1
				[ $quiet = 1 ] || ok "$d — своя стратегия: ${B}$res${N}"
				log "learn: $d → $res"
			fi
		done
		# the main strategy comes back with the sites' profiles
		[ $norestart = 1 ] && TESTS_RUNNING=0
		tests_end
		return 0
	fi
	[ $changed = 1 ] || return 0
	if running && [ $norestart = 0 ]; then
		[ $quiet = 1 ] || echo "Перезапускаю zapret со стратегиями для сайтов…"
		cmd_start >/dev/null && { [ $quiet = 1 ] || ok "готово"; }
	fi
	return 0
}

# a site that doesn't open: it goes into the user's list, gets its own strategy if the main one
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
	local was_running=0
	running && was_running=1
	cmd_learn --quiet --no-restart "$d" >/dev/null
	strategy=$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$SITES" 2>/dev/null)
	# the lists changed: the engine reads them on start
	if [ $was_running = 1 ]; then cmd_start >/dev/null 2>&1; sleep 1; fi
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

# options the deep search tries, the simple ones first. the same tricks as blockcheck of bol-van:
# splitting, disorder, fakes with different ways to make the DPI accept and the server drop them
deep_candidates()
{
	local p f r g=@BASE@/bin/tls_clienthello_www_google_com.bin
	for p in 1 2 midsld 1,midsld sniext+1 host+1 2,sniext+1 1,sniext+1,host+1,midsld,endhost-1; do
		echo "--dpi-desync=multisplit --dpi-desync-split-pos=$p"
		echo "--dpi-desync=multidisorder --dpi-desync-split-pos=$p"
	done
	for p in 1 2 midsld; do
		echo "--dpi-desync=multisplit --dpi-desync-split-pos=$p --dpi-desync-split-seqovl=1"
		echo "--dpi-desync=multisplit --dpi-desync-split-pos=1 --dpi-desync-split-seqovl=681 --dpi-desync-split-seqovl-pattern=$g"
	done | sort -u
	for f in ts badseq md5sig datanoack badsum; do
		for r in 1 6; do
			echo "--dpi-desync=fake --dpi-desync-fooling=$f --dpi-desync-repeats=$r --dpi-desync-fake-tls=$g"
			echo "--dpi-desync=fake --dpi-desync-fooling=$f --dpi-desync-repeats=$r --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"
		done
		for p in 1 midsld 1,midsld; do
			echo "--dpi-desync=fake,multisplit --dpi-desync-split-pos=$p --dpi-desync-fooling=$f --dpi-desync-fake-tls=$g"
			echo "--dpi-desync=fake,multidisorder --dpi-desync-split-pos=$p --dpi-desync-fooling=$f --dpi-desync-fake-tls=$g"
			echo "--dpi-desync=fakedsplit --dpi-desync-split-pos=$p --dpi-desync-fooling=$f"
			echo "--dpi-desync=fakeddisorder --dpi-desync-split-pos=$p --dpi-desync-fooling=$f"
		done
		echo "--dpi-desync=hostfakesplit --dpi-desync-fooling=$f --dpi-desync-hostfakesplit-mod=host=www.google.com"
		echo "--dpi-desync=fake,hostfakesplit --dpi-desync-fooling=$f --dpi-desync-hostfakesplit-mod=host=www.google.com --dpi-desync-fake-tls=$g"
	done
}

# when no strategy helps: hundreds of options of the engine are tried on one site (5-15 minutes),
# and the first working one becomes the site's own strategy. --json: events for the app
cmd_deep()
{
	need_root deep "$@"
	local d=${1:-www.youtube.com} json=0 n=0 total o found="" name
	[ "$2" = --json ] && json=1
	d=$(host_of "$d")
	if [ -z "$d" ]; then
		event error message "Не похоже на адрес сайта"
		die "Не похоже на адрес сайта: $1"
	fi
	installed || die "zapret не установлен. Запустить zapret.command"
	vpn_active && { event error message "Включён VPN — его нужно выключить"; die "Включён VPN — его нужно выключить"; }
	total=$(deep_candidates | wc -l | tr -d ' ')
	event start site "$d" total "$total"
	if site_ok "" "$d"; then
		event finish strategy "" reason "open"
		[ $json = 1 ] || ok "$d открывается и без обхода — дело не в провайдере"
		return 0
	fi
	[ $json = 1 ] || echo "${B}Глубокий подбор для $d: до $total вариантов, 5–15 минут, интернет на это время может пропадать…${N}"
	sync_runtime
	write_lists
	tests_begin
	while IFS= read -r o; do
		n=$((n + 1))
		if [ $json = 1 ]; then event progress tested "$n" option "${o//@BASE@\/bin\//}"; else echo "  $n) ${o//@BASE@\/bin\//}"; fi
		if try_opts "$o" "$d"; then found=$o; break; fi
	done < <(deep_candidates)
	if [ -n "$found" ]; then
		name="Глубокий подбор: $d"
		touch "$DSTRATS"
		{ grep -vF "$name|" "$DSTRATS"; echo "$name|$found"; } > "$TESTS_TMP/d"
		install -m 644 -o root -g wheel "$TESTS_TMP/d" "$DSTRATS"
		awk -F'\t' -v d="$d" '$1 != d' "$SITES" 2>/dev/null > "$TESTS_TMP/s"
		printf '%s\t%s\n' "$d" "$name" >> "$TESTS_TMP/s"
		cat "$TESTS_TMP/s" > "$SITES"
		log "deep $d: $found"
	fi
	# the main strategy comes back, with the site's new profile
	tests_end
	if [ -n "$found" ]; then
		running || cmd_start >/dev/null
		event finish strategy "$name" options "$found"
		[ $json = 1 ] || ok "найдено: ${B}$name${N} ($found) — работает для $d"
	else
		event finish strategy "" reason "none"
		[ $json = 1 ] || bad "ничего не нашлось: провайдер режет $d так, что подмена пакетов не помогает"
	fi
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
