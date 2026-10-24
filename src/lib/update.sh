# shellcheck shell=bash
# zapret.sh: update / restore / uninstall. Sourced by src/zapret.sh, which defines the constants.

cmd_update()
{
	local rv tmp
	rv=$(remote_version)
	[ -n "$rv" ] || die "Не удалось проверить обновления (GitHub недоступен?)"
	if ! newer "$rv" "$VERSION"; then
		# the files are new but the root copy the app and services use may not be: the project
		# folder was replaced by hand, or an update stopped halfway
		if [ "$SRC" != "$RT" ] && [ "$(cat "$RT/VERSION" 2>/dev/null)" != "$VERSION" ]; then
			finish_update "$SELF"
			ok "Обновлено до $VERSION"
		else
			ok "Установлена последняя версия ($VERSION)"
		fi
		return
	fi
	echo "Обновляю $VERSION → ${B}$rv${N}"
	local src
	# in /tmp: root's own temporary folder is closed to the user, who copies the files into the project
	tmp=$(mktemp -d /tmp/zapret-update.XXXXXX)
	curl -fsSL -o "$tmp/u.tar.gz" "https://github.com/$REPO/archive/refs/heads/main.tar.gz" || die "Не удалось скачать"
	tar -xzf "$tmp/u.tar.gz" -C "$tmp" || die "Не удалось распаковать"
	src="$tmp/zapret-discord-youtube-macos-main"
	chmod -R go+rX "$tmp"
	if [ -d "$PROJECT/.git" ]; then
		as_user git -C "$PROJECT" pull --ff-only || die "git pull не удался"
	else
		# свои списки не трогаем
		as_user rsync -a --exclude lists/list-user.txt --exclude lists/list-exclude-user.txt \
			"$src/" "$PROJECT/" || die "Не удалось обновить файлы"
	fi
	ok "Файлы обновлены"
	# as root (the daily autoupdate) the new script runs from this download, never from the project
	# folder: any program of the user can change that one
	if [ "$(id -u)" = 0 ]; then finish_update "$src/src/zapret.sh"; else finish_update "$PROJECT/src/zapret.sh"; fi
	rm -rf "$tmp"
}

# after new files: the root copy, the running strategy and the app follow them.
# done by the new script ($1): it knows the new version
finish_update()
{
	local new=$1 root=()
	[ "$(id -u)" = 0 ] || root=(sudo)
	if running; then
		echo "Перезапускаю zapret с новыми списками…"
		ZAPRET_PROJECT="$PROJECT" "${root[@]}" "$new" start "$(current)"
	else
		# the root copy the app and launchd use must be new too
		ZAPRET_PROJECT="$PROJECT" "${root[@]}" "$new" sync
	fi
	app_installed && ZAPRET_PROJECT="$PROJECT" "$new" app --if-outdated
}

cmd_restore()
{
	need_root restore
	[ -f "$Z/config.bak-before-macos" ] || die "Резервной копии нет"
	nfqws_stop
	rm -f "$NQ_PLIST"
	launchctl enable system/zapret
	cp "$Z/config.bak-before-macos" "$Z/config"
	rm -f "$Z/init.d/macos/custom.d/90-block-quic"
	zapret_stop
	"$Z/init.d/macos/zapret" start >/dev/null 2>&1
	ok "Исходный конфиг zapret восстановлен"
}

cmd_uninstall()
{
	need_root uninstall "$@"
	local a=y
	# --yes: confirmed elsewhere (the app asks itself)
	[ "$1" = --yes ] || read -r -p "Удалить zapret полностью (служба, правила файрвола, /opt/zapret)? [y/N] " a
	case "$a" in y|Y) ;; *) return ;; esac
	rm -f "$RT/autofix" "$RT/autoupdate"
	background_job
	cmd_menubar off >/dev/null 2>&1
	nfqws_stop
	rm -f "$NQ_PLIST" "$NQ_READY"
	launchctl bootout system/$TG_LABEL 2>/dev/null
	rm -f "$TG_PLIST"
	[ -x "$Z/uninstall_easy.sh" ] && "$Z/uninstall_easy.sh" >/dev/null 2>&1
	rm -f /Library/LaunchDaemons/zapret.plist /etc/sudoers.d/zapret-macos
	rm -rf "$Z" "$RT"
	ok "zapret удалён. Папку проекта можно удалить вручную."
}
