--!nonstrict
-- Виджет рабочего стола: карточки «в работе» текущей доски мини-листками.
-- Добавляется в редакторе виджетов стола (Win+G → Kanban). Клик — доска.

local store = require("./store.luau")
local boardLib = require("./board.luau")

local INK = "#22262F"
local INK_MUTED = "#22262FA6"
-- те же цвета, что на доске: незавершённые колонки по порядку
local PAPERS = { "#FFF0A5", "#FFD3A3", "#B9DDFF", "#DCC6F7", "#FFC2D6", "#FFB3AC", "#DFE2E8" }
local NAMED = {
  yellow = "#FFF0A5", orange = "#FFD3A3", pink = "#FFC2D6", red = "#FFB3AC",
  purple = "#DCC6F7", blue = "#B9DDFF", green = "#C5EDAE", gray = "#DFE2E8",
}

local function laneColor(board, li)
  local n = 0
  for i = 1, li do
    if not board.lanes[i].complete then
      n += 1
    end
  end
  return PAPERS[((math.max(n, 1) - 1) % #PAPERS) + 1]
end
local TAPE = "#FFFFFF59"
local TAPE_EDGE = "#00000021"
local SHADOW = "#0000002E"

local maxCards = math.max(1, math.floor(tonumber(noctalia.getConfig("max_cards")) or 6))
local width = math.max(160, math.floor(tonumber(noctalia.getConfig("width")) or 240))

local fontFamily = nil
do
  local path = noctalia.string.trim(tostring(store.cfg("font_path") or ""))
  if path ~= "" then
    fontFamily = noctalia.loadFont(noctalia.expandPath(path))
  end
end

desktopWidget.setWantsSecondTicks(false)
noctalia.setUpdateInterval(30000)

local lastKey = nil

local function hash(text)
  local h = 5381
  for i = 1, #text do
    h = (h * 33 + string.byte(text, i)) % 2147483647
  end
  return h
end

local function openBoard()
  store.openBoard()
end

local function miniSticker(card, paper)
  local due = boardLib.dueOf(card.text)
  local days = due and boardLib.daysUntil(due)
  local overdue = days ~= nil and days <= 0
  local h = hash(card.text)
  local left = 2 + (h % 7)
  local body = {
    ui.row({ gap = 0, height = 12, align = "center" }, {
      ui.spacer({ flexGrow = left }),
      ui.column({ gap = 0, width = 44, height = 9, align = "stretch" }, {
        ui.box({ height = 1, fill = TAPE_EDGE }),
        ui.box({ flexGrow = 1, fill = overdue and "#E5484D80" or TAPE }),
        ui.box({ height = 1, fill = TAPE_EDGE }),
      }),
      ui.spacer({ flexGrow = 10 - left }),
    }),
    ui.column({ paddingH = 10, paddingV = 2, gap = 2 }, {
      ui.label({ text = boardLib.bodyOf(card.text), fontFamily = fontFamily, fontSize = 15, color = INK, maxLines = 3 }),
      due and ui.label({ text = (overdue and "⚠ " or "") .. due, fontSize = 11, color = overdue and "#C62828" or INK_MUTED }) or nil,
    }),
    ui.box({ height = 6, fill = "#00000000" }),
  }
  return ui.column({ gap = 0 }, {
    ui.column({ gap = 0, radius = 2, fill = paper, align = "stretch" }, body),
    ui.box({ height = 3, fill = SHADOW, softness = 3 }),
  })
end

local function render()
  local p = store.currentPath()
  local board = store.read(p)
  local items = {}
  local title = store.boardName(p)
  local colors = store.colors()
  if board ~= nil then
    local shown = 0
    local total = 0
    for _, li in ipairs(store.activeLanes(board)) do
      local lane = board.lanes[li]
      total += #lane.cards
      for _, card in ipairs(lane.cards) do
        if shown < maxCards then
          shown += 1
          local named = store.colorOf(colors, p, card.text)
          table.insert(items, miniSticker(card, (named and NAMED[named]) or laneColor(board, li)))
        end
      end
    end
    if total == 0 then
      table.insert(items, ui.label({ text = "в работе пусто", fontFamily = fontFamily, fontSize = 16, color = "on_surface_variant" }))
    elseif total > shown then
      table.insert(items, ui.label({ text = "и ещё " .. (total - shown) .. "…", fontFamily = fontFamily, fontSize = 15, color = "on_surface" }))
    end
  end

  desktopWidget.render(ui.column({ gap = 8, width = width, onClick = openBoard }, {
    ui.row({ paddingH = 10, paddingV = 4, radius = 10, fill = "surface/0.6" }, {
      ui.label({ text = title .. " · в работе", fontFamily = fontFamily, fontSize = 20, color = "on_surface", maxLines = 1 }),
    }),
    ui.column({ gap = 8 }, items),
  }))
end

local function refresh(force)
  local p = store.currentPath()
  local st = store.stampOf(p)
  local key = p .. "|" .. tostring(st and st.mtime) .. "|" .. tostring(st and st.size) .. "|" .. boardLib.today()
  if force or key ~= lastKey then
    lastKey = key
    render()
  end
end

function update()
  refresh(false)
end

noctalia.state.watch("kanban.rev", function()
  refresh(true)
end)

refresh(true)
