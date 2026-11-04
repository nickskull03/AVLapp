-- Show Deck feedback for grandMA3
--
-- Sends what Show Deck can't otherwise know to the app over OSC: executor
-- names, fader positions, running states, current and next cue, and the page
-- the desk is on. Runs until you run it again (it toggles).
--
-- Uses OSC line OSC_LINE in Menu › In & Out › OSC, which must have Send on and
-- point at the iPad: its prefix is added to everything sent.
--
-- Messages (after the prefix):
--   /Page<p>/Name<exec>    ,s  name of the object on the executor ("-" if none)
--   /Page<p>/Fader<exec>   ,i  fader or knob position, 0–100
--   /Page<p>/Active<exec>  ,i  1 while its playback runs
--   /Page<p>/Cue<exec>     ,s  current cue: number and name
--   /Page<p>/NextCue<exec> ,s  next cue
--   /CurrentPage           ,i  the page the desk is on
--
-- Written for grandMA3 2.5 (checked against the 2.5.1 Lua API and object
-- properties). Based on the approach of MA3_OSC_FEEDBACK by ArtGateOne and
-- Andreas from the MA forum. Every lookup is guarded, so anything a software
-- version lacks just isn't sent.

local OSC_LINE = 1          -- which OSC line to send with
local COLUMNS = 15          -- executors x01–x15
local ROWS = {1, 2, 3, 4}   -- 1xx (under the fader), 2xx (fader), 3xx and 4xx (knobs)
local INTERVAL = 0.25       -- seconds between checks
local RESEND = 20           -- also resend everything every this many checks

local Cmd, GetExecutor, ipairs, pcall, tostring, tonumber, mfloor = Cmd, GetExecutor, ipairs, pcall, tostring, tonumber, math.floor

local running = false
local sent = {}

-- Commas and quotes would break the SendOSC command; spaces are fine.
local function clean(text)
  text = tostring(text or "")
  text = text:gsub('[,"]', ' '):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  if text == "" then return "-" end
  return text
end

local function send(address, kind, value)
  local text = tostring(value)
  if sent[address] == text then return end
  sent[address] = text
  Cmd(string.format('SendOSC %d "%s,%s,%s"', OSC_LINE, address, kind, text))
end

local function safe(f, ...)
  local ok, result = pcall(f, ...)
  if ok then return result end
  return nil
end

-- A property by name (2.5: handle:Get("Name")), falling back to field access.
local function prop(handle, name)
  if not handle then return nil end
  local value = safe(function() return handle:Get(name) end)
  if value == nil then value = safe(function() return handle[name] end) end
  return value
end

local function currentPage()
  local page = safe(CurrentExecPage)
  return tonumber(prop(page, "No")) or 1
end

-- "3 Verse": a cue's number, then its name if it isn't just "Cue 3".
local function label(number, name)
  number = tostring(number or "")
  name = tostring(name or "")
  if number == "" and name == "" then return "-" end
  if name == "" or name == ("Cue " .. number) then return clean(number) end
  return clean(number .. " " .. name)
end

-- Current and next cue of a sequence. 2.5 sequences carry CueNo, CueName and
-- CurrentCue; the next cue is the one after CurrentCue among its children.
local function cues(sequence)
  if not sequence then return "-", "-" end
  local cueNo = prop(sequence, "CueNo")
  if cueNo == nil or cueNo == "" then return "-", "-" end
  local current = label(cueNo, prop(sequence, "CueName"))
  local nextLabel = "-"
  local currentCue = prop(sequence, "CurrentCue")
  local children = safe(function() return sequence:Children() end) or {}
  for i, child in ipairs(children) do
    if child == currentCue and children[i + 1] then
      local nextCue = children[i + 1]
      nextLabel = label(prop(nextCue, "No"), prop(nextCue, "Name"))
      break
    end
  end
  return current, nextLabel
end

local function poll(pageNumber, exec)
  local executor = safe(GetExecutor, exec)
  local object = prop(executor, "Object")
  local base = string.format("/Page%d/", pageNumber)

  send(base .. "Name" .. exec, "s", clean(prop(object, "Name")))

  local fader = executor and safe(function() return executor:GetFader({}) end)
  if fader then send(base .. "Fader" .. exec, "i", mfloor(fader + 0.5)) end

  local active = object and safe(function() return object:HasActivePlayback() end)
  send(base .. "Active" .. exec, "i", active and 1 or 0)

  local current, nextLabel = cues(object)
  send(base .. "Cue" .. exec, "s", current)
  send(base .. "NextCue" .. exec, "s", nextLabel)
end

local function mainloop()
  local checks = 0
  while running do
    local pageNumber = currentPage()
    send("/CurrentPage", "i", pageNumber)
    for _, row in ipairs(ROWS) do
      for column = 1, COLUMNS do
        poll(pageNumber, row * 100 + column)
      end
    end
    checks = checks + 1
    if checks >= RESEND then
      checks = 0
      sent = {} -- so an app that just connected gets everything
    end
    coroutine.yield(INTERVAL)
  end
end

local function toggle(displayHandle)
  if running then
    running = false
    Printf("Show Deck feedback stopped")
  else
    running = true
    sent = {}
    Printf("Show Deck feedback running")
    mainloop()
  end
end

local function cleanup()
  running = false
end

return toggle, cleanup
