--!nonstrict
-- Виджет панели: сколько карточек «в работе» на текущей доске. Красный —
-- есть просроченные (срок @{…} прошёл или сегодня). Клик — доска,
-- подсказка — разбивка по колонкам. Во время помидора — обратный отсчёт,
-- правый клик его останавливает.

local store = require("./store.luau")
local boardLib = require("./board.luau")

noctalia.setUpdateInterval(30000)

local pomo = store.pomo()
local ticking = false

local lastStamp = nil
local lastPath = nil
local lastDay = nil

local lastRows, lastActive, lastOverdue = {}, 0, 0

-- Помидор идёт — «24:13» и тикаем раз в секунду; иначе число карточек.
function draw()
  local left = pomo and math.max(0, pomo.untilMs - noctalia.nowMs()) or nil
  if left ~= nil and left > 0 then
    local sec = math.floor(left / 1000)
    barWidget.setGlyph("clock")
    barWidget.setText(barWidget.isVertical() and "" or string.format("%d:%02d", sec // 60, sec % 60))
    barWidget.setGlyphColor("primary")
    barWidget.setColor("primary")
    barWidget.setTooltip({ { "Помидор", boardLib.bodyOf(pomo.text or "") }, { "Правый клик", "остановить" } })
    if not ticking then
      ticking = true
      noctalia.setUpdateInterval(1000)
    end
    return
  end
  if ticking then
    ticking = false
    noctalia.setUpdateInterval(30000)
  end
  barWidget.setGlyph("layout-kanban")
  barWidget.setText(barWidget.isVertical() and "" or tostring(lastActive))
  barWidget.setGlyphColor(lastOverdue > 0 and "error" or "on_surface")
  barWidget.setColor(lastOverdue > 0 and "error" or "on_surface")
  barWidget.setTooltip(lastRows)
end

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

  lastRows, lastActive, lastOverdue = rows, active, overdue
  draw()
end

function onClick()
  store.openBoard()
end

function onRightClick()
  if pomo ~= nil then
    store.stopPomo()
  end
end

function update()
  if ticking then
    pomo = store.pomo()
    draw()
  end
  refresh(false)
end

noctalia.state.watch("kanban.pomo", function(value)
  pomo = type(value) == "table" and value or nil
  draw()
end)

-- любая запись из панели/службы/лаунчера
noctalia.state.watch("kanban.rev", function()
  refresh(true)
end)

refresh(true)
