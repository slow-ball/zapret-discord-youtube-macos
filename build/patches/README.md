# Патчи utunws

Сюда кладутся патчи к исходникам Flowseal/zapret-mac-discord-youtube (`git diff` от корня их репозитория, `-p1`).
`build/utunws.sh` применяет их по алфавиту. После изменения — новая сборка в Actions (workflow «utunws»)
и новые `NQ_TAG` и `NQ_SHA256` в `src/zapret.sh`.
