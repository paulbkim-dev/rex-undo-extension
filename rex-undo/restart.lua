local M = {}

-- Ctrl+U empties the prompt, so a command another tool typed there (rexurrect
-- types each pane's last command) isn't typed a second time.
local CLEAR = "\21"

local function each_pane(sessions, fn)
  for _, s in ipairs(sessions or {}) do
    for wi, w in ipairs(s.windows or {}) do
      for pi, p in ipairs(w.panes or {}) do fn(p, s, wi, pi) end
    end
  end
end

local function same_shape(a, b)
  if #(a.windows or {}) ~= #(b.windows or {}) then return false end
  for i, w in ipairs(a.windows or {}) do
    if #(w.panes or {}) ~= #(b.windows[i].panes or {}) then return false end
  end
  return true
end

-- Rex keeps session and block IDs over a restart, so the block ID comes first.
-- rexurrect recreates the sessions with new IDs, so then the session's name and
-- the pane's position decide, if the layout is unchanged.
local function matcher(saved, live)
  local by_block, by_id, by_label = {}, {}, {}
  each_pane(live.sessions, function(p, s) by_block[p.block_id] = { pane = p, session = s } end)
  for _, s in ipairs(live.sessions or {}) do
    by_id[s.session_id] = s
    local label = s.label or ""
    by_label[label] = by_label[label] or {}
    table.insert(by_label[label], s)
  end
  local target, used = {}, {}
  for _, s in ipairs(saved.sessions or {}) do
    if by_id[s.session_id] then
      target[s], used[s.session_id] = by_id[s.session_id], true
    end
  end
  for _, s in ipairs(saved.sessions or {}) do
    for _, candidate in ipairs((not target[s] and by_label[s.label or ""]) or {}) do
      if not used[candidate.session_id] and same_shape(s, candidate) then
        target[s], used[candidate.session_id] = candidate, true
        break
      end
    end
  end
  return function(p, s, wi, pi)
    local hit = by_block[p.block_id]
    if hit then return hit.pane, hit.session end
    local t = target[s]
    if t and same_shape(s, t) then return t.windows[wi].panes[pi], t end
  end
end

function M.plan(saved, live, opts)
  local find = matcher(saved, live)
  local running, unnamed = {}, {}
  each_pane(live.sessions, function(p) if p.key then running[p.key] = true end end)
  for key in pairs(opts.started) do running[key] = true end
  each_pane(saved.sessions, function(p)
    if p.agent and not p.key then
      local k = p.agent .. "\0" .. (p.cwd or "")
      unnamed[k] = (unnamed[k] or 0) + 1
    end
  end)

  local writes, notes, busy, claimed = {}, {}, 0, {}
  each_pane(saved.sessions, function(p, s, wi, pi)
    if not p.command or (not p.agent and opts.programs == false) then return end
    local where = string.format("%s tab %d pane %d", s.label or "session", wi, pi)
    local have, session = find(p, s, wi, pi)
    if not have then
      notes[#notes + 1] = where .. ": no matching pane"
    elseif opts.skip[have.block_id] then
      return
    elseif p.key and running[p.key] then
      notes[#notes + 1] = where .. ": its conversation is already open"
    elseif not have.idle or claimed[have.block_id] then
      busy = busy + 1
      notes[#notes + 1] = where .. ": the pane is busy"
    elseif p.cwd and not opts.exists(p.cwd) then
      notes[#notes + 1] = where .. ": its folder is gone"
    else
      -- Without a conversation to name, an agent resumes the latest one in its
      -- folder. Two of them there would open the same one, so those are typed
      -- for you to choose.
      local run = p.agent ~= nil and (p.key ~= nil or unnamed[p.agent .. "\0" .. (p.cwd or "")] == 1)
      local text = p.command
      if p.cwd and p.cwd ~= have.cwd then text = "cd " .. opts.quote(p.cwd) .. " && " .. text end
      claimed[have.block_id] = true
      if p.key then running[p.key] = true end
      writes[#writes + 1] = {
        session_id = session.session_id, block_id = have.block_id,
        data = CLEAR .. text .. (run and "\n" or ""), run = run, where = where, command = p.command,
        key = p.key,
      }
    end
  end)
  return writes, busy, notes
end

return M
