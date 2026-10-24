# shellcheck shell=bash
# zapret.sh: the old menu bar icon (SwiftBar). Sourced by src/zapret.sh, which defines the constants.

cmd_menubar()
{
	if [ "$(id -u)" = 0 ]; then
		as_user "$SELF" menubar "$@"
		return
	fi
	local dir
	case "$1" in
		off)
			dir=$(menubar_dir)
			[ -n "$dir" ] && rm -f "$dir/zapret.10s.sh"
			open -g "swiftbar://refreshallplugins" 2>/dev/null
			ok "иконка убрана"
			return
			;;
	esac
	[ -x "$RT/menubar.sh" ] || die "Сначала нужно запустить zapret"
	if [ ! -d /Applications/SwiftBar.app ]; then
		say "Ставлю SwiftBar (бесплатная программа для иконок в строке меню)…"
		local tmp url
		tmp=$(mktemp -d)
		url=$(curl -fsSL https://api.github.com/repos/swiftbar/SwiftBar/releases/latest |
			/usr/bin/python3 -I -c 'import json,sys; print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith(".zip")))') ||
			die "Не удалось найти SwiftBar. Установить вручную: https://swiftbar.app"
		curl -fL --progress-bar -o "$tmp/sb.zip" "$url" || die "Не удалось скачать SwiftBar"
		ditto -x -k "$tmp/sb.zip" /Applications || die "Не удалось распаковать SwiftBar в /Applications"
		rm -rf "$tmp"
	fi
	dir=$(menubar_dir)
	if [ -z "$dir" ]; then
		dir="$HOME/Library/Application Support/zapret-macos/menubar"
		defaults write com.ameba.SwiftBar PluginDirectory "$dir"
	fi
	mkdir -p "$dir"
	ln -sf "$RT/menubar.sh" "$dir/zapret.10s.sh"
	open -a SwiftBar
	open -g "swiftbar://refreshallplugins" 2>/dev/null
	ok "иконка добавлена в строку меню"
}

# runs a command with the macOS admin password dialog (used by the menu bar icon)
cmd_gui()
{
	if [ "$(id -u)" = 0 ]; then "$SELF" "$@"; return; fi
	osascript - "$SELF" "$@" <<'EOF' >/dev/null 2>&1
on run argv
	set cmd to ""
	repeat with a in argv
		set cmd to cmd & quoted form of (a as text) & " "
	end repeat
	do shell script cmd with administrator privileges
end run
EOF
}
