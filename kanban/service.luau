--!nonstrict
-- Фоновая служба канбана:
--   • быстрое добавление карточки без панели (хоткей, скрипты):
--       noctalia msg plugin pvs/kanban:service all add "текст"
--   • напоминания о сроках @{ГГГГ-ММ-ДД}: раз в 10 минут проверяет все доски,
--     о каждой незакрытой карточке со сроком сегодня/просроченной —
--     одно уведомление в день;
--   • учёт времени: где и с какого момента лежит каждая карточка (в том числе
--     перенесённая в Obsidian), повторы #каждую-неделю для закрытых;
--   • сводка за неделю — по понедельникам;
--   • помидор: конец таймера — уведомление.
--
-- IPC: add <текст> · check (сроки сейчас) · summary (сводка сейчас) ·
--      shot <png> (карточка со скриншотом) · pomo-stop ·
--      open (открыть/закрыть доску; Win+K) · open-force (открыть)

local store = require("./store.luau")
local boardLib = require("./board.luau")

local CHECK_EVERY_MS = 600000
local lastCheck = 0

noctalia.setUpdateInterval(5000)

local function add(text)
  local ok, err, laneTitle, boardName = store.addCard(text)
  if ok then
    noctalia.notify("Канбан", "«" .. boardLib.bodyOf(text) .. "» → " .. tostring(laneTitle) .. " (" .. tostring(boardName) .. ")")
  else
    noctalia.notifyError("Канбан", "Не добавилось: " .. tostring(err))
  end
end

-- ── Сроки, учёт, повторы ──

local function listBoards(cb)
  local script = 'find "$1" -type f -name "*.md" -exec grep -l -m1 -e "^kanban-plugin: board" {} + 2>/dev/null; true'
  noctalia.runAsync({ "sh", "-c", script, "_", store.boardsDir() }, function(result)
    local list = {}
    for line in string.gmatch(result.stdout or "", "[^\n]+") do
      table.insert(list, line)
    end
    cb(list)
  end)
end

local function remindBoard(p, board, today, notified)
  for _, lane in ipairs(board.lanes) do
    if not lane.complete then
      for _, card in ipairs(lane.cards) do
        local due = boardLib.dueOf(card.text)
        local days = due and boardLib.daysUntil(due)
        if days ~= nil and days <= 0 and not card.done then
          local key = store.boardName(p) .. "|" .. card.text
          if notified[key] ~= today then
            notified[key] = today
            local when = days == 0 and "срок сегодня" or ("просрочено на " .. -days .. " дн.")
            noctalia.notify("Канбан: " .. when, boardLib.bodyOf(card.text) .. "\n" .. store.boardName(p) .. " → " .. lane.title)
          end
        end
      end
    end
  end
end

-- Повторы для закрытых в Obsidian (из панели повтор создаётся сразу).
local function respawnBoard(p, board)
  local changed = false
  for _, lane in ipairs(board.lanes) do
    if lane.complete then
      for _, card in ipairs(lane.cards) do
        if store.respawn(board, card) then
          changed = true
        end
      end
    end
  end
  if changed then
    store.write(p, board)
  end
end

local function summary(force, boards, st)
  -- неделя = дата её понедельника (os.date в Luau не знает %G/%V/%u)
  local now = os.date("*t")
  local sinceMonday = (now.wday + 5) % 7
  local week = os.date("%Y-%m-%d", os.time() - sinceMonday * 86400)
  local monday = sinceMonday == 0
  if not force and (not monday or st.summaryWeek == week) then
    return
  end
  st.summaryWeek = week
  local nowMs = noctalia.nowMs()
  local closed, stuck = 0, {}
  for _, b in ipairs(boards) do
    for _, lane in ipairs(b.board.lanes) do
      for _, card in ipairs(lane.cards) do
        local t = store.trackOf(st, b.path, card.text)
        if t ~= nil and t.done ~= nil and nowMs - t.done <= 7 * 86400000 then
          closed += 1
        elseif t ~= nil and not lane.complete and nowMs - t.since > 5 * 86400000 then
          local days = math.floor((nowMs - t.since) / 86400000)
          table.insert(stuck, "• " .. boardLib.bodyOf(card.text) .. " — " .. days .. " дн. в «" .. lane.title .. "»")
        end
      end
    end
  end
  local body = "Закрыто за неделю: " .. closed
  if #stuck > 0 then
    body ..= "\nЗависло (больше 5 дней):\n" .. table.concat(stuck, "\n", 1, math.min(#stuck, 8))
    if #stuck > 8 then
      body ..= "\n…и ещё " .. (#stuck - 8)
    end
  end
  noctalia.notify("Канбан: неделя", body)
end

function checkDue(force, wantSummary)
  lastCheck = noctalia.nowMs()
  listBoards(function(paths)
    local today = boardLib.today()
    local boards = {}
    for _, p in ipairs(paths) do
      local board = store.read(p)
      if board ~= nil then
        respawnBoard(p, board)
        table.insert(boards, { path = p, board = board })
      end
    end
    store.updateState(function(st)
      local notified = type(st.notified) == "table" and st.notified or {}
      if force then
        notified = {}
      end
      for k, v in pairs(notified) do
        if v ~= today then
          notified[k] = nil
        end
      end
      for _, b in ipairs(boards) do
        store.reconcile(st, b.path, b.board)
        remindBoard(b.path, b.board, today, notified)
      end
      st.notified = notified
      summary(wantSummary == true, boards, st)
    end)
  end)
end

-- ── Помидор ──

local function checkPomo()
  local pomo = store.pomo()
  if pomo ~= nil and noctalia.nowMs() >= pomo.untilMs then
    store.stopPomo()
    noctalia.notify("Помидор закончился", boardLib.bodyOf(pomo.text or "") .. "\nПерерыв 5 минут.")
  end
end

-- ── Окно доски ──
-- Размер обычной панели: size_percent от видимой области сфокусированного
-- монитора (логические px минус занятые панелями края). Пишется в
-- plugin.toml (строки «# kanban:size») + перезагрузка конфига — других
-- способов задать размер панели в API нет.
local MANIFEST = (noctalia.pluginDir() or noctalia.expandPath("~/.local/share/noctalia/plugins/kanban")) .. "/plugin.toml"

local function fitPanel(cb, openAfter)
  noctalia.runAsync({ "hyprctl", "monitors", "-j" }, function(result)
    local mons = noctalia.json.decode(result.stdout or "") or {}
    local mon = nil
    for _, m in ipairs(mons) do
      if m.focused then
        mon = m
      end
    end
    mon = mon or mons[1]
    if mon == nil then
      cb(false)
      return
    end
    local scale = tonumber(mon.scale) or 1
    local rot = (tonumber(mon.transform) or 0) % 2 == 1
    local lw = math.floor((rot and mon.height or mon.width) / scale + 0.5)
    local lh = math.floor((rot and mon.width or mon.height) / scale + 0.5)
    local r = mon.reserved or { 0, 0, 0, 0 }
    local aw = lw - (r[1] or 0) - (r[3] or 0)
    local ah = lh - (r[2] or 0) - (r[4] or 0)
    local pct = math.max(40, math.min(100, tonumber(noctalia.getConfig("size_percent")) or 85))
    local w = math.floor(aw * pct / 100)
    local h = math.floor(ah * pct / 100)
    store.updateState(function(st)
      st.size = { w = w, h = h, fullW = aw, fullH = ah }
    end)
    local raw = noctalia.readFile(MANIFEST) or ""
    local n = 0
    local fixed = string.gsub(raw, "(width%s*=%s*)%d+(%s*# kanban:size)", function(a, b)
      return a .. w .. b
    end)
    fixed = string.gsub(fixed, "(height%s*=%s*)%d+(%s*# kanban:size)", function(a, b)
      n += 1
      return a .. h .. b
    end)
    if fixed ~= raw and n > 0 then
      -- плагин перезапустится вместе со службой, колбэк не дождётся —
      -- открыть доску после перезапуска (см. конец файла)
      if openAfter then
        store.updateState(function(st) st.openPending = noctalia.nowMs() end)
      end
      noctalia.writeFile(MANIFEST, fixed)
      noctalia.runAsync({ "noctalia", "msg", "config-reload" }, function()
        -- дать хосту пересоздать панель с новым размером
        noctalia.runAsync({ "sleep", "0.4" }, function() cb(true) end)
      end)
    else
      cb(false)
    end
  end)
end

local function openBoard(force)
  local open = noctalia.state.get("kanban.open")
  if not force and type(open) == "string" and open ~= "" then
    noctalia.togglePanel(open)
    return
  end
  if store.isFull() then
    noctalia.togglePanel("pvs/kanban:full")
    return
  end
  fitPanel(function()
    noctalia.togglePanel("pvs/kanban:panel")
  end, true)
end

function onConfigChanged()
  fitPanel(function() end)
end

function onIpc(event, payload)
  if event == "add" then
    add(payload or "")
  elseif event == "check" then
    checkDue(true, false)
  elseif event == "summary" then
    checkDue(false, true)
  elseif event == "shot" then
    -- скриншот из extras/hyprland/kanban-shot.sh → attachments + карточка
    local src = noctalia.string.trim(payload or "")
    local name = "kanban-" .. os.date("%Y%m%d-%H%M%S") .. ".png"
    local dir = store.boardsDir() .. "/attachments"
    noctalia.runAsync({ "sh", "-c", 'mkdir -p "$1" && mv -f -- "$2" "$1/$3"', "_", dir, src, name }, function(result)
      if result.exitCode == 0 then
        add("Скриншот " .. os.date("%d.%m %H:%M") .. " ![[" .. name .. "]]")
      else
        noctalia.notifyError("Канбан", "Скриншот не сохранился: " .. tostring(result.stderr))
      end
    end)
  elseif event == "open" then
    openBoard(false)
  elseif event == "open-force" then
    openBoard(true)
  elseif event == "pomo-stop" then
    store.stopPomo()
  end
end

function update()
  checkPomo()
  if noctalia.nowMs() - lastCheck >= CHECK_EVERY_MS then
    checkDue(false, false)
fitPanel(function() end)
  end
end

checkDue(false, false)
fitPanel(function() end)

-- Открыть доску, если перед перезапуском просили (размер окна поменялся).
do
  local pending = store.readState().openPending
  if type(pending) == "number" then
    store.updateState(function(st) st.openPending = nil end)
    if noctalia.nowMs() - pending < 15000 then
      noctalia.runAsync({ "sleep", "0.5" }, function()
        noctalia.togglePanel("pvs/kanban:panel")
      end)
    end
  end
end
