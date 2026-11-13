#!/usr/bin/env bash
# Win+Ctrl+K: выделить область экрана — карточка со скриншотом в первой колонке
# текущей канбан-доски. Картинка ложится в <папка досок>/attachments/, в тексте
# карточки — ![[имя.png]] (Obsidian покажет её у себя, на листке — миниатюра).
set -euo pipefail
geom=$(slurp -d) || exit 0
tmp=$(mktemp --suffix=.png)
grim -g "$geom" "$tmp"
exec noctalia msg plugin pvs/kanban:service all shot "$tmp"
