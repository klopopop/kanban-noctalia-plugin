--!nonstrict
-- Виджет панели: сколько карточек «в работе» на текущей доске. Красный —
-- есть просроченные (срок @{…} прошёл или сегодня). Клик — доска,
-- подсказка — разбивка по колонкам.

local store = require("./store.luau")
local boardLib = require("./board.luau")

noctalia.setUpdateInterval(30000)

local lastStamp = nil
local lastPath = nil
local lastDay = nil

local function refresh(force)
  local p = store.currentPath()
  local stamp = store.stampOf(p)
  local day = boardLib.today()
  if not force and p == lastPath and day == lastDay and store.sameStamp(stamp, lastStamp) then
    return
  end
  lastPath, lastStamp, lastDay = p, stamp, day

  local board = store.read(p)
  if board == nil then
    return
  end

  local active = 0
  for _, li in ipairs(store.activeLanes(board)) do
    active += #board.lanes[li].cards
  end

  local overdue = 0
  local rows = { { store.boardName(p), "" } }
  for _, lane in ipairs(board.lanes) do
    table.insert(rows, { lane.title, tostring(#lane.cards) })
    if not lane.complete then
      for _, card in ipairs(lane.cards) do
        local days = boardLib.daysUntil(boardLib.dueOf(card.text))
        if days ~= nil and days <= 0 then
          overdue += 1
        end
      end
    end
  end
  if overdue > 0 then
    table.insert(rows, { "Срок сегодня / просрочено", tostring(overdue) })
  end

  barWidget.setGlyph("layout-kanban")
  barWidget.setText(barWidget.isVertical() and "" or tostring(active))
  barWidget.setGlyphColor(overdue > 0 and "error" or "on_surface")
  barWidget.setColor(overdue > 0 and "error" or "on_surface")
  barWidget.setTooltip(rows)
end

function onClick()
  noctalia.togglePanel("pvs/kanban:panel")
end

function update()
  refresh(false)
end

-- любая запись из панели/службы/лаунчера
noctalia.state.watch("kanban.rev", function()
  refresh(true)
end)

refresh(true)
