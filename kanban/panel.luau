--!nonstrict
-- Канбан-доска в панели Noctalia. Карточки нарисованы как стикеры Noctes
-- (бумага, полоска скотча, рукописный шрифт), данные — markdown Obsidian Kanban.
--
--   клик по карточке      — правка: Enter сохранить, Shift+Enter новая строка
--   перетаскивание        — в другую колонку или между карточками
--   «+» у колонки         — новая карточка
--
-- Файл может параллельно править Obsidian: перед каждой правкой и раз в
-- секунду, пока панель открыта, сверяем mtime/размер и перечитываем.

local boardLib = require("./board.luau")

local INK = "#22262F"
local TAPE = "#FFFFFF59"
local TAPE_EDGE = "#00000021"
local PAPER_DONE = "#C5EDAE"
local PAPERS = { "#FFF0A5", "#FFD3A3", "#B9DDFF", "#DCC6F7", "#FFC2D6", "#FFB3AC", "#DFE2E8" }

local CARD_FONT = 18
local LANE_FONT = 26

local fontFamily = nil
local fontFile = "DejaVu-Sans"
do
  local path = noctalia.string.trim(noctalia.getConfig("font_path") or "")
  if path ~= "" then
    fontFile = noctalia.expandPath(path)
  end
  if path ~= "" then
    local family, err = noctalia.loadFont(noctalia.expandPath(path))
    if family ~= nil then
      fontFamily = family
    else
      noctalia.log("kanban: шрифт не загрузился: " .. tostring(err))
    end
  end
end

-- ── Состояние ───────────────────────────────────────────────────────────────

local board = nil
local path = ""
local stamp = nil -- { mtime, size } файла на момент последнего чтения/записи

local editingId = nil
local editText = ""
local editSeq = 0

local addingLane = nil
local addText = ""
local addSeq = 0
local lastAdd = { text = "", lane = 0, at = 0 }

-- «Очистить готово»: первое нажатие взводит, второе в течение 4 с — чистит
local clearArmed = nil -- { lane, at }

-- Правка колонки (клик по заголовку)
local laneEdit = nil
local laneEditText = ""
local laneSeq = 0
local laneDeleteArmed = nil -- { lane, at }

-- Переименование доски (= файла)
local boardEdit = false
local boardEditText = ""
local boardSeq = 0
local boardDeleteArmed = nil -- время первого нажатия «удалить доску»

-- Все доски: { path, name }, из папки boards_dir (+ текущая, если она вне её)
local boards = {}

local store = require("./store.luau")
local resolvePath = store.currentPath
local rememberPath = store.rememberPath

-- Цвета карточек, выбранные вручную (в файле состояния, по доске и тексту)
local colors = {}
local NAMED = {
  yellow = "#FFF0A5", orange = "#FFD3A3", pink = "#FFC2D6", red = "#FFB3AC",
  purple = "#DCC6F7", blue = "#B9DDFF", green = "#C5EDAE", gray = "#DFE2E8",
}
local NAMED_ORDER = { "yellow", "orange", "pink", "red", "purple", "blue", "green", "gray" }

-- Фильтр по метке (#тег), nil — все карточки
local tagFilter = nil

local render -- вперёд

-- ── Файл ────────────────────────────────────────────────────────────────────

local function stampOf()
  local info = noctalia.fileInfo(path)
  if info == nil then
    return nil
  end
  return { mtime = info.mtime, size = info.size }
end

local function sameStamp(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a.mtime == b.mtime and a.size == b.size
end

local function save()
  local ok, err = noctalia.writeFile(path, boardLib.serialize(board))
  if not ok then
    noctalia.notifyError("Канбан", "Не удалось сохранить " .. path .. ": " .. tostring(err))
    return
  end
  stamp = stampOf()
  store.bump()
end

local function load()
  path = resolvePath()
  if not noctalia.fileExists(path) then
    board = boardLib.default()
    save()
    return
  end
  local raw, err = noctalia.readFile(path)
  if raw == nil then
    noctalia.notifyError("Канбан", "Не удалось прочитать " .. path .. ": " .. tostring(err))
    board = board or boardLib.default()
    return
  end
  board = boardLib.parse(raw)
  stamp = stampOf()
  colors = store.colors()
end

-- Файл поменяли снаружи (Obsidian, git) — перечитать. true, если перечитали.
local function reloadIfChanged()
  if path == "" or board == nil then
    load()
    return true
  end
  if sameStamp(stampOf(), stamp) then
    return false
  end
  load()
  editingId, addingLane, laneEdit = nil, nil, nil
  return true
end

-- Перед правкой: если файл изменился, правку не применяем — id карточек уже
-- другие, а пользователь видел старую доску.
local function guard()
  if reloadIfChanged() then
    noctalia.notify("Канбан", "Доска изменилась в другом месте — показываю свежую версию")
    render()
    return false
  end
  return true
end

-- ── Модель ──────────────────────────────────────────────────────────────────

local function findCard(id)
  for li, lane in ipairs(board.lanes) do
    for ci, card in ipairs(lane.cards) do
      if card.id == id then
        return li, ci, card
      end
    end
  end
  return nil
end

local function laneColor(li)
  local lane = board.lanes[li]
  if lane ~= nil and lane.complete then
    return PAPER_DONE
  end
  -- незавершённые колонки по порядку, зелёный — только «готово»
  local n = 0
  for i = 1, li do
    if not board.lanes[i].complete then
      n += 1
    end
  end
  return PAPERS[((n - 1) % #PAPERS) + 1]
end

local function cardPaper(card, li)
  local named = store.colorOf(colors, path, card.text)
  return (named and NAMED[named]) or laneColor(li)
end

local function moveCard(id, toLane, pos)
  local li, ci, card = findCard(id)
  if card == nil or board.lanes[toLane] == nil then
    return
  end
  table.remove(board.lanes[li].cards, ci)
  local cards = board.lanes[toLane].cards
  if li == toLane and ci < pos then
    pos -= 1
  end
  pos = math.max(1, math.min(pos, #cards + 1))
  table.insert(cards, pos, card)
  if board.lanes[toLane].complete then
    card.done = true
  elseif board.lanes[li].complete then
    card.done = false
  end
end

-- ── Действия ────────────────────────────────────────────────────────────────

local function onDrop(payload, value)
  if not guard() then
    return
  end
  editingId = nil
  if value == "trash" then
    local tli, tci = findCard(payload)
    if tli ~= nil then
      table.remove(board.lanes[tli].cards, tci)
    end
    render()
    save()
    return
  end
  local li = tonumber(string.match(value, "^lane:(%d+)$"))
  local pos
  if li ~= nil then
    pos = #board.lanes[li].cards + 1
  else
    local a, b = string.match(value, "^at:(%d+):(%d+)$")
    li, pos = tonumber(a), tonumber(b)
  end
  if li == nil then
    return
  end
  moveCard(payload, li, pos)
  render()
  save()
end

local function startEdit(card)
  if not guard() then
    return
  end
  addingLane = nil
  editingId = card.id
  editText = card.text
  editSeq += 1
  render()
end

local function cancelEdit()
  editingId = nil
  render()
end

local function commitEdit(value)
  local text = noctalia.string.trim(value or editText)
  local id = editingId
  editingId = nil
  if id == nil or not guard() then
    return
  end
  local li, ci, card = findCard(id)
  if card ~= nil then
    if text == "" then
      table.remove(board.lanes[li].cards, ci)
    else
      local named = store.colorOf(colors, path, card.text)
      if named ~= nil and text ~= card.text then
        store.setColor(path, text, named, card.text)
        colors = store.colors()
      end
      card.text = text
    end
  end
  render()
  save()
end

local function deleteCard(id)
  editingId = nil
  if not guard() then
    return
  end
  local li, ci = findCard(id)
  if li ~= nil then
    table.remove(board.lanes[li].cards, ci)
  end
  render()
  save()
end

local function shiftCard(id, delta)
  if not guard() then
    return
  end
  local li = findCard(id)
  if li == nil then
    return
  end
  local to = li + delta
  if to < 1 or to > #board.lanes then
    return
  end
  -- текст из поля правки не терять
  local _, _, card = findCard(id)
  local text = noctalia.string.trim(editText)
  if card ~= nil and text ~= "" then
    card.text = text
  end
  moveCard(id, to, #board.lanes[to].cards + 1)
  editingId = nil
  render()
  save()
end

-- Копия карточки стикером на рабочий стол (плагин Noctes).
local function toDesktop(id)
  local _, _, card = findCard(id)
  if card == nil then
    return
  end
  local text = noctalia.string.trim(editText ~= "" and editText or card.text)
  noctalia.runAsync({ "noctalia", "msg", "plugin", "remo/noctes:service", "all", "new", text })
  noctalia.notify("Канбан", "Стикер на рабочем столе")
end

local function startAdd(li)
  if not guard() then
    return
  end
  editingId = nil
  addingLane = li
  addText = ""
  addSeq += 1
  render()
end

local function commitAdd(value)
  local text = noctalia.string.trim(value or addText)
  local li = addingLane
  if li == nil or text == "" then
    addingLane = nil
    render()
    return
  end
  -- один Enter не должен добавить карточку дважды
  local now = noctalia.nowMs()
  if text == lastAdd.text and li == lastAdd.lane and now - lastAdd.at < 1500 then
    return
  end
  if not guard() then
    return
  end
  lastAdd = { text = text, lane = li, at = now }
  table.insert(board.lanes[li].cards, boardLib.newCard(text, board.lanes[li].complete))
  -- поле остаётся открытым: можно накидать несколько карточек подряд
  addText = ""
  addSeq += 1
  render()
  save()
end

-- ── Колонки ──

local function startLaneEdit(li)
  if not guard() then
    return
  end
  editingId, addingLane = nil, nil
  laneEdit = li
  laneEditText = board.lanes[li].title
  laneSeq += 1
  laneDeleteArmed = nil
  render()
end

local function cleanTitle(text)
  local t = noctalia.string.trim(string.gsub(text or "", "[\r\n]+", " "))
  t = string.gsub(t, "^#+%s*", "")
  return t
end

local function commitLaneEdit(value)
  local li = laneEdit
  laneEdit = nil
  if li == nil or not guard() then
    return
  end
  local title = cleanTitle(value or laneEditText)
  if title ~= "" and board.lanes[li] ~= nil then
    board.lanes[li].title = title
    render()
    save()
    return
  end
  render()
end

local function addLane()
  if not guard() then
    return
  end
  editingId, addingLane = nil, nil
  -- новая колонка — перед «готово», если она последняя
  local at = #board.lanes + 1
  if #board.lanes > 0 and board.lanes[#board.lanes].complete then
    at = #board.lanes
  end
  table.insert(board.lanes, at, { title = "Новая колонка", complete = false, cards = {} })
  laneEdit = at
  laneEditText = "Новая колонка"
  laneSeq += 1
  render()
  save()
end

local function moveLane(li, delta)
  local to = li + delta
  if not guard() or to < 1 or to > #board.lanes then
    return
  end
  local title = cleanTitle(laneEditText)
  if title ~= "" then
    board.lanes[li].title = title
  end
  board.lanes[li], board.lanes[to] = board.lanes[to], board.lanes[li]
  laneEdit = to
  laneEditText = board.lanes[to].title
  laneSeq += 1
  render()
  save()
end

local function toggleComplete(li)
  if not guard() then
    return
  end
  local lane = board.lanes[li]
  lane.complete = not lane.complete
  for _, card in ipairs(lane.cards) do
    card.done = lane.complete
  end
  render()
  save()
end

local function deleteLane(li)
  if not guard() or #board.lanes <= 1 then
    return
  end
  local now = noctalia.nowMs()
  local armed = laneDeleteArmed ~= nil and laneDeleteArmed.lane == li and now - laneDeleteArmed.at <= 4000
  if #board.lanes[li].cards > 0 and not armed then
    laneDeleteArmed = { lane = li, at = now }
    render()
    return
  end
  laneDeleteArmed = nil
  laneEdit = nil
  table.remove(board.lanes, li)
  render()
  save()
end

-- ── Доска ──

local startBoardEdit -- ниже
local scanBoards

local function boardName(p)
  return string.match(p, "([^/]+)%.md$") or p
end

local function boardsDir()
  return noctalia.expandPath(noctalia.string.trim(noctalia.getConfig("boards_dir") or ""))
end

-- Найти доски: .md с frontmatter Kanban. Асинхронно, потом перерисовка.
scanBoards = function()
  local script = 'mkdir -p "$1"; find "$1" -type f -name "*.md" -exec grep -l -m1 -e "^kanban-plugin: board" {} + 2>/dev/null; true'
  noctalia.runAsync({ "sh", "-c", script, "_", boardsDir() }, function(result)
    local list, seen = {}, {}
    for line in string.gmatch(result.stdout or "", "[^\n]+") do
      if not seen[line] then
        seen[line] = true
        table.insert(list, { path = line, name = boardName(line) })
      end
    end
    if path ~= "" and not seen[path] then
      table.insert(list, { path = path, name = boardName(path) })
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    boards = list
    render()
  end)
end

local function switchBoard(p)
  if p == path then
    startBoardEdit()
    return
  end
  editingId, addingLane, laneEdit, boardEdit = nil, nil, nil, false
  boardDeleteArmed = nil
  rememberPath(p)
  tagFilter = nil
  load()
  render()
end

local function newBoard()
  local dir = boardsDir()
  local name = "Новая доска"
  local n = 1
  while noctalia.fileExists(dir .. "/" .. name .. ".md") do
    n += 1
    name = "Новая доска " .. n
  end
  local target = dir .. "/" .. name .. ".md"
  local ok, err = noctalia.writeFile(target, boardLib.serialize(boardLib.default()))
  if not ok then
    noctalia.notifyError("Канбан", "Не удалось создать доску: " .. tostring(err))
    return
  end
  rememberPath(target)
  load()
  scanBoards()
  startBoardEdit()
end

-- В корзину системы (gio trash) — доску можно достать обратно.
local function deleteBoard()
  local now = noctalia.nowMs()
  if boardDeleteArmed == nil or now - boardDeleteArmed > 4000 then
    boardDeleteArmed = now
    render()
    return
  end
  boardDeleteArmed = nil
  boardEdit = false
  local victim = path
  noctalia.runAsync({ "gio", "trash", "--", victim }, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError("Канбан", "Не удалось удалить доску: " .. tostring(result.stderr))
      render()
      return
    end
    local next = nil
    for _, b in ipairs(boards) do
      if b.path ~= victim then
        next = b.path
        break
      end
    end
    if next == nil then
      next = boardsDir() .. "/Канбан.md"
      noctalia.writeFile(next, boardLib.serialize(boardLib.default()))
    end
    noctalia.notify("Канбан", "Доска «" .. boardName(victim) .. "» в корзине")
    rememberPath(next)
    load()
    scanBoards()
  end)
end

startBoardEdit = function()
  editingId, addingLane, laneEdit = nil, nil, nil
  boardEdit = true
  boardEditText = string.match(path, "([^/]+)%.md$") or ""
  boardSeq += 1
  render()
end

local function commitBoardEdit(value)
  boardEdit = false
  local name = noctalia.string.trim((string.gsub(value or boardEditText, "[\r\n/\\:*?\"<>|#%^%[%]]", "")))
  name = string.gsub(name, "^%.+", "")
  local dir = string.match(path, "^(.*)/[^/]+$") or "."
  local target = dir .. "/" .. name .. ".md"
  if name == "" or target == path then
    render()
    return
  end
  if noctalia.fileExists(target) then
    noctalia.notifyError("Канбан", "Файл «" .. name .. ".md» уже есть в этой папке")
    render()
    return
  end
  local old = path
  noctalia.runAsync({ "mv", "-n", "--", old, target }, function(result)
    if result.exitCode == 0 and noctalia.fileExists(target) and not noctalia.fileExists(old) then
      path = target
      stamp = stampOf()
      rememberPath(target)
      scanBoards()
    else
      noctalia.notifyError("Канбан", "Не удалось переименовать: " .. tostring(result.stderr))
    end
    render()
  end)
end

local function openInObsidian()
  local uri = "obsidian://open?path=" .. noctalia.string.urlEncode(path)
  noctalia.runAsync({ "xdg-open", uri })
  panel.close()
end

-- ── Отрисовка ───────────────────────────────────────────────────────────────

-- Листок как у Noctes: почти квадратный, с тенью справа и снизу.
local STICKER_W = 176
local STICKER_H = 172
-- Ширина доски внутри панели (лог. px) — от неё считаем, сколько листков
-- влезает в ряд и не пора ли их уменьшить (при 6+ колонках).
local BOARD_W = 1210
local LANE_GAP = 14
local cellW, cellH, perRow = STICKER_W, STICKER_H, 2
local laneInner = 360

local function layoutFor(n)
  local inner = (BOARD_W - (n - 1) * LANE_GAP) / n - 24 - 8
  laneInner = inner
  perRow = math.max(1, math.floor((inner + 6) / (STICKER_W + 6)))
  cellW = math.min(STICKER_W, math.floor((inner - (perRow - 1) * 6) / perRow))
  cellH = math.floor(cellW * STICKER_H / STICKER_W)
end
local SHADOW_W = 5
local SHADOW = "#00000059"
local TAPE_SPOTS = { "none", "left", "center", "right", "center" }
local LINE_HEIGHT = 1.4

local function hash(text)
  local h = 5381
  for i = 1, #text do
    h = (h * 33 + string.byte(text, i)) % 2147483647
  end
  return h
end

local function jitter(seed, salt, spread)
  return (hash(salt .. "|" .. seed) % (spread * 2 + 1)) - spread
end

-- Оттенок бумаги чуть гуляет, чтобы два соседних листка не выглядели печатными.
local function shiftColor(hex, delta)
  local function ch(i)
    local v = tonumber(string.sub(hex, i, i + 1), 16) + delta
    return math.max(0, math.min(255, v))
  end
  return string.format("#%02X%02X%02X", ch(2), ch(4), ch(6))
end

-- Полоска матового скотча: слева, по центру, справа или её нет.
local function tapeRow(seed)
  local spot = TAPE_SPOTS[(hash("tape|" .. seed) % #TAPE_SPOTS) + 1]
  if spot == "none" then
    return nil
  end
  local width = 52 + jitter(seed, "tapew", 8)
  local inset = 12 + jitter(seed, "tapex", 6)
  local strip = ui.column({ gap = 0, width = width, height = 12, align = "stretch" }, {
    ui.box({ height = 1, fill = TAPE_EDGE }),
    ui.box({ flexGrow = 1, fill = TAPE }),
    ui.box({ height = 1, fill = TAPE_EDGE }),
  })
  local cells
  if spot == "left" then
    cells = { ui.box({ width = inset, height = 1, fill = "#00000000" }), strip, ui.spacer({ flexGrow = 1 }) }
  elseif spot == "right" then
    cells = { ui.spacer({ flexGrow = 1 }), strip, ui.box({ width = inset, height = 1, fill = "#00000000" }) }
  else
    cells = { ui.spacer({ flexGrow = 1 }), strip, ui.spacer({ flexGrow = 1 }) }
  end
  return ui.row({ gap = 0, height = 18, align = "center" }, cells)
end

local function iconButton(glyph, tooltip, onClick, variant)
  return ui.button({
    glyph = glyph,
    tooltip = tooltip,
    variant = variant or "ghost",
    controlSize = "sm",
    onClick = onClick,
  })
end

-- Поставить срок в тексте правки (поле ввода пересоздаётся с новым текстом).
local function setEditDue(date)
  editText = boardLib.withDue(editText, date)
  editSeq += 1
  render()
end

local function setCardColor(card, name)
  store.setColor(path, card.text, name)
  colors = store.colors()
  render()
end

local function dueChip(label, date)
  return ui.button({ text = label, variant = "ghost", controlSize = "sm", onClick = function() setEditDue(date) end })
end

local function colorChips(card)
  local current = store.colorOf(colors, path, card.text)
  local chips = {
    ui.button({
      glyph = "color-swatch-off", controlSize = "sm",
      variant = current == nil and "primary" or "ghost",
      tooltip = "Цвет колонки",
      onClick = function() setCardColor(card, nil) end,
    }),
  }
  for _, name in ipairs(NAMED_ORDER) do
    table.insert(chips, ui.box({
      key = "chip-" .. name,
      width = 20, height = 20, radius = 10,
      fill = NAMED[name],
      border = current == name and "on_surface" or "#00000033",
      borderWidth = current == name and 2 or 1,
      onClick = function() setCardColor(card, name) end,
    }))
  end
  return ui.row({ gap = 6, align = "center" }, chips)
end

local function editorView(card, li)
  local id = card.id
  local due = boardLib.dueOf(editText)
  return ui.column({ key = "card-" .. id, fill = cardPaper(card, li), radius = 4, paddingH = 10, paddingV = 10, gap = 8 }, {
    ui.input({
      key = "edit-" .. editSeq,
      value = editText,
      multiline = true,
      submitOnEnter = true,
      focus = true,
      height = 120,
      fontSize = 16,
      onChange = function(v) editText = v end,
      onSubmit = function(v) commitEdit(v) end,
    }),
    ui.row({ gap = 2, align = "center" }, {
      ui.glyph({ name = "calendar", size = 14, color = INK }),
      ui.label({ text = due and ("срок " .. due) or "срок:", fontSize = 12, color = INK }),
      dueChip("сегодня", boardLib.today(0)),
      dueChip("завтра", boardLib.today(1)),
      dueChip("+неделя", boardLib.today(7)),
      due and iconButton("calendar-off", "Убрать срок", function() setEditDue(nil) end) or nil,
    }),
    colorChips(card),
    ui.row({ gap = 2, align = "center" }, {
      iconButton("arrow-left", "В колонку левее", function() shiftCard(id, -1) end),
      iconButton("arrow-right", "В колонку правее", function() shiftCard(id, 1) end),
      iconButton("note", "Копию стикером на рабочий стол", function() toDesktop(id) end),
      iconButton("trash", "Удалить карточку", function() deleteCard(id) end),
      ui.spacer({ flexGrow = 1 }),
      iconButton("x", "Отмена", cancelEdit),
      iconButton("check", "Сохранить (Enter)", function() commitEdit(nil) end, "primary"),
    }),
  })
end

-- Сам листок: бумага + тень, текст обрезается по высоте листка.
local function stickerView(card, li)
  local seed = card.text
  local sheetW, sheetH = cellW - SHADOW_W, cellH - SHADOW_W
  local paper = shiftColor(cardPaper(card, li), jitter(seed, "paper", 6))
  local tape = tapeRow(seed)

  local body = {}
  if tape ~= nil then
    table.insert(body, tape)
  end
  local padTop = tape ~= nil and 2 or 12
  local lines = math.max(1, math.floor((sheetH - padTop - 12 - (tape ~= nil and 18 or 0)) / (CARD_FONT * LINE_HEIGHT)))
  table.insert(body, ui.column({ paddingH = 12, paddingV = padTop, flexGrow = 1, gap = 0 }, {
    ui.label({ text = boardLib.bodyOf(card.text), fontFamily = fontFamily, fontSize = CARD_FONT, color = INK, maxLines = lines }),
  }))

  local sheet = ui.column({
    width = sheetW, height = sheetH, gap = 0, radius = 2, fill = paper, align = "stretch",
    opacity = card.done and 0.85 or 1,
  }, body)

  return ui.column({ gap = 0, width = cellW, height = cellH }, {
    ui.row({ gap = 0, height = sheetH }, {
      sheet,
      ui.column({ gap = 0, width = SHADOW_W, height = sheetH }, {
        ui.spacer({ width = SHADOW_W, height = SHADOW_W }),
        ui.box({ width = SHADOW_W, height = sheetH - SHADOW_W, fill = SHADOW, softness = SHADOW_W }),
      }),
    }),
    ui.row({ gap = 0, height = SHADOW_W }, {
      ui.spacer({ width = SHADOW_W, height = SHADOW_W }),
      ui.box({ width = cellW - SHADOW_W, height = SHADOW_W, fill = SHADOW, softness = SHADOW_W }),
    }),
  })
end

-- Листок картинкой: поворот, скотч за краем и тень рисует tools/sticker.sh
-- (ImageMagick). Картинка в кеше по ключу из текста и параметров; пока она
-- рисуется — плоский листок.
local CACHE = noctalia.expandPath("~/.cache/noctalia-kanban")
local RENDER_SCALE = 2 -- с запасом под масштаб 1.5–1.6
local TOOL = (noctalia.pluginDir() or noctalia.expandPath("~/.local/share/noctalia/plugins/kanban")) .. "/tools/sticker.sh"
local pending = {}
local failed = {}

-- Подпись листка: срок и метки; просроченное — красным (и скотч красный).
local function cardFooter(card)
  local parts = {}
  local due = boardLib.dueOf(card.text)
  local days = due and boardLib.daysUntil(due)
  local late = days ~= nil and days <= 0 and not card.done
  if due ~= nil then
    local d, m = string.match(due, "^%d+%-(%d+)%-(%d+)$")
    local short = m .. "." .. d
    if card.done then
      table.insert(parts, "до " .. short)
    elseif days == 0 then
      table.insert(parts, "сегодня!")
    elseif days == 1 then
      table.insert(parts, "завтра")
    elseif days < 0 then
      table.insert(parts, "было до " .. short)
    else
      table.insert(parts, "до " .. short)
    end
  end
  for _, tag in ipairs(boardLib.tagsOf(card.text)) do
    table.insert(parts, "#" .. tag)
  end
  local footer = table.concat(parts, " · ")
  if late then
    return footer, "#E5484DB8", "#C62828"
  end
  return footer, "#F2EEE3CC", "#22262F99"
end

local function imageSticker(card, li, sign)
  local seed = card.text
  local paper = shiftColor(cardPaper(card, li), jitter(seed, "paper", 6))
  local footer, tapeColor, footColor = cardFooter(card)
  -- сторону задаёт место в сетке (шахматка), величину 0.8–3.8° — текст
  local angle = string.format("%.1f", sign * (8 + hash("angle|" .. seed .. "|tilt") % 31) / 10)
  local tapeAngle = tostring(jitter(seed, "tapea", 6))
  local tapeShift = tostring(jitter(seed, "tapex", 22))
  local tape = (hash("tape|" .. seed) % 5 ~= 0) and "1" or "0"
  local key = tostring(hash(table.concat({ seed, paper, angle, tapeAngle, tapeShift, tape, fontFile, RENDER_SCALE, footer, tapeColor, footColor, "v4" }, "|")))
  local file = CACHE .. "/" .. key .. ".png"

  if noctalia.fileExists(file) then
    return ui.image({ path = file, width = cellW, height = cellH, fit = "contain", opacity = card.done and 0.85 or 1 })
  end
  if not pending[key] and not failed[key] then
    pending[key] = true
    noctalia.runAsync({ TOOL, file, boardLib.bodyOf(seed), paper, angle, tapeAngle, tapeShift, tape, fontFile, tostring(RENDER_SCALE), footer, tapeColor, footColor }, function(result)
      pending[key] = nil
      if result.exitCode ~= 0 then
        failed[key] = true
        noctalia.log("kanban: sticker.sh: " .. tostring(result.stderr))
      end
      render()
    end)
  end
  return stickerView(card, li)
end

-- Листок можно тащить; бросок на листок — встать перед ним.
local function cardView(card, li, ci, sign)
  return ui.dropZone({
    key = "at-" .. card.id,
    accepts = { "card" },
    value = "at:" .. li .. ":" .. ci,
    onDrop = onDrop,
    width = cellW,
    height = cellH,
  }, {
    ui.dragSource({
      key = "drag-" .. card.id,
      dragType = "card",
      payload = card.id,
      grabCursor = false,
      onClick = function() startEdit(card) end,
    }, { imageSticker(card, li, sign) }),
  })
end

-- Листки по два в ряд, с небольшим разбросом по высоте, как налеплены руками.
local function cardGrid(lane, li)
  local rows = {}
  local cells = {}
  local function flush()
    if #cells > 0 then
      table.insert(rows, ui.row({ gap = 6, align = "start" }, cells))
      cells = {}
    end
  end
  for ci, card in ipairs(lane.cards) do
    local hidden = false
    if tagFilter ~= nil and card.id ~= editingId then
      hidden = true
      for _, tag in ipairs(boardLib.tagsOf(card.text)) do
        if tag == tagFilter then
          hidden = false
        end
      end
    end
    if hidden then
      -- пропускаем
    elseif card.id == editingId then
      flush()
      table.insert(rows, editorView(card, li))
    else
      -- шахматка: наклон в разные стороны, а листок с наклоном вправо ещё и
      -- ниже соседа; сверху — свой случайный сдвиг от текста
      local sign = ((ci + (ci - 1) // 2) % 2 == 0) and 1 or -1
      local drop = (sign > 0 and 12 or 1) + hash(card.text .. "|drop") % 11
      table.insert(cells, ui.column({ gap = 0 }, { ui.box({ height = drop, fill = "#00000000" }), cardView(card, li, ci, sign) }))
      if #cells == perRow then
        flush()
      end
    end
  end
  flush()
  return rows
end

local function addView(li)
  if addingLane ~= li then
    return ui.button({
      key = "add-btn-" .. li,
      text = "Добавить карточку",
      glyph = "plus",
      variant = "ghost",
      contentAlign = "start",
      controlSize = "sm",
      onClick = function() startAdd(li) end,
    })
  end
  return ui.column({ key = "add-" .. li, fill = laneColor(li), radius = 4, paddingH = 10, paddingV = 10, gap = 8 }, {
    ui.input({
      key = "add-input-" .. addSeq,
      placeholder = "Что сделать? Enter — добавить, Shift+Enter — новая строка",
      multiline = true,
      submitOnEnter = true,
      focus = true,
      height = 80,
      fontSize = 16,
      onChange = function(v) addText = v end,
      onSubmit = function(v) commitAdd(v) end,
    }),
    ui.row({ gap = 4, align = "center" }, {
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = "Готово", variant = "ghost", controlSize = "sm", onClick = function() addingLane = nil; render() end }),
      ui.button({ text = "Добавить", variant = "primary", controlSize = "sm", onClick = function() commitAdd(nil) end }),
    }),
  })
end

local function clearDone(li)
  local now = noctalia.nowMs()
  if clearArmed == nil or clearArmed.lane ~= li or now - clearArmed.at > 4000 then
    clearArmed = { lane = li, at = now }
    render()
    return
  end
  clearArmed = nil
  if not guard() then
    return
  end
  -- не удаляем, а в архив (раздел «Archive» Obsidian Kanban)
  board.archive = board.archive or {}
  for _, card in ipairs(board.lanes[li].cards) do
    card.done = true
    table.insert(board.archive, card)
  end
  board.lanes[li].cards = {}
  noctalia.notify("Канбан", "Карточки в архиве — в Obsidian: меню доски → Archive")
  render()
  save()
end

local function clearButton(lane, li)
  if not lane.complete or #lane.cards == 0 then
    return ui.box({ width = 1, height = 1, fill = "#00000000" })
  end
  local armed = clearArmed ~= nil and clearArmed.lane == li and noctalia.nowMs() - clearArmed.at <= 4000
  if armed then
    return ui.button({ key = "clear-" .. li, text = "В архив " .. #lane.cards .. "?", glyph = "archive", variant = "primary", controlSize = "sm", onClick = function() clearDone(li) end })
  end
  local archived = board.archive and #board.archive or 0
  return iconButton("archive", "Убрать все в архив (два нажатия)" .. (archived > 0 and (". В архиве: " .. archived) or ""), function() clearDone(li) end)
end

local function laneHeader(lane, li)
  if laneEdit ~= li then
    return ui.row({ gap = 8, align = "center" }, {
      ui.row({
        gap = 8, align = "center", flexGrow = 1,
        tooltip = "Изменить колонку",
        onClick = function() startLaneEdit(li) end,
      }, {
        ui.label({ text = lane.title, fontFamily = fontFamily, fontSize = LANE_FONT, color = "on_surface", maxLines = 1,
          maxWidth = math.max(60, laneInner - (lane.complete and #lane.cards > 0 and 110 or 80)) }),
        ui.label({ text = tostring(#lane.cards), fontSize = 14, color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
      }),
      clearButton(lane, li),
      iconButton("plus", "Новая карточка", function() startAdd(li) end),
    })
  end

  local now = noctalia.nowMs()
  local delArmed = laneDeleteArmed ~= nil and laneDeleteArmed.lane == li and now - laneDeleteArmed.at <= 4000
  return ui.column({ gap = 6 }, {
    ui.input({
      key = "lane-title-" .. laneSeq,
      value = lane.title,
      focus = true,
      controlSize = "sm",
      fontSize = 16,
      onChange = function(v) laneEditText = v end,
      onSubmit = function(v) commitLaneEdit(v) end,
    }),
    ui.row({ gap = 2, align = "center" }, {
      iconButton("arrow-left", "Сдвинуть колонку левее", function() moveLane(li, -1) end),
      iconButton("arrow-right", "Сдвинуть колонку правее", function() moveLane(li, 1) end),
      ui.button({
        glyph = "checks",
        tooltip = lane.complete and "Колонка «готово»: карточки отмечены [x]. Нажми, чтобы снять"
          or "Сделать колонкой «готово» (карточки отмечаются [x])",
        variant = lane.complete and "primary" or "ghost",
        controlSize = "sm",
        onClick = function() toggleComplete(li) end,
      }),
      delArmed
        and ui.button({ text = "Удалить с " .. #lane.cards .. "?", glyph = "trash", variant = "destructive", controlSize = "sm", onClick = function() deleteLane(li) end })
        or iconButton("trash", #board.lanes <= 1 and "Последнюю колонку не удалить" or "Удалить колонку", function() deleteLane(li) end),
      ui.spacer({ flexGrow = 1 }),
      iconButton("x", "Отмена", function() laneEdit = nil; render() end),
      iconButton("check", "Сохранить (Enter)", function() commitLaneEdit(nil) end, "primary"),
    }),
  })
end

local function laneView(lane, li)
  local items = cardGrid(lane, li)
  table.insert(items, addView(li))

  return ui.dropZone({
    key = "lane-" .. li,
    accepts = { "card" },
    value = "lane:" .. li,
    onDrop = onDrop,
    direction = "column",
    flexGrow = 1,
    fill = "surface_container/0.6",
    radius = 14,
    padding = 12,
    gap = 6,
  }, {
    laneHeader(lane, li),
    ui.box({ height = 4, radius = 2, fill = laneColor(li) }),
    ui.scroll({ flexGrow = 1, gap = 0, paddingH = 4 }, items),
  })
end

-- Вкладки досок; открытая — primary, клик по ней — переименование/удаление.
local function boardTabs()
  local cells = {}
  for _, b in ipairs(boards) do
    if b.path == path and boardEdit then
      local armed = boardDeleteArmed ~= nil and noctalia.nowMs() - boardDeleteArmed <= 4000
      table.insert(cells, ui.input({
        key = "board-title-" .. boardSeq,
        value = b.name,
        focus = true,
        width = 240,
        controlSize = "sm",
        fontSize = 15,
        onChange = function(v) boardEditText = v end,
        onSubmit = function(v) commitBoardEdit(v) end,
      }))
      table.insert(cells, armed
        and ui.button({ text = "В корзину?", glyph = "trash", variant = "destructive", controlSize = "sm", onClick = deleteBoard })
        or iconButton("trash", "Удалить доску (в корзину системы, два нажатия)", deleteBoard))
      table.insert(cells, iconButton("x", "Отмена", function() boardEdit = false; boardDeleteArmed = nil; render() end))
      table.insert(cells, iconButton("check", "Переименовать (Enter)", function() commitBoardEdit(nil) end, "primary"))
    else
      -- вкладка рукописным шрифтом: открытая — крупно, с полоской бумаги снизу
      local current = b.path == path
      table.insert(cells, ui.column({
        key = "tab-" .. b.path,
        gap = 2,
        paddingH = 8,
        align = "stretch",
        tooltip = current and "Переименовать или удалить доску" or "Открыть доску",
        onClick = function() switchBoard(b.path) end,
      }, {
        ui.label({
          text = b.name,
          fontFamily = fontFamily,
          fontSize = current and 30 or 21,
          color = current and "on_surface" or "on_surface_variant",
          maxLines = 1,
        }),
        ui.box({ height = 3, radius = 2, fill = current and PAPERS[1] or "#00000000" }),
      }))
    end
  end
  table.insert(cells, iconButton("plus", "Новая доска", newBoard))
  return ui.row({ gap = 6, align = "center" }, cells)
end

-- Метки всех карточек доски — фильтр; нет меток — пустая строка нулевой высоты.
local function tagBar()
  local counts, order = {}, {}
  for _, lane in ipairs(board.lanes) do
    for _, card in ipairs(lane.cards) do
      for _, tag in ipairs(boardLib.tagsOf(card.text)) do
        if counts[tag] == nil then
          counts[tag] = 0
          table.insert(order, tag)
        end
        counts[tag] += 1
      end
    end
  end
  if #order == 0 then
    tagFilter = nil
    return ui.box({ height = 1, fill = "#00000000" })
  end
  table.sort(order)
  local chips = {
    ui.glyph({ name = "tag", size = 16, color = "on_surface_variant" }),
    ui.button({ text = "все", variant = tagFilter == nil and "primary" or "ghost", controlSize = "sm", onClick = function() tagFilter = nil; render() end }),
  }
  for _, tag in ipairs(order) do
    table.insert(chips, ui.button({
      key = "tag-" .. tag,
      text = "#" .. tag .. " " .. counts[tag],
      variant = tagFilter == tag and "primary" or "ghost",
      controlSize = "sm",
      onClick = function() tagFilter = (tagFilter == tag) and nil or tag; render() end,
    }))
  end
  return ui.row({ gap = 4, align = "center" }, chips)
end

render = function()
  if board == nil then
    load()
  end
  layoutFor(#board.lanes)
  local lanes = {}
  for li, lane in ipairs(board.lanes) do
    table.insert(lanes, laneView(lane, li))
  end

  panel.render(ui.column({ gap = 14, flexGrow = 1 }, {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "layout-kanban", size = 22, color = "primary" }),
      boardTabs(),
      ui.spacer({ flexGrow = 1 }),
      ui.dropZone({
        key = "trash",
        accepts = { "card" },
        value = "trash",
        onDrop = onDrop,
        direction = "row",
        align = "center",
        gap = 8,
        paddingH = 14,
        height = 38,
        radius = 10,
        fill = "error/0.12",
        hitSlop = 12,
      }, {
        ui.glyph({ name = "trash", size = 18, color = "error" }),
        ui.label({ text = "Удалить", fontSize = 14, color = "on_surface_variant" }),
      }),
      ui.box({ width = 12, height = 1, fill = "#00000000" }),
      iconButton("column-insert-right", "Добавить колонку", addLane),
      iconButton("refresh", "Перечитать файл", function() load(); editingId, addingLane = nil, nil; render() end),
      iconButton("external-link", "Открыть в Obsidian", openInObsidian),
      iconButton("settings", "Настройки: папка с досками, доска по умолчанию, шрифт", function() panel.close(); noctalia.openSettings() end),
      iconButton("x", "Закрыть (Esc)", function() panel.close() end),
    }),
    tagBar(),
    ui.row({ gap = LANE_GAP, flexGrow = 1, align = "stretch" }, lanes),
  }))
end

-- ── Жизненный цикл ──────────────────────────────────────────────────────────

function onOpen()
  reloadIfChanged()
  scanBoards()
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  editingId, addingLane = nil, nil
end

-- Раз в секунду, пока открыта: подхватить правки из Obsidian. Пока что-то
-- набирается — не трогаем, правка сама сверится с файлом при сохранении.
function update()
  if clearArmed ~= nil and noctalia.nowMs() - clearArmed.at > 4000 then
    clearArmed = nil
    render()
  end
  if editingId ~= nil or addingLane ~= nil or laneEdit ~= nil or boardEdit then
    return
  end
  if reloadIfChanged() then
    render()
  end
end
