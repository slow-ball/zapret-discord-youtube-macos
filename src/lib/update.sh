# shellcheck shell=bash
# zapret.sh: update / rollback / uninstall. Sourced by src/zapret.sh, which defines the constants.

# a version number, nothing else: it goes into a URL
valid_version() { [[ $1 =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; }

# the version that was installed before the last update: the app offers to go back to it.
# versions before 3.0 had another engine and can't come back this way
previous_version()
{
	local p
	p=$(cat "$RT/previous" 2>/dev/null)
	valid_version "$p" && [ "$p" != "$VERSION" ] && newer "$p" 2.99 && echo "$p"
}

# installs the latest release, or with --to a given one (going back is allowed only to 3.0 or later).
# tests set ZAPRET_UPDATE_REF to a commit: only root can pass it, the sudoers rule allows no variables
cmd_update()
{
	need_root update "$@"
	local rv="" ref tmp src back=0
	if [ "$1" = --to ]; then
		valid_version "$2" || die "Не похоже на номер версии: $2"
		newer "$2" 2.99 || die "Вернуться можно только к версии 3.0 и новее"
		rv=$2; back=1
	elif [ -n "$ZAPRET_UPDATE_REF" ]; then
		rv=$(curl -fsSL -m 8 "https://raw.githubusercontent.com/$REPO/$ZAPRET_UPDATE_REF/src/VERSION" | head -1)
	else
		rv=$(remote_version)
	fi
	[ -n "$rv" ] || die "Не удалось проверить обновления (GitHub недоступен?)"
	if [ $back = 0 ] && ! newer "$rv" "$VERSION"; then
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
	[ "$rv" = "$VERSION" ] && { ok "Уже установлена версия $rv"; return; }
	echo "$([ $back = 1 ] && echo Возвращаю || echo Обновляю) $VERSION → ${B}$rv${N}"
	ref=${ZAPRET_UPDATE_REF:-refs/tags/v$rv}
	# in /tmp: root's own temporary folder is closed to the user, who copies the files into the project
	tmp=$(mktemp -d /tmp/zapret-update.XXXXXX)
	curl -fsSL -o "$tmp/u.tar.gz" "https://github.com/$REPO/archive/$ref.tar.gz" || { rm -rf "$tmp"; die "Не удалось скачать $rv"; }
	mkdir "$tmp/x"
	tar -xzf "$tmp/u.tar.gz" -C "$tmp/x" || { rm -rf "$tmp"; die "Не удалось распаковать"; }
	src=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)
	[ "$(cat "$src/src/VERSION" 2>/dev/null)" = "$rv" ] || { rm -rf "$tmp"; die "В загрузке не та версия"; }
	chmod -R go+rX "$tmp"
	if [ -d "$PROJECT/.git" ]; then
		as_user git -C "$PROJECT" pull --ff-only || die "git pull не удался"
	else
		# свои списки не трогаем
		as_user rsync -a --exclude lists/list-user.txt --exclude lists/list-exclude-user.txt \
			"$src/" "$PROJECT/" || die "Не удалось обновить файлы"
	fi
	ok "Файлы обновлены"
	echo "$VERSION" > "$RT/previous"
	# after going back the daily autoupdate leaves the version it came from alone
	if [ $back = 1 ]; then echo "$VERSION" > "$RT/skip-version"; else rm -f "$RT/skip-version"; fi
	log "update: $VERSION → $rv"
	# the new script runs from this download, never from the project folder: any program of the user
	# can change that one
	finish_update "$src/src/zapret.sh"
	rm -rf "$tmp"
}

# after new files: the root copy, the running strategy and the app follow them.
# done by the new script ($1): it knows the new version
finish_update()
{
	local new=$1
	if running; then
		echo "Перезапускаю zapret…"
		ZAPRET_PROJECT="$PROJECT" "$new" start
	else
		# the root copy the app and launchd use must be new too
		ZAPRET_PROJECT="$PROJECT" "$new" sync
	fi
	app_installed && ZAPRET_PROJECT="$PROJECT" "$new" app --if-outdated
}

cmd_uninstall()
{
	need_root uninstall "$@"
	local a=y
	# --yes: confirmed elsewhere (the app asks itself)
	[ "$1" = --yes ] || read -r -p "Удалить zapret полностью (службы, правила файрвола, $RT)? [y/N] " a
	case "$a" in y|Y) ;; *) return ;; esac
	rm -f "$RT/autofix" "$RT/autoupdate"
	background_job
	cmd_menubar off >/dev/null 2>&1
	nfqws_stop
	rm -f "$NQ_PLIST" "$NQ_READY"
	launchctl bootout system/$TG_LABEL 2>/dev/null
	rm -f "$TG_PLIST"
	# zapret of bol-van from versions before 3.0, if the update didn't remove it
	if [ -x "$LEGACY/uninstall_easy.sh" ] && [ -f "$LEGACY/config.bak-before-macos" ]; then
		"$LEGACY/uninstall_easy.sh" >/dev/null 2>&1
		rm -f "$LEGACY_PLIST"
		rm -rf "$LEGACY"
	fi
	rm -f /etc/sudoers.d/zapret-macos
	rm -rf "$RT"
	ok "zapret удалён. Папку проекта можно удалить вручную."
}
