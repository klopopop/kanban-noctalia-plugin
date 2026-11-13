--!nonstrict
-- Фоновая служба канбана:
--   • быстрое добавление карточки без панели (хоткей, скрипты):
--       noctalia msg plugin pvs/kanban:service all add "текст"
--   • напоминания о сроках @{ГГГГ-ММ-ДД}: раз в 10 минут проверяет все доски,
--     о каждой незакрытой карточке со сроком сегодня/просроченной —
--     одно уведомление в день.

local store = require("./store.luau")
local boardLib = require("./board.luau")

noctalia.setUpdateInterval(600000)

local function add(text)
  local ok, err, laneTitle, boardName = store.addCard(text)
  if ok then
    noctalia.notify("Канбан", "«" .. boardLib.bodyOf(text) .. "» → " .. tostring(laneTitle) .. " (" .. tostring(boardName) .. ")")
  else
    noctalia.notifyError("Канбан", "Не добавилось: " .. tostring(err))
  end
end

function onIpc(event, payload)
  if event == "add" then
    add(payload or "")
  elseif event == "check" then
    checkDue(true)
  end
end

-- ── Напоминания ──

local function remindBoard(p, today, notified)
  local board = store.read(p)
  if board == nil then
    return
  end
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

function checkDue(force)
  local script = 'find "$1" -type f -name "*.md" -exec grep -l -m1 -e "^kanban-plugin: board" {} + 2>/dev/null; true'
  noctalia.runAsync({ "sh", "-c", script, "_", store.boardsDir() }, function(result)
    local today = boardLib.today()
    store.updateState(function(st)
      local notified = type(st.notified) == "table" and st.notified or {}
      if force then
        notified = {}
      end
      -- старые отметки (не сегодня) выкинуть, чтобы файл не рос
      for k, v in pairs(notified) do
        if v ~= today then
          notified[k] = nil
        end
      end
      for line in string.gmatch(result.stdout or "", "[^\n]+") do
        remindBoard(line, today, notified)
      end
      st.notified = notified
    end)
  end)
end

function update()
  checkDue(false)
end

-- первая проверка — после старта сессии
checkDue(false)
