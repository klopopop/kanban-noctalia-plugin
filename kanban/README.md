# Kanban

Kanban boards for Noctalia with cards drawn as paper sticky notes — tilted
sheets with a soft shadow, a strip of torn-edge tape and a handwritten font.
Boards are plain markdown in the [Obsidian Kanban](https://github.com/mgmeyers/obsidian-kanban)
format, so every board opens and edits in Obsidian too.

## Plugin

| Field | Value |
| --- | --- |
| ID | `pvs/kanban` |
| Entries | panel: `panel`; service: `service`; bar widget: `bar`; desktop widget: `desk`; launcher: `launcher` (`/kb`) |

## Features

- Board panel: lanes of sticky-note cards, drag and drop between and within
  lanes, click to edit, drop on the trash to delete.
- Several boards: every Obsidian Kanban `.md` in the boards folder is a tab;
  create, rename (renames the file), delete (to the system trash).
- Lanes: add, rename, reorder, delete, mark as "complete" (`**Complete**`).
- Due dates `@{YYYY-MM-DD}`: shown on the card, overdue cards get red tape;
  the service sends a reminder once a day per card that is due or overdue.
- Tags `#tag`: shown on the card and as a filter row.
- Per-card paper colour; archive (`***` / `## Archive`) for the complete lane.
- Bar widget: number of cards in progress, red when something is overdue.
- Desktop widget: cards in progress as small sheets.
- Launcher `/kb text`: add a card to any lane, search cards.
- Undo (Ctrl+Z), keyboard control (arrows, Enter, Delete, n, p, 1–9), search (Ctrl+F).
- Pomodoro with a countdown in the bar; time in lane on the card; weekly summary.
- Repeating cards (`#каждую-неделю` …), per-lane card limit.
- Checklists with progress, `[[note]]` / URL links (paperclip), screenshot cards, `!`/`!!` priority with a push pin.
- Window size as % of the visible screen area (`size_percent`) and a fullscreen toggle.
- IPC: `noctalia msg plugin pvs/kanban:service all add "text"` · `open` · `shot <png>` · `check` · `summary` · `pomo-stop`.

## Requirements

ImageMagick 7 (`magick`) draws the tilted sheets (plugin API 43 has no
rotation for `ui.*`); `find`, `grep`, `mv`, `gio`, `xdg-open`. A handwritten
font with the scripts you write in — Pangolin by default
(`~/.local/share/fonts/Pangolin-Regular.ttf`, SIL OFL).

## Settings

| Key | Default | |
| --- | --- | --- |
| `boards_dir` | `~/Documents/obsidian/kanban-boards` | Boards folder (searched recursively) |
| `board_path` | `~/Documents/obsidian/kanban-boards/Канбан.md` | Default board |
| `font_path` | `~/.local/share/fonts/Pangolin-Regular.ttf` | Card font, empty = shell font |
| `size_percent` | 85 | Board window size, % of the visible area |
| `max_cards`, `width` | 6, 240 | Desktop widget |

The current board, per-card colours and reminder marks live in
`~/.local/state/noctalia-kanban.json` (plugins cannot write their own settings).
