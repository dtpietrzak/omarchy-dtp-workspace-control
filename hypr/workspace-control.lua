-- Four finger vertical swipe that drives the workspace control panel, a shell
-- plugin (dtpietrzak.workspacecontrol).
--
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

-- The panel follows the fingers, so a compositor fade would only lag behind.
hl.layer_rule({ match = { namespace = "^dtpietrzak-workspacecontrol$" }, no_anim = true, animation = "none" })
