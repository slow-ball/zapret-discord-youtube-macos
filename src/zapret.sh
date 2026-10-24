#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# zapret-discord-youtube-macos — управление zapret на macOS.
# Движок — nfqws (utunws, собранный из порта Flowseal), стратегии — Windows-версии и свои.
# Запуск без аргументов открывает меню. Команды: см. usage().

# strings compare byte by byte: awk compares them by the collation of the locale, and in some locales
# two different Russian strings come out equal. LC_ALL would override LC_COLLATE
unset LC_ALL
export LC_COLLATE=C
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF="$SRC/$(basename "${BASH_SOURCE[0]}")"
RT=/opt/zapret-macos          # копия скриптов, принадлежащая root: её вызывают launchd и приложение
LEGACY=/opt/zapret            # zapret от bol-van из версий до 3.0
LEGACY_PLIST=/Library/LaunchDaemons/zapret.plist
# tests (only they) put these elsewhere; sudo and launchd never pass this variable
if [ "$ZAPRET_LIB_ONLY" = 1 ]; then
	RT=${ZAPRET_TEST_RT:-$RT}; LEGACY=${ZAPRET_TEST_LEGACY:-$LEGACY}; LEGACY_PLIST=${ZAPRET_TEST_LEGACY_PLIST:-$LEGACY_PLIST}
fi
REPO=slow-ball/zapret-discord-youtube-macos
# обновления подписаны одним из этих ключей (build/release.sh); без верной подписи обновление не ставится.
# запасной хранится не на компьютере: им подписывают, если основной потерян
RELEASE_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKLGLi13f9yB7KucbwVHTl0yc84E4bt4TJgMI0oNkdl"
RELEASE_KEY_BACKUP="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBANscZ3X47PUq7WCPh/r4aSqI2ouJTC49NI+oKPGSNQ"
NQ_TAG=utunws-1               # наша сборка utunws (build/utunws.sh, workflow «utunws»)
NQ_SHA256=f4e94bc227c28413bcd92102f836f9aced642f612ab4793634e47027f5b59703
APPTAG=utunws-9               # релиз с zapret-app.zip (workflow «utunws»); пусто — приложение собирается из исходников
APPSHA256=5b6edf13716be3d6ba9540ff86a547c12aeaa17184899b9988b604cce9644d32
TGVER=v1.11.2                 # Flowseal/tg-ws-proxy: прокси для Telegram Desktop
TGSHA256=d159eece1b6331a06803fd193dc0ac8406022244f961793c1441b01f4b34cfac
TG_LABEL=com.zapret-macos.telegram
TG_PLIST=/Library/LaunchDaemons/$TG_LABEL.plist
WD_LABEL=com.zapret-macos.watchdog
WD_PLIST=/Library/LaunchDaemons/$WD_LABEL.plist
NQ_LABEL=com.zapret-macos.nfqws
NQ_PLIST=/Library/LaunchDaemons/$NQ_LABEL.plist
NQ_ANCHOR=com.apple/zapret-macos
NQ_READY=/var/run/zapret-macos.nfqws-ready
AUTO_LIST=$RT/lists/list-auto.txt     # sites the smart mode found blocked
SITES=$RT/site-strategies             # site<TAB>strategy, filled by learn and deep
CURRENT=$RT/current                   # the strategy that runs
SITES_TESTED=$RT/site-tested          # sites learn has already looked at
WORKED=$RT/check-worked               # strategies that passed the last check, the best first
LOG=/var/log/zapret-macos.log

if [ "$SRC" = "$RT" ]; then
	PROJECT=$(cat "$RT/project" 2>/dev/null)
elif [ -n "$ZAPRET_PROJECT" ]; then
	# an update runs the new script from its download; the root copy above ignores this
	PROJECT=$ZAPRET_PROJECT
else
	PROJECT=$(dirname "$SRC")
fi
NQ_STRATS="$SRC/nfqws/strategies.tsv"     # the Windows version's
OWN_STRATS="$SRC/nfqws/macos.conf"         # our own
# found by the deep search (cmd_deep). root-owned on purpose: they go into the config of the engine
DSTRATS=$RT/strategies-deep.conf
VERSION=$(cat "$SRC/VERSION" 2>/dev/null)

TESTS="https://www.youtube.com/
https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg
https://redirector.googlevideo.com/generate_204
https://discord.com/"

if [ -t 1 ]; then
	B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
fi
# messages are Russian printf formats with their arguments; in English their formats come from
# lang/en.tsv (Russian<TAB>English). the language is the one of the user's macOS (see ui_lang)
msg()
{
	local f=$1 e
	shift
	if [ "$UI" = en ]; then
		e=$(awk -F'\t' -v k="$f" '$1 == k { print $2; exit }' "$SRC/lang/en.tsv" 2>/dev/null)
		[ -n "$e" ] && f=$e
	fi
	# shellcheck disable=SC2059  # the format comes from this code or its table
	printf "$f" "$@"
}
say()  { msg "$@"; echo; }
ok()   { echo "  ${G}✓${N} $(msg "$@")"; }
bad()  { echo "  ${R}✗${N} $(msg "$@")"; }
warn() { echo "  ${Y}!${N} $(msg "$@")"; }
die()  { echo "${R}$(msg "$@")${N}" >&2; exit 1; }
log()  { echo "$(date '+%F %T') $*" >> "$LOG"; }

# the code lives in lib/: next to this script, so the root copy in $RT sources root-owned files
# shellcheck source=lib/helpers.sh
. "$SRC/lib/helpers.sh"
# shellcheck source=lib/nfqws.sh
. "$SRC/lib/nfqws.sh"
# shellcheck source=lib/start.sh
. "$SRC/lib/start.sh"
# shellcheck source=lib/telegram.sh
. "$SRC/lib/telegram.sh"
# shellcheck source=lib/sites.sh
. "$SRC/lib/sites.sh"
# shellcheck source=lib/check.sh
. "$SRC/lib/check.sh"
# shellcheck source=lib/diag.sh
. "$SRC/lib/diag.sh"
# shellcheck source=lib/service.sh
. "$SRC/lib/service.sh"
# shellcheck source=lib/app.sh
. "$SRC/lib/app.sh"
# shellcheck source=lib/swiftbar.sh
. "$SRC/lib/swiftbar.sh"
# shellcheck source=lib/update.sh
. "$SRC/lib/update.sh"
# shellcheck source=lib/menu.sh
. "$SRC/lib/menu.sh"

# ru or en: the first language of the logged in user's macOS. as root too: the app and launchd run
# the script as root, the messages are for the user. ZAPRET_LANG — for tests and the curious
ui_lang()
{
	local u l
	u=$(console_user)
	if [ "$(id -u)" = 0 ]; then
		[ -n "$u" ] && [ "$u" != root ] && l=$(sudo -u "$u" defaults read -g AppleLanguages 2>/dev/null)
	else
		l=$(defaults read -g AppleLanguages 2>/dev/null)
	fi
	l=$(printf '%s\n' "$l" | sed -n '2p' | tr -d ' ",')
	case "$l" in ru*|be*|kk*|ky*|"") echo ru ;; *) echo en ;; esac
}

# tests source this script for its functions only
if [ "$ZAPRET_LIB_ONLY" = 1 ]; then UI=${ZAPRET_LANG:-ru}; return 0; fi
UI=${ZAPRET_LANG:-$(ui_lang)}

case "$1" in
	"" | menu)  need_root; if [ -x "$RT/zapret.sh" ]; then cmd_menu; else cmd_install && cmd_menu; fi ;;
	install)    shift; cmd_install "$@" ;;
	start)      shift; cmd_start "$@" ;;
	stop)       cmd_stop ;;
	status)     shift; cmd_status "$@" ;;
	list)       strategy_names ;;
	check)      shift; cmd_check "$@" ;;
	diag)       shift; cmd_diag "$@" ;;
	dns)        cmd_dns ;;
	autostart)  shift; cmd_autostart "$@" ;;
	watchdog)   shift; cmd_watchdog "$@" ;;
	autoupdate) shift; cmd_autoupdate "$@" ;;
	telegram)   shift; cmd_telegram "$@" ;;
	app)        shift; cmd_app "$@" ;;
	# an update of a stopped zapret ends here: the old engine of 2.x goes away too
	sync)       need_root sync; sync_runtime; migrate_legacy ;;
	menubar)    shift; cmd_menubar "$@" ;;
	scope)      shift; cmd_scope "$@" ;;
	found)      shift; cmd_found "$@" ;;
	site)       shift; cmd_site "$@" ;;
	deep)       shift; cmd_deep "$@" ;;
	game)       shift; cmd_game "$@" ;;
	learn)      shift; cmd_learn "$@" ;;
	gui)        shift; cmd_gui "$@" ;;
	update)     shift; cmd_update "$@" ;;
	repair)     shift; cmd_repair "$@" ;;
	uninstall)  shift; cmd_uninstall "$@" ;;
	help|-h|--help) usage ;;
	*)          usage; exit 1 ;;
esac
