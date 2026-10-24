# shellcheck shell=bash
# zapret.sh: check (strategy search). Sourced by src/zapret.sh, which defines the constants.

# true if a strategy ($1 name, $2 bytes/s, $3 voice 0/1) beats the best one so far ($4 name, $5, $6).
# voice wins; speeds are noisy, so among equals the earlier stays unless another is clearly faster,
# and nfqws (the Windows version's strategies) beats tpws unless tpws is clearly faster
better()
{
	[ -z "$4" ] && return 0
	[ "$3" -gt "$6" ] && return 0
	[ "$3" = "$6" ] || return 1
	[ "$2" -gt $(($5 * 3 / 2)) ] && return 0
	[ "$(engine_of "$1")" = nfqws ] && [ "$(engine_of "$4")" = tpws ] && [ $(($2 * 3 / 2)) -ge "$5" ]
}

# tpws: every strategy is tested in parallel through temporary socks instances.
# both tpws (--user=root) and curl run as root, so the system pf redirect doesn't touch them
# and the running zapret can stay up.
# nfqws can't run as a proxy: its strategies are started one by one for real and tested as nobody,
# so the running zapret is stopped for that time. --quick skips nfqws.
cmd_check()
{
	need_root check "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local auto=0 quiet=0 quick=0 json=0 a
	for a in "$@"; do
		case "$a" in
			--auto) auto=1 ;;
			--quiet) quiet=1; auto=1 ;;
			--quick) quick=1 ;;
			# events for the app instead of text; applies the best strategy itself
			--json) json=1; quiet=1; auto=1 ;;
		esac
	done
	if vpn_active; then
		event error message "Включён VPN — его нужно выключить"
		[ $quiet = 1 ] && return 1
		die "Включён VPN — его нужно выключить, иначе проверка покажет не провайдера, а VPN."
	fi

	local tmp n=0 pids=() name base vbase=0 voice best_voice=-1 total
	total=$(tpws_names | wc -l | tr -d ' ')
	[ $quick = 0 ] && total=$((total + $(nfqws_names | wc -l | tr -d ' ')))
	event start total "$total"
	tmp=$(mktemp -d)
	[ $quiet = 1 ] || echo "${B}Проверка без zapret…${N}"
	base=$(probe "")
	# tpws doesn't touch UDP: for its strategies voice works exactly as without zapret
	stun_ok "" && vbase=1
	[ $quiet = 1 ] || echo "  открылось ${base% *}, голос Discord $([ $vbase = 1 ] && echo ✓ || echo ✗) — дальше проверяю стратегии tpws параллельно"
	event base pass "${base% *}" voice "$vbase"

	while IFS= read -r name; do
		n=$((n + 1))
		(
			# shellcheck disable=SC2046
			"$Z/tpws/tpws" --socks --user=root --bind-addr=127.0.0.1 --port=$((TEST_PORT + n)) \
				$(strategy_opts "$name") >/dev/null 2>&1 &
			tp=$!
			sleep 0.5
			probe $((TEST_PORT + n)) > "$tmp/$n"
			kill $tp 2>/dev/null
		) &
		pids+=($!)
	done < <(tpws_names)
	wait "${pids[@]}"

	# the parallel run decides pass/fail; speed is measured again one by one for the winners
	local best="" best_speed=-1 res pass yt
	consider()
	{
		local v
		[ "$4" = 1 ] && v="голос ✓" || v="голос ✗"
		[ $quiet = 1 ] || ok "$(printf '%-36s %s  %5s КБ/с  %s' "$1" "$2" $(($3 / 1024)) "$v")"
		event result name "$1" ok 1 pass "$2" kbps "$(($3 / 1024))" voice "$4"
		if better "$1" "$3" "$4" "$best" "$best_speed" "$best_voice"; then
			best=$1; best_speed=$3; best_voice=$4
		fi
	}
	n=0
	[ $quiet = 1 ] || echo
	while IFS= read -r name; do
		n=$((n + 1))
		res=$(cat "$tmp/$n" 2>/dev/null)
		pass=${res% *}
		if [ "${pass%/*}" = "${pass#*/}" ]; then
			# shellcheck disable=SC2046
			"$Z/tpws/tpws" --socks --user=root --bind-addr=127.0.0.1 --port=$TEST_PORT \
				$(strategy_opts "$name") >/dev/null 2>&1 &
			local tp=$!
			sleep 0.3
			yt=$(probe $TEST_PORT); yt=${yt#* }
			kill $tp 2>/dev/null; wait $tp 2>/dev/null
			consider "$name" "$pass" "$yt" $vbase
		else
			[ $quiet = 1 ] || echo "  ${D}✗ $(printf '%-36s %s' "$name" "$pass")${N}"
			event result name "$name" ok 0 pass "$pass"
		fi
	done < <(tpws_names)

	local was was_running=0
	was=$(current)
	running && was_running=1
	if [ $quick = 0 ] && sync_runtime && write_lists >/dev/null && { [ $quiet = 1 ] && nfqws_install >/dev/null || nfqws_install; }; then
		[ $quiet = 1 ] || { echo; echo "${B}Стратегии nfqws проверяются по очереди, интернет на это время может пропадать…${N}"; }
		zapret_stop
		nfqws_stop
		local rp=""
		# shellcheck disable=SC2064
		trap "[ -n \"\$rp\" ] && kill \$rp 2>/dev/null; wait; rm -rf '$tmp'; [ $was_running = 1 ] && '$SELF' start '$was' >/dev/null; exit 130" INT TERM
		while IFS= read -r name; do
			nfqws_conf "$name" "$tmp/nq.conf" || continue
			"$RT/nfqws/run.sh" "$tmp/nq.conf" >/dev/null 2>&1 &
			rp=$!
			if nfqws_wait_ready; then
				sleep 0.3
				res=$(probe user 1)
			else
				res="0/0 0"
			fi
			pass=${res% *}; yt=${res#* }
			voice=0
			if [ "${pass%/*}" = "${pass#*/}" ] && [ "${pass%/*}" != 0 ]; then
				stun_ok user && voice=1
			fi
			kill $rp 2>/dev/null; wait $rp 2>/dev/null
			rp=""
			if [ "${pass%/*}" = "${pass#*/}" ] && [ "${pass%/*}" != 0 ]; then
				consider "$name" "$pass" "$yt" $voice
			else
				[ $quiet = 1 ] || echo "  ${D}✗ $(printf '%-36s %s' "$name" "$pass")${N}"
				event result name "$name" ok 0 pass "$pass"
			fi
		done < <(nfqws_names)
		trap - INT TERM
	fi
	rm -rf "$tmp"

	if [ -z "$best" ]; then
		event finish best ""
		[ $quiet = 1 ] || { echo; bad "Ни одна стратегия не прошла все проверки."; echo "  Можно создать Issue на GitHub и приложить этот вывод и вывод диагностики."; }
		[ $was_running = 1 ] && ! running && cmd_start "$was" >/dev/null
		return 1
	fi
	[ $quiet = 1 ] || { echo; echo "Лучшая: ${B}$best${N} ($((best_speed / 1024)) КБ/с, голос Discord $([ "$best_voice" = 1 ] && echo ✓ || echo ✗))"; }
	if [ $auto = 0 ]; then
		read -r -p "Применить? [Y/n] " a
		case "$a" in
			n|N) [ $was_running = 1 ] && ! running && cmd_start "$was"; return 0 ;;
		esac
	fi
	if [ "$best" = "$(current)" ] && running; then
		[ $quiet = 1 ] || ok "Она уже включена."
	elif [ $quiet = 1 ]; then
		cmd_start "$best" >/dev/null
	else
		cmd_start "$best"
	fi
	event finish best "$best" kbps "$((best_speed / 1024))" voice "$best_voice"
	# watchdog reads the chosen name from the last line
	[ $quiet = 1 ] && [ $json = 0 ] && echo "$best"
	return 0
}
