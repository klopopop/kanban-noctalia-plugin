#!/usr/bin/env bash
# Win+Alt+K: текст из буфера — карточкой в первую колонку текущей канбан-доски
# (без открытия панели; уведомление покажет служба плагина pvs/kanban).
text=$(wl-paste --no-newline --type text 2>/dev/null)
if [[ -z "${text//[[:space:]]/}" ]]; then
    notify-send -a Канбан "Карточка не создана" "В буфере обмена нет текста"
    exit 0
fi
exec noctalia msg plugin pvs/kanban:service all add "$text"
