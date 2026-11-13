--!nonstrict
-- Лаунчер: /kb <текст>
--   • первым — «добавить в первую колонку текущей доски», дальше — в любую
--     другую колонку;
--   • ниже — найденные карточки всех колонок текущей доски (выбор — открыть доску).
-- Без текста — список колонок с числом карточек.

local store = require("./store.luau")
local boardLib = require("./board.luau")

local function currentBoard()
  local p = store.currentPath()
  return store.read(p), p
end

function onQuery(text)
  local board, p = currentBoard()
  if board == nil then
    launcher.setResults(text, { { id = "none", title = "Доска не читается: " .. p, glyph = "alert-triangle" } })
    return
  end
  local name = store.boardName(p)
  local q = noctalia.string.trim(text or "")
  local results = {}

  if q == "" then
    for li, lane in ipairs(board.lanes) do
      table.insert(results, {
        id = "open",
        title = lane.title,
        subtitle = name .. " · карточек: " .. #lane.cards,
        glyph = lane.complete and "checks" or "layout-kanban",
        score = 100 - li,
      })
    end
    table.insert(results, 1, { id = "hint", title = "Напиши текст — добавлю карточку", subtitle = "Срок: @{2026-11-20}, метки: #работа", glyph = "pencil-plus", score = 200 })
    launcher.setResults(text, results)
    return
  end

  for li, lane in ipairs(board.lanes) do
    table.insert(results, {
      id = "add:" .. li .. ":" .. q,
      title = (li == 1 and "Добавить: " or "В «" .. lane.title .. "»: ") .. boardLib.bodyOf(q),
      subtitle = name .. " → " .. lane.title,
      glyph = li == 1 and "pencil-plus" or "arrow-right",
      score = 1000 - li,
    })
  end

  for _, lane in ipairs(board.lanes) do
    for _, card in ipairs(lane.cards) do
      local score = noctalia.fuzzyScore(q, card.text)
      if score ~= nil then
        table.insert(results, {
          id = "open",
          title = boardLib.bodyOf(card.text),
          subtitle = lane.title .. (boardLib.dueOf(card.text) and (" · срок " .. boardLib.dueOf(card.text)) or ""),
          glyph = card.done and "check" or "note",
          score = score,
        })
      end
    end
  end
  launcher.setResults(text, results)
end

function onActivate(id)
  if id == "open" or id == "hint" then
    store.openBoard()
    return
  end
  local li, text = string.match(id, "^add:(%d+):(.*)$")
  if li == nil then
    return
  end
  local ok, err, laneTitle = store.addCard(text, tonumber(li))
  if ok then
    noctalia.notify("Канбан", "«" .. boardLib.bodyOf(text) .. "» → " .. tostring(laneTitle))
  else
    noctalia.notifyError("Канбан", "Не добавилось: " .. tostring(err))
  end
end
