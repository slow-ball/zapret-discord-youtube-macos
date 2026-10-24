#!/bin/bash
# <xbar.title>zapret</xbar.title>
# <xbar.desc>zapret-discord-youtube-macos: статус и переключение стратегий</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

RT=/opt/zapret-macos
CTL=$RT/zapret.sh
PROJECT=$(cat "$RT/project" 2>/dev/null)
cur=$(head -1 "$RT/current" 2>/dev/null)
job=com.zapret-macos.nfqws

if pgrep -qx utunws; then
	echo "| sfimage=checkmark.shield.fill"
	echo "---"
	echo "zapret работает | sfimage=circle.fill sfcolor=#30D158"
	echo "Стратегия: $cur"
	echo "Остановить | bash=$CTL param1=gui param2=stop terminal=false refresh=true sfimage=stop.fill"
	echo "Перезапустить | bash=$CTL param1=gui param2=start terminal=false refresh=true sfimage=arrow.clockwise"
else
	echo "| sfimage=shield.slash"
	echo "---"
	echo "zapret остановлен | sfimage=circle.fill sfcolor=#FF453A"
	echo "Запустить${cur:+ ($cur)} | bash=$CTL param1=gui param2=start terminal=false refresh=true sfimage=play.fill"
fi

echo "---"
echo "Стратегия | sfimage=slider.horizontal.3"
strategy_item()
{
	local mark=""
	[ "$1" = "$cur" ] && mark=" checked=true"
	echo "--$1 | bash=$CTL param1=gui param2=start param3=\"$1\" terminal=false refresh=true$mark"
}
echo "--Windows-версия | disabled=true"
awk -F'\t' 'NF == 2 { print "nfqws " $2 }' "$RT/nfqws/strategies.tsv" 2>/dev/null | while IFS= read -r n; do strategy_item "$n"; done
echo "-----"
echo "--macOS | disabled=true"
grep -hvE '^\s*(#|$)' "$RT/nfqws/macos.conf" "$RT/strategies-deep.conf" 2>/dev/null | cut -d'|' -f1 | while IFS= read -r n; do strategy_item "$n"; done
echo "Подобрать автоматически… | bash=$CTL param1=check terminal=true sfimage=wand.and.stars"
echo "---"

if launchctl print-disabled system 2>/dev/null | grep -qE "\"$job\" => (true|disabled)"; then
	echo "Автозапуск | bash=$CTL param1=gui param2=autostart param3=on terminal=false refresh=true"
else
	echo "Автозапуск | bash=$CTL param1=gui param2=autostart param3=off terminal=false refresh=true checked=true"
fi
if [ -f "$RT/autofix" ]; then
	echo "Автопочинка | bash=$CTL param1=gui param2=watchdog param3=off terminal=false refresh=true checked=true"
else
	echo "Автопочинка | bash=$CTL param1=gui param2=watchdog param3=on terminal=false refresh=true"
fi
scope=$(cat "$RT/scope" 2>/dev/null)
echo "Сайты | sfimage=globe"
for s in "all|Все" "smart|Умный: сами найденные заблокированные" "lists|Только YouTube, Discord и свои списки"; do
	mark=""
	[ "${s%%|*}" = "${scope:-all}" ] && mark=" checked=true"
	echo "--${s#*|} | bash=$CTL param1=gui param2=scope param3=${s%%|*} terminal=false refresh=true$mark"
done
if [ -f "$RT/autoupdate" ]; then
	echo "Автообновление | bash=$CTL param1=gui param2=autoupdate param3=off terminal=false refresh=true checked=true"
else
	echo "Автообновление | bash=$CTL param1=gui param2=autoupdate param3=on terminal=false refresh=true"
fi
echo "---"
echo "Диагностика… | bash=$CTL param1=diag terminal=true sfimage=stethoscope"
echo "Найденные сайты… | bash=$CTL param1=found terminal=true sfimage=sparkle.magnifyingglass"
echo "Мои списки доменов | bash=/usr/bin/open param1=-t param2=\"$PROJECT/lists/list-user.txt\" terminal=false sfimage=list.bullet"
echo "Открыть меню… | bash=$CTL terminal=true sfimage=terminal"
echo "Проверить обновления… | bash=$CTL param1=update terminal=true sfimage=arrow.down.circle"
echo "Папка проекта | bash=/usr/bin/open param1=\"$PROJECT\" terminal=false sfimage=folder"
