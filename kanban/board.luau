--!nonstrict
-- Доска в markdown-формате плагина Obsidian Kanban (mgmeyers/obsidian-kanban):
--
--   ---
--
--   kanban-plugin: board
--
--   ---
--
--   ## Надо
--
--   - [ ] карточка<br>вторая строка
--
--
--   ## Готово
--
--   **Complete**
--   - [x] сделано
--
--   %% kanban:settings
--   ```
--   {"kanban-plugin":"board", ...}
--   ```
--   %%
--
-- Шапка (frontmatter) и блок настроек сохраняются как есть — их правит Obsidian.
-- Перенос строки в карточке хранится как <br>, как это делает сам Kanban.

local M = {}

local DEFAULT_FRONT = "---\n\nkanban-plugin: board\n\n---\n"
local DEFAULT_LANES = {
  { title = "Надо", complete = false },
  { title = "В работе", complete = false },
  { title = "Готово", complete = true },
}

local function settingsFooter(laneCount)
  local collapse = {}
  for _ = 1, laneCount do
    table.insert(collapse, "false")
  end
  return "%% kanban:settings\n```\n{\"kanban-plugin\":\"board\",\"list-collapse\":["
    .. table.concat(collapse, ",") .. "]}\n```\n%%"
end

local nextId = 0
local function newId()
  nextId += 1
  return "c" .. nextId
end

function M.newCard(text, done)
  return { id = newId(), text = text, done = done == true }
end

function M.default()
  local lanes = {}
  for _, lane in ipairs(DEFAULT_LANES) do
    table.insert(lanes, { title = lane.title, complete = lane.complete, cards = {} })
  end
  return { front = DEFAULT_FRONT, footer = settingsFooter(#lanes), lanes = lanes }
end

local function decodeText(raw)
  local text = string.gsub(raw, "<br%s*/?>", "\n")
  return text
end

local function encodeText(text)
  local line = string.gsub(noctalia.string.trim(text), "\r", "")
  line = string.gsub(line, "\n", "<br>")
  return line
end

function M.parse(src)
  src = string.gsub(src or "", "\r\n", "\n")
  local board = { front = DEFAULT_FRONT, footer = nil, lanes = {} }

  -- frontmatter: от первой строки «---» до следующей «---»
  local body = src
  if string.sub(src, 1, 4) == "---\n" then
    local stop = string.find(src, "\n%-%-%-[ \t]*\n", 4)
      or string.find(src, "\n%-%-%-[ \t]*$", 4)
    if stop ~= nil then
      local close = string.find(src, "\n", stop + 1) or #src
      board.front = string.sub(src, 1, close)
      body = string.sub(src, close + 1)
    end
  end

  -- блок настроек Kanban в конце
  local footerAt = string.find(body, "%%%% kanban:settings", 1)
  if footerAt ~= nil then
    board.footer = noctalia.string.trim(string.sub(body, footerAt))
    body = string.sub(body, 1, footerAt - 1)
  end

  local lane = nil
  local card = nil
  local afterRule = false -- «***» отделяет архив от колонок
  board.archive = {}
  for line in string.gmatch(body .. "\n", "([^\n]*)\n") do
    local heading = string.match(line, "^##%s+(.-)%s*$")
    local mark, text = string.match(line, "^%s*[-*]%s+%[(.)%]%s?(.*)$")
    if string.match(line, "^%*%*%*%s*$") then
      afterRule = true
      lane, card = nil, nil
    elseif heading ~= nil and afterRule then
      -- архив: карточки сюда, колонкой не показываем
      lane = { title = heading, complete = true, cards = board.archive, isArchive = true }
      card = nil
    elseif heading ~= nil then
      lane = { title = heading, complete = false, cards = {} }
      table.insert(board.lanes, lane)
      card = nil
    elseif lane ~= nil and not lane.isArchive and string.match(line, "^%*%*Complete%*%*%s*$") then
      lane.complete = true
    elseif lane ~= nil and mark ~= nil then
      card = M.newCard(decodeText(text), mark ~= " ")
      table.insert(lane.cards, card)
    elseif card ~= nil and string.match(line, "^%s+%S") then
      -- продолжение карточки с отступом (так пишут руками)
      card.text = card.text .. "\n" .. decodeText(noctalia.string.trim(line))
    elseif noctalia.string.trim(line) == "" then
      card = nil
    end
  end

  if #board.lanes == 0 then
    return M.default()
  end
  board.footer = board.footer or settingsFooter(#board.lanes)
  return board
end

-- В настройках Kanban list-collapse — по флагу на колонку; после добавления
-- или удаления колонок длину подгоняем, сохраняя флаги, что уже были.
local function fitFooter(footer, n)
  if footer == nil then
    return settingsFooter(n)
  end
  local fixed, count = string.gsub(footer, '"list%-collapse":%[([^%]]*)%]', function(inner)
    local flags = {}
    for flag in string.gmatch(inner, "%a+") do
      table.insert(flags, flag)
    end
    local out = {}
    for i = 1, n do
      out[i] = flags[i] or "false"
    end
    return '"list-collapse":[' .. table.concat(out, ",") .. "]"
  end)
  if count == 0 then
    return footer
  end
  return fixed
end

function M.serialize(board)
  local out = { noctalia.string.trim(board.front), "", "" }
  for _, lane in ipairs(board.lanes) do
    table.insert(out, "## " .. lane.title)
    table.insert(out, "")
    if lane.complete then
      table.insert(out, "**Complete**")
    end
    for _, card in ipairs(lane.cards) do
      table.insert(out, "- [" .. (card.done and "x" or " ") .. "] " .. encodeText(card.text))
    end
    table.insert(out, "")
    table.insert(out, "")
  end
  if board.archive ~= nil and #board.archive > 0 then
    table.insert(out, "***")
    table.insert(out, "")
    table.insert(out, "## Archive")
    table.insert(out, "")
    for _, card in ipairs(board.archive) do
      table.insert(out, "- [x] " .. encodeText(card.text))
    end
    table.insert(out, "")
    table.insert(out, "")
  end
  table.insert(out, "")
  table.insert(out, fitFooter(board.footer, #board.lanes))
  table.insert(out, "")
  return table.concat(out, "\n")
end

-- ── Сроки и метки (как в Obsidian Kanban) ──

-- Срок: @{2026-11-20} → "2026-11-20"
function M.dueOf(text)
  return string.match(text or "", "@{(%d%d%d%d%-%d%d%-%d%d)}")
end

-- Заменить/поставить/убрать срок в тексте.
function M.withDue(text, date)
  local t = string.gsub(text or "", "%s*@{%d%d%d%d%-%d%d%-%d%d}", "")
  t = noctalia.string.trim(t)
  if date ~= nil and date ~= "" then
    t = t .. " @{" .. date .. "}"
  end
  return t
end

-- Метки: #работа, #дом/кухня (буквы, цифры, _ - /; кириллица — UTF-8 байты)
function M.tagsOf(text)
  local tags, seen = {}, {}
  for tag in string.gmatch(" " .. (text or ""), "[%s(]#([^%s#,.;:!?()]+)") do
    if not seen[tag] then
      seen[tag] = true
      table.insert(tags, tag)
    end
  end
  return tags
end

-- ── Содержимое карточки ──

-- Чек-лист: строки «- [ ] пункт» / «- [x] пункт» в тексте карточки.
function M.checklist(text)
  local items = {}
  for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
    local mark, label = string.match(line, "^%s*[-*]%s+%[(.)%]%s*(.*)$")
    if mark ~= nil then
      table.insert(items, { done = mark ~= " ", label = label })
    end
  end
  return items
end

-- Отметить/снять n-й пункт чек-листа.
function M.toggleItem(text, n)
  local i = 0
  local out = {}
  for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
    local pre, mark, rest = string.match(line, "^(%s*[-*]%s+%[)(.)(%].*)$")
    if mark ~= nil then
      i += 1
      if i == n then
        line = pre .. (mark == " " and "x" or " ") .. rest
      end
    end
    table.insert(out, line)
  end
  return table.concat(out, "\n")
end

-- Ссылки: [[Заметка]] / [[Заметка|подпись]] и http(s)://…
function M.links(text)
  local out = {}
  for inner in string.gmatch(text or "", "%[%[([^%]]+)%]%]") do
    local target, alias = string.match(inner, "^([^|]+)|(.+)$")
    target = target or inner
    -- ![[картинка]] — не ссылка
    local pos = string.find(text, "!%[%[" .. string.gsub(inner, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
    if pos == nil then
      table.insert(out, { kind = "note", target = target, label = alias or target })
    end
  end
  for url in string.gmatch(text or "", "(https?://[^%s%)>]+)") do
    local host = string.match(url, "^https?://([^/]+)") or url
    table.insert(out, { kind = "url", target = url, label = host })
  end
  return out
end

-- Первая картинка: ![[файл.png]] или ![](путь)
function M.imageOf(text)
  local name = string.match(text or "", "!%[%[([^%]|]+)[^%]]*%]%]")
  if name ~= nil then
    return name
  end
  return string.match(text or "", "!%[[^%]]*%]%(([^%)]+)%)")
end

-- Приоритет: «!! текст» — 2, «! текст» — 1, иначе 0.
function M.priority(text)
  local t = noctalia.string.trim(text or "")
  if string.sub(t, 1, 2) == "!!" then
    return 2
  elseif string.sub(t, 1, 1) == "!" and string.sub(t, 2, 2) ~= "[" then
    return 1
  end
  return 0
end

-- Текст для листка: без срока, меток, чек-листа, картинок и приоритета;
-- [[ссылки]] — их подписью, адреса — доменом.
function M.bodyOf(text)
  local lines = {}
  for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
    if not string.match(line, "^%s*[-*]%s+%[.%]") then
      table.insert(lines, line)
    end
  end
  local t = table.concat(lines, "\n")
  t = string.gsub(t, "^%s*!!?%s+", "")
  t = string.gsub(t, "!%[%[[^%]]*%]%]", "")
  t = string.gsub(t, "!%[[^%]]*%]%([^%)]*%)", "")
  t = string.gsub(t, "%[%[([^%]|]+)|([^%]]+)%]%]", "%2")
  t = string.gsub(t, "%[%[([^%]]+)%]%]", "%1")
  t = string.gsub(t, "https?://([^/%s]+)[^%s%)>]*", "%1")
  t = string.gsub(t, "%s*@{%d%d%d%d%-%d%d%-%d%d}", "")
  t = string.gsub(" " .. t, "([%s(])#[^%s#,.;:!?()]+", "%1")
  t = string.gsub(t, "[ \t]+\n", "\n")
  t = string.gsub(t, "\n\n+", "\n")
  t = string.gsub(t, "  +", " ")
  return noctalia.string.trim(t)
end

-- "2026-11-20" → дни от сегодня (отрицательно — просрочено)
function M.daysUntil(date)
  local y, m, d = string.match(date or "", "^(%d+)%-(%d+)%-(%d+)$")
  if y == nil then
    return nil
  end
  local due = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local now = os.date("*t")
  local today = os.time({ year = now.year, month = now.month, day = now.day, hour = 12 })
  return math.floor((due - today) / 86400 + 0.5)
end

function M.today(offsetDays)
  return os.date("%Y-%m-%d", os.time() + (offsetDays or 0) * 86400)
end

return M
