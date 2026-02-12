-- lua/codex/state.lua

local M = {
  buf = nil,
  win = nil,
  job = nil,
  ready = false,
  pending = {},
  ready_probe_scheduled = false,
  ready_fallback_scheduled = false,
}

return M
