-- Four finger vertical swipe that drives the workspace control panel, a shell
-- plugin (io.github.dtpietrzak.workspace-control).
--
-- A plugin can't add to hyprland.lua, so WorkspaceControl.qml runs this file
-- itself: when it starts and after every Hyprland reload, which forgets all of
-- it, this flag included. The flag covers the shell restarting without a reload.
if dtpwc_loaded then
  return
end
dtpwc_loaded = true

-- This file only reports the swipe. The plugin owns the panel and decides what
-- a swipe means, so it can tell an opening drag from a closing one.
--
-- Reports go out as custom events on Hyprland's event socket, the one Quickshell
-- already listens to. The callbacks run inside Hyprland, so they must never call
-- hyprctl: it would wait on Hyprland forever.

local FINGERS = 4
-- Pixels of panel travel per touchpad delta unit. Raise it for a swipe that
-- needs less finger travel.
local SENSITIVITY = 1.0

local travel = nil
local reported = nil

local function emit(message)
  hl.dispatch(hl.dsp.event("dtpwc:" .. message))
end

local function report()
  local rounded = math.floor(travel + 0.5)
  if rounded ~= reported then
    reported = rounded
    emit("move " .. rounded)
  end
end

-- The panel follows the fingers, so a compositor fade would only lag behind.
hl.layer_rule({ match = { namespace = "^dtpietrzak-workspacecontrol(-peek)?$" }, no_anim = true, animation = "none" })

-- A glassy bar is drawn see-through with Hyprland blurring what is behind it, and
-- the panel's background follows the bar's, so it needs the same blur. Omarchy
-- reloads Hyprland whenever this toggle file comes or goes.
local state_home = os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
local glassy = io.open(state_home .. "/omarchy/toggles/hypr/bar-glassy.lua")
if glassy then
  glassy:close()
  hl.layer_rule({ match = { namespace = "^dtpietrzak-workspacecontrol(-peek)?$" }, blur = true, ignore_alpha = 0.3 })
end

-- Omarchy gives each monitor ten workspace slots, ids block * 10 + slot.
local SLOTS = 10

-- One slot over, empty or not, as a four finger swipe does. It does not wrap:
-- past the first or last slot it stays put.
local function slide(step)
  local workspace = hl.get_active_workspace()
  if not workspace or workspace.special or workspace.id < 1 then
    return
  end
  local slot = (workspace.id - 1) % SLOTS + 1 + step
  if slot >= 1 and slot <= SLOTS then
    hl.dispatch(o.workspaces.focus(slot))
  end
end

-- Hyprland keeps drawing a window opened over a maximized one above it, even
-- after the maximized one is focused and ahead of it in the stack, and clicks
-- follow the stack, so they pass straight through what's drawn. Maximizing again
-- is what makes Hyprland draw the maximized window on top.
local function take_front(window)
  local mode = window.fullscreen == 2 and "fullscreen" or "maximized"
  hl.dispatch(hl.dsp.window.fullscreen({ mode = mode, action = "unset", window = window }))
  hl.dispatch(hl.dsp.window.fullscreen({ mode = mode, action = "set", window = window }))
end

-- So a maximized window that gets focus, however it got it, really is in front.
hl.on("window.active", function(window)
  if not window or (window.fullscreen or 0) == 0 or not window.workspace then
    return
  end
  for _, other in ipairs(hl.get_workspace_windows(window.workspace) or {}) do
    if other.address ~= window.address and other.allowed_over_fullscreen and (other.fullscreen or 0) == 0 then
      take_front(window)
      return
    end
  end
end)

-- Focus the next or previous window on this workspace and bring it to the front.
-- It walks a fixed order, because the stack changes with every raise.
function dtpwc_cycle(step)
  local workspace = hl.get_active_workspace()
  if not workspace then
    return
  end
  local windows = hl.get_workspace_windows(workspace) or {}
  if #windows < 2 then
    return
  end
  table.sort(windows, function(a, b)
    return a.address < b.address
  end)
  local active = hl.get_active_window()
  local current = 1
  for index, window in ipairs(windows) do
    if active and window.address == active.address then
      current = index
    end
  end
  local target = windows[(current - 1 + step) % #windows + 1]
  local address = "address:" .. target.address
  -- Focusing a window warps the mouse to it. Leave the mouse where it is.
  local no_warps = hl.get_config("cursor.no_warps")
  hl.config({ cursor = { no_warps = true } })
  hl.dispatch(hl.dsp.focus({ window = address }))
  hl.config({ cursor = { no_warps = no_warps } })
  hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = address }))
  if (target.fullscreen or 0) ~= 0 then
    take_front(target)
  end
end

-- Workspace numbers are fixed, so moving a workspace along the row means moving
-- the windows: the one dragged takes its new position's number, and those it
-- passed shift over by one. `ids` is the row, 1-based; `insert` is the position
-- to land before, past the end for last.
function dtpwc_reorder(ids, from, insert)
  local order = {}
  for _, id in ipairs(ids) do
    order[#order + 1] = id
  end
  local dragged = table.remove(order, from)
  if insert > from then
    insert = insert - 1
  end
  table.insert(order, insert, dragged)

  local destination = {}
  for index, id in ipairs(order) do
    if id ~= ids[index] then
      destination[id] = ids[index]
    end
  end

  local active_workspace = hl.get_active_workspace()
  local active_window = hl.get_active_window()
  -- Listed first because moving changes what each workspace holds. Moving keeps
  -- a window's place in the stack, so the windows on each stay in order.
  local moves = {}
  for _, window in ipairs(hl.get_windows() or {}) do
    local target = window.workspace and destination[window.workspace.id]
    if target then
      moves[#moves + 1] = { address = window.address, workspace = target }
    end
  end
  for _, move in ipairs(moves) do
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(move.workspace), follow = false, window = "address:" .. move.address }))
  end

  -- If this was the workspace in view, keep it in view at its new number.
  local followed = active_workspace and destination[active_workspace.id]
  if followed then
    hl.dispatch(o.workspaces.focus((followed - 1) % SLOTS + 1))
    if active_window then
      local no_warps = hl.get_config("cursor.no_warps")
      hl.config({ cursor = { no_warps = true } })
      hl.dispatch(hl.dsp.focus({ window = "address:" .. active_window.address }))
      hl.config({ cursor = { no_warps = no_warps } })
    end
  end
end

-- The settings pane saves to this file and reloads Hyprland when these change.
local function enabled(setting, default)
  local config = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
  local file = io.open(config .. "/omarchy/io.github.dtpietrzak.workspace-control.json")
  if not file then
    return default
  end
  local text = file:read("a")
  file:close()
  if text:find('"' .. setting .. '"%s*:%s*false') then
    return false
  end
  if text:find('"' .. setting .. '"%s*:%s*true') then
    return true
  end
  return default
end

-- These replace Omarchy's defaults on the same keys, which swap tiled windows,
-- so they wait until they're turned on in the settings.
if enabled("hotkeys", false) then
  o.rebind("SUPER + SHIFT + LEFT", "Previous workspace", function()
    slide(-1)
  end)
  o.rebind("SUPER + SHIFT + RIGHT", "Next workspace", function()
    slide(1)
  end)
  o.rebind("SUPER + SHIFT + UP", "Next window on this workspace", function()
    dtpwc_cycle(1)
  end)
  o.rebind("SUPER + SHIFT + DOWN", "Previous window on this workspace", function()
    dtpwc_cycle(-1)
  end)
end

-- Last: Hyprland refuses this if the user already has a four finger vertical
-- gesture, and the error ends this file.
if enabled("swipe", true) then
  hl.gesture({
    fingers = FINGERS,
    direction = "vertical",
    action = {
      start = function(event)
        travel = event.delta.y * SENSITIVITY
        reported = nil
        emit("begin")
        report()
      end,
      update = function(event)
        if not travel then
          return
        end
        travel = travel + event.delta.y * SENSITIVITY
        report()
      end,
      finish = function(event)
        if not travel then
          return
        end
        travel = nil
        emit("end " .. (event.cancelled and "1" or "0"))
      end,
    },
  })
end
