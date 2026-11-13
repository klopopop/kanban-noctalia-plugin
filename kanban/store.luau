--!nonstrict
-- Общий доступ к доскам для всех частей плагина (панель, служба, виджеты,
-- лаунчер). У каждой части свой экземпляр модуля, поэтому общего в памяти
-- нет: всё — через файлы, а о своих записях части сообщают друг другу через
-- noctalia.state "kanban.rev" (меняется после каждой записи).

local boardLib = require("./board.luau")

local M = {}

M.STATE_FILE = noctalia.expandPath("~/.local/state/noctalia-kanban.json")

function M.settingPath()
  return noctalia.expandPath(noctalia.string.trim(noctalia.getConfig("board_path") or ""))
end

function M.boardsDir()
  return noctalia.expandPath(noctalia.string.trim(noctalia.getConfig("boards_dir") or ""))
end

function M.boardName(p)
  return string.match(p or "", "([^/]+)%.md$") or (p or "")
end

-- Файл состояния: текущая доска, цвета карточек, отметки напоминаний.
-- Файл состояния правят несколько частей сразу (панель, служба, значок), а
-- writeFile не атомарен: читатель может застать файл недописанным. Поэтому:
-- не разобралось — перечитать; так и не вышло — последнее удачное, и
-- updateState в таком случае ничего не пишет (иначе затрёт состояние пустым).
local lastGood = nil

local function readStateSafe()
  if not noctalia.fileExists(M.STATE_FILE) then
    return {}, true
  end
  for _ = 1, 8 do
    local raw = noctalia.readFile(M.STATE_FILE)
    if raw ~= nil and raw ~= "" then
      local st = noctalia.json.decode(raw)
      if type(st) == "table" then
        lastGood = st
        return st, true
      end
    end
  end
  return lastGood or {}, false
end

function M.readState()
  local st = readStateSafe()
  return st
end

function M.writeState(st)
  noctalia.writeFile(M.STATE_FILE, noctalia.json.encode(st))
  lastGood = st
end

function M.updateState(fn)
  local st, ok = readStateSafe()
  if not ok then
    noctalia.log("kanban: файл состояния не прочитался — правка пропущена")
    return false
  end
  fn(st)
  M.writeState(st)
  return true
end

-- Текущая доска. Настройка board_path — доска по умолчанию; если её поменять
-- в GUI, она главнее сохранённой.
function M.currentPath()
  local setting = M.settingPath()
  local st = M.readState()
  if st.setting == setting and type(st.path) == "string" and st.path ~= "" then
    return st.path
  end
  return setting
end

function M.rememberPath(p)
  M.updateState(function(st)
    st.setting = M.settingPath()
    st.path = p
  end)
end

function M.stampOf(p)
  local info = noctalia.fileInfo(p)
  if info == nil then
    return nil
  end
  return { mtime = info.mtime, size = info.size }
end

function M.sameStamp(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a.mtime == b.mtime and a.size == b.size
end

-- Прочитать доску; нет файла — пустая доска по умолчанию (не записывается).
function M.read(p)
  if not noctalia.fileExists(p) then
    return boardLib.default(), nil
  end
  local raw, err = noctalia.readFile(p)
  if raw == nil then
    return nil, err
  end
  return boardLib.parse(raw), nil
end

function M.bump()
  noctalia.state.set("kanban.rev", noctalia.nowMs())
end

function M.write(p, board)
  local ok, err = noctalia.writeFile(p, boardLib.serialize(board))
  if ok then
    M.bump()
  end
  return ok, err
end

-- Добавить карточку в колонку (по умолчанию — первую) текущей доски.
function M.addCard(text, laneIndex)
  text = noctalia.string.trim(text or "")
  if text == "" then
    return false, "пустой текст"
  end
  local p = M.currentPath()
  local board, err = M.read(p)
  if board == nil then
    return false, err
  end
  local lane = board.lanes[laneIndex or 1] or board.lanes[1]
  table.insert(lane.cards, boardLib.newCard(text, lane.complete))
  local ok, werr = M.write(p, board)
  return ok, werr, lane.title, M.boardName(p)
end

-- «В работе»: незавершённые колонки кроме первой (первая — входящие).
-- Если незавершённая колонка всего одна — она и есть «в работе».
function M.activeLanes(board)
  local open = {}
  for i, lane in ipairs(board.lanes) do
    if not lane.complete then
      table.insert(open, i)
    end
  end
  if #open <= 1 then
    return open
  end
  table.remove(open, 1)
  return open
end

-- Цвет карточки, выбранный вручную: по доске и тексту.
local function colorKey(p, text)
  return M.boardName(p) .. "|" .. noctalia.string.trim(text)
end

function M.colors()
  local st = M.readState()
  return type(st.colors) == "table" and st.colors or {}
end

function M.colorOf(colors, p, text)
  return colors[colorKey(p, text)]
end

function M.setColor(p, text, color, oldText)
  M.updateState(function(st)
    st.colors = type(st.colors) == "table" and st.colors or {}
    if oldText ~= nil then
      st.colors[colorKey(p, oldText)] = nil
    end
    st.colors[colorKey(p, text)] = color
  end)
  M.bump()
end

-- ── Учёт времени ──
-- track["доска|текст"] = { lane = заголовок, since = мс, done = мс|nil }
-- Сверка «где карточка сейчас» — reconcile: новая колонка → since = сейчас,
-- попала в «готово» → done = сейчас.

local function trackKey(p, text)
  return M.boardName(p) .. "|" .. noctalia.string.trim(text)
end

function M.reconcile(st, p, board)
  st.track = type(st.track) == "table" and st.track or {}
  local now = noctalia.nowMs()
  local seen = {}
  for _, lane in ipairs(board.lanes) do
    for _, card in ipairs(lane.cards) do
      local key = trackKey(p, card.text)
      seen[key] = true
      local t = st.track[key]
      if t == nil or t.lane ~= lane.title then
        t = { lane = lane.title, since = now, done = (t and t.done) or nil }
        if lane.complete then
          t.done = t.done or now
        else
          t.done = nil
        end
        st.track[key] = t
      end
    end
  end
  -- карточки этой доски, которых больше нет (удалены, в архиве), — забыть
  -- через 30 дней после закрытия, чтобы сводка за неделю их ещё видела
  local prefix = M.boardName(p) .. "|"
  for key, t in pairs(st.track) do
    if string.sub(key, 1, #prefix) == prefix and not seen[key] then
      if t.done == nil or now - t.done > 30 * 86400000 then
        st.track[key] = nil
      end
    end
  end
end

function M.trackOf(st, p, text)
  return type(st.track) == "table" and st.track[trackKey(p, text)] or nil
end

-- Текст карточки поменялся — учёт и цвет переезжают за ним.
function M.renameCard(p, oldText, newText)
  M.updateState(function(st)
    for _, field in ipairs({ "track", "colors" }) do
      local map = st[field]
      if type(map) == "table" then
        local a, b = trackKey(p, oldText), trackKey(p, newText)
        if map[a] ~= nil then
          map[b] = map[a]
          map[a] = nil
        end
      end
    end
  end)
end

-- ── Лимит карточек в колонке ── wip["доска|колонка"] = n
function M.wipOf(st, p, laneTitle)
  return type(st.wip) == "table" and st.wip[M.boardName(p) .. "|" .. laneTitle] or nil
end

function M.setWip(p, laneTitle, n, oldTitle)
  M.updateState(function(st)
    st.wip = type(st.wip) == "table" and st.wip or {}
    if oldTitle ~= nil then
      st.wip[M.boardName(p) .. "|" .. oldTitle] = nil
    end
    st.wip[M.boardName(p) .. "|" .. laneTitle] = (n ~= nil and n > 0) and n or nil
  end)
  M.bump()
end

-- ── Помидор ── pomo = { text, board, untilMs, minutes }
function M.pomo()
  local st = M.readState()
  local p = st.pomo
  if type(p) == "table" and type(p.untilMs) == "number" then
    return p
  end
  return nil
end

function M.startPomo(text, boardName, minutes)
  minutes = minutes or 25
  local pomo = { text = text, board = boardName, untilMs = noctalia.nowMs() + minutes * 60000, minutes = minutes }
  M.updateState(function(st) st.pomo = pomo end)
  noctalia.state.set("kanban.pomo", pomo)
  M.bump()
end

function M.stopPomo()
  M.updateState(function(st) st.pomo = nil end)
  noctalia.state.set("kanban.pomo", false)
  M.bump()
end

-- ── Повторы ── #каждый-день / #каждую-неделю / #каждый-месяц
local PERIODS = {
  ["каждый-день"] = 1, ["ежедневно"] = 1,
  ["каждую-неделю"] = 7, ["еженедельно"] = 7,
  ["каждый-месяц"] = 30, ["ежемесячно"] = 30,
}

function M.repeatDays(text)
  for _, tag in ipairs(boardLib.tagsOf(text)) do
    if PERIODS[tag] ~= nil then
      return PERIODS[tag]
    end
  end
  return nil
end

-- Карточка с повтором закрыта → следующая в первой колонке со сдвинутым
-- сроком (от старого срока, но не раньше завтра). Идемпотентно: если такая
-- уже есть в незавершённой колонке — ничего. Возвращает true, если добавила.
function M.respawn(board, card)
  local days = M.repeatDays(card.text)
  if days == nil or board.lanes[1] == nil then
    return false
  end
  local base = boardLib.dueOf(card.text)
  local shift = days
  if base ~= nil then
    local left = boardLib.daysUntil(base) or 0
    shift = math.max(left + days, 1)
  end
  local nextText = boardLib.withDue(card.text, boardLib.today(shift))
  for _, lane in ipairs(board.lanes) do
    if not lane.complete then
      for _, c in ipairs(lane.cards) do
        if c.text == nextText then
          return false
        end
      end
    end
  end
  table.insert(board.lanes[1].cards, boardLib.newCard(nextText, board.lanes[1].complete))
  return true
end

-- ── Открыть доску ──
-- Всё открывает служба: она знает, обычная панель или на весь экран, и
-- перед открытием подгоняет размер окна под монитор.
function M.openBoard(force)
  noctalia.runAsync({ "noctalia", "msg", "plugin", "pvs/kanban:service", "all", force and "open-force" or "open" })
end

function M.isFull()
  return M.readState().fullscreen == true
end

function M.setFull(on)
  M.updateState(function(st) st.fullscreen = on and true or nil end)
end

return M
