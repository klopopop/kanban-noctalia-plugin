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
--      shot <png> (карточка со скриншотом) · pomo-stop

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
  elseif event == "pomo-stop" then
    store.stopPomo()
  end
end

function update()
  checkPomo()
  if noctalia.nowMs() - lastCheck >= CHECK_EVERY_MS then
    checkDue(false, false)
  end
end

checkDue(false, false)
