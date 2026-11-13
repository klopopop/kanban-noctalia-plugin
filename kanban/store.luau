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
function M.readState()
  if not noctalia.fileExists(M.STATE_FILE) then
    return {}
  end
  local raw = noctalia.readFile(M.STATE_FILE)
  local st = raw and noctalia.json.decode(raw) or nil
  return type(st) == "table" and st or {}
end

function M.writeState(st)
  noctalia.writeFile(M.STATE_FILE, noctalia.json.encode(st))
end

function M.updateState(fn)
  local st = M.readState()
  fn(st)
  M.writeState(st)
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

return M
