local vim = vim
local installer = require 'codex.installer'
local state = require 'codex.state'

local M = {}
M.actions = {}

local config = {
  keymaps = {
    smart = '<C-a>', -- Default: Ctrl+a for smart Codex actions
    toggle = nil,
    quit = '<C-q>', -- Default: Ctrl+q to quit
  },
  border = 'single',
  width = 0.8,
  height = 0.8,
  cmd = 'codex',
  model = nil, -- Default to the latest model
  autoinstall = true,
  panel     = false,   -- if true, open Codex in a side-panel instead of floating window
  use_buffer = false,  -- if true, capture Codex stdout into a normal buffer instead of a terminal
  cwd_from_buffer = true, -- if true, run Codex from current file's directory
}

local smart_keymap_lhs = nil

local function clear_smart_keymaps(lhs)
  if type(lhs) ~= 'string' or lhs == '' then
    return
  end

  pcall(vim.keymap.del, 'n', lhs)
  pcall(vim.keymap.del, 'x', lhs)
end

local function setup_smart_keymaps()
  if smart_keymap_lhs then
    clear_smart_keymaps(smart_keymap_lhs)
    smart_keymap_lhs = nil
  end

  local smart_lhs = config.keymaps and config.keymaps.smart
  if type(smart_lhs) ~= 'string' or smart_lhs == '' then
    return
  end

  vim.keymap.set('n', smart_lhs, function()
    M.toggle()
  end, { silent = true, desc = 'Codex: Toggle' })

  vim.keymap.set('x', smart_lhs, function()
    M.actions.send_selection { submit = false }
  end, { silent = true, desc = 'Codex: Send selection' })

  smart_keymap_lhs = smart_lhs
end

local function cmd_contains_model_flag(cmd_args)
  for _, arg in ipairs(cmd_args or {}) do
    if arg == '-m' or arg == '--model' then
      return true
    end
  end

  return false
end

local function build_cmd_args()
  local raw_cmd = config.cmd

  if raw_cmd == nil then
    raw_cmd = 'codex'
  end

  local cmd_args = type(raw_cmd) == 'string' and { raw_cmd } or vim.deepcopy(raw_cmd)

  if config.model and not cmd_contains_model_flag(cmd_args) then
    table.insert(cmd_args, '-m')
    table.insert(cmd_args, config.model)
  end

  return cmd_args
end

local function check_cmd(cmd_args)
  local executable_cmd = type(cmd_args) == 'table' and cmd_args[1] or nil
  if type(executable_cmd) == 'string' and not executable_cmd:find '%s' then
    return executable_cmd
  end

  return nil
end

local function resolve_job_cwd()
  if not config.cwd_from_buffer then
    return vim.loop.cwd()
  end

  local file_path = vim.api.nvim_buf_get_name(0)
  if file_path == '' then
    return vim.loop.cwd()
  end

  local file_dir = vim.fn.fnamemodify(file_path, ':p:h')
  if file_dir == '' or vim.fn.isdirectory(file_dir) == 0 then
    return vim.loop.cwd()
  end

  return file_dir
end

local function normalize_column(buffer_number, line_number, column_number, is_end)
  if column_number < 0 then
    return column_number
  end

  local line_text = vim.api.nvim_buf_get_lines(buffer_number, line_number - 1, line_number, false)[1] or ''
  if column_number == 2147483647 then
    return #line_text
  end

  local zero_based_column = math.max(column_number - 1, 0)
  if is_end then
    zero_based_column = math.min(zero_based_column + 1, #line_text)
  else
    zero_based_column = math.min(zero_based_column, #line_text)
  end

  return zero_based_column
end

local function exit_visual_mode_if_needed()
  if vim.api.nvim_get_mode().mode:match '^[vV\22]' then
    local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
    vim.api.nvim_feedkeys(esc, 'nx', false)
  end
end

local function get_visual_selection()
  local buffer_number = vim.api.nvim_get_current_buf()
  local current_mode = vim.fn.mode()
  local needs_restore = false

  if not current_mode:match '^[vV\22]' then
    local ok = pcall(vim.cmd, [[normal! gv]])
    if not ok then
      return nil
    end

    current_mode = vim.fn.mode()
    needs_restore = true
  end

  local selection_type = vim.fn.visualmode()
  if selection_type == nil or selection_type == '' then
    selection_type = current_mode
  end
  selection_type = selection_type:sub(1, 1)

  local start_pos = vim.fn.getpos 'v'
  local end_pos = vim.fn.getpos '.'
  if start_pos[2] == 0 or end_pos[2] == 0 then
    if needs_restore or current_mode:match '^[vV\22]' then
      exit_visual_mode_if_needed()
    end
    return nil
  end

  if needs_restore or current_mode:match '^[vV\22]' then
    exit_visual_mode_if_needed()
  end

  local start_line = start_pos[2]
  local start_column = start_pos[3]
  local end_line = end_pos[2]
  local end_column = end_pos[3]

  if start_line > end_line or (start_line == end_line and start_column > end_column) then
    start_line, end_line = end_line, start_line
    start_column, end_column = end_column, start_column
  end

  local text
  if selection_type == 'V' then
    local lines = vim.api.nvim_buf_get_lines(buffer_number, start_line - 1, end_line, false)
    text = table.concat(lines, '\n')
  elseif selection_type == '\22' then
    local left_col = math.min(start_column, end_column) - 1
    local right_col = math.max(start_column, end_column) - 1
    local pieces = {}

    for row = start_line - 1, end_line - 1 do
      local line = vim.api.nvim_buf_get_lines(buffer_number, row, row + 1, false)[1] or ''
      pieces[#pieces + 1] = line:sub(left_col + 1, math.min(right_col + 1, #line))
    end

    text = table.concat(pieces, '\n')
  else
    local start_col = normalize_column(buffer_number, start_line, start_column, false)
    local end_col = normalize_column(buffer_number, end_line, end_column, true)
    local lines = vim.api.nvim_buf_get_text(buffer_number, start_line - 1, start_col, end_line - 1, end_col, {})
    text = table.concat(lines, '\n')
  end

  if text == '' then
    return nil
  end

  if vim.bo.expandtab then
    local tabstop = vim.bo.tabstop
    if tabstop and tabstop > 0 then
      text = text:gsub('\t', string.rep(' ', tabstop))
    end
  end

  return {
    buffer_number = buffer_number,
    start_line = start_line,
    end_line = end_line,
    text = text,
  }
end

local function reset_session_send_state()
  state.ready = false
  state.pending = {}
  state.ready_probe_scheduled = false
  state.ready_fallback_scheduled = false
end

local function flush_pending_messages()
  if not state.job or not state.ready then
    return
  end

  local queue = state.pending or {}
  if #queue == 0 then
    return
  end

  state.pending = {}

  for i, payload in ipairs(queue) do
    local ok = pcall(vim.fn.chansend, state.job, payload)
    if not ok then
      for j = i, #queue do
        table.insert(state.pending, queue[j])
      end
      vim.notify('codex.nvim: failed to flush queued message to Codex session', vim.log.levels.ERROR)
      return
    end
  end
end

local function mark_session_ready()
  if not state.job or state.ready then
    return
  end

  state.ready = true
  flush_pending_messages()
end

local function schedule_ready_probe(delay, kind)
  local flag_name = kind == 'fallback' and 'ready_fallback_scheduled' or 'ready_probe_scheduled'
  if state[flag_name] then
    return
  end

  state[flag_name] = true
  vim.defer_fn(function()
    state[flag_name] = false
    mark_session_ready()
  end, delay)
end

local function schedule_session_ready_fallback()
  schedule_ready_probe(1200, 'fallback')
end

function M.actions.send(text, opts)
  local options = opts or {}
  local submit = options.submit == true

  if type(text) ~= 'string' or text == '' then
    vim.notify('codex.nvim: cannot send empty message', vim.log.levels.WARN)
    return false
  end

  if config.use_buffer then
    vim.notify('codex.nvim: actions.send is available only when use_buffer = false', vim.log.levels.WARN)
    return false
  end

  if not state.job then
    vim.notify('codex.nvim: no active Codex session (open Codex first)', vim.log.levels.WARN)
    return false
  end

  local payload = submit and (text .. '\n') or text

  if not state.ready then
    state.pending = state.pending or {}
    table.insert(state.pending, payload)
    schedule_session_ready_fallback()
    return true
  end

  local ok = pcall(vim.fn.chansend, state.job, payload)

  if not ok then
    vim.notify('codex.nvim: failed to send message to Codex session', vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.actions.send_selection(opts)
  local options = opts or {}
  local origin_win = vim.api.nvim_get_current_win()

  local selection = get_visual_selection()
  if not selection or not selection.text or selection.text == '' then
    vim.notify('codex.nvim: visual selection is empty', vim.log.levels.WARN)
    return false
  end

  local filename = vim.api.nvim_buf_get_name(selection.buffer_number)
  if filename == '' then
    filename = '[No Name]'
  else
    filename = vim.fn.fnamemodify(filename, ':t')
  end

  local payload = string.format('File: %s:%d-%d\n\n%s', filename, selection.start_line, selection.end_line, selection.text)
  if payload:sub(-1) ~= '\n' then
    payload = payload .. '\n\n'
  end

  local has_visible_window = state.win and vim.api.nvim_win_is_valid(state.win)

  if not state.job then
    if has_visible_window then
      M.close()
    end

    M.open { focus = false }
  elseif not has_visible_window then
    M.open { focus = false }
  end

  if not state.job then
    vim.notify('codex.nvim: no active Codex session (open Codex first)', vim.log.levels.WARN)
    if vim.api.nvim_win_is_valid(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
    exit_visual_mode_if_needed()
    return false
  end

  local ok = M.actions.send(payload, { submit = options.submit == true })

  if vim.api.nvim_win_is_valid(origin_win) then
    pcall(vim.api.nvim_set_current_win, origin_win)
  end
  exit_visual_mode_if_needed()

  return ok
end

function M.setup(user_config)
  config = vim.tbl_deep_extend('force', config, user_config or {})

  vim.api.nvim_create_user_command('Codex', function()
    M.toggle()
  end, { desc = 'Toggle Codex popup' })

  vim.api.nvim_create_user_command('CodexToggle', function()
    M.toggle()
  end, { desc = 'Toggle Codex popup (alias)' })

  vim.api.nvim_create_user_command('CodexSendSelection', function()
    M.actions.send_selection()
  end, { desc = 'Send visual selection to Codex' })

  if config.keymaps.toggle then
    vim.api.nvim_set_keymap('n', config.keymaps.toggle, '<cmd>CodexToggle<CR>', { noremap = true, silent = true })
  end

  setup_smart_keymaps()
end

local function open_window(enter)
  local width = math.floor(vim.o.columns * config.width)
  local height = math.floor(vim.o.lines * config.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local styles = {
    single = {
      { '┌', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '┐', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '┘', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '└', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    double = {
      { '╔', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╗', 'FloatBorder' },
      { '║', 'FloatBorder' },
      { '╝', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╚', 'FloatBorder' },
      { '║', 'FloatBorder' },
    },
    rounded = {
      { '╭', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╮', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '╯', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╰', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    none = nil,
  }

  local border = type(config.border) == 'string' and styles[config.border] or config.border

  state.win = vim.api.nvim_open_win(state.buf, enter ~= false, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = border,
  })
end

--- Open Codex in a side-panel (vertical split) instead of floating window
local function open_panel(enter)
  -- Create a vertical split on the right and show the buffer
  local origin_win = vim.api.nvim_get_current_win()
  vim.cmd('vertical rightbelow vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.buf)
  -- Adjust width according to config (percentage of total columns)
  local width = math.floor(vim.o.columns * config.width)
  vim.api.nvim_win_set_width(win, width)
  state.win = win

  if enter == false and vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end
end

function M.open(opts)
  local options = opts or {}
  local focus_window = options.focus ~= false

  local function create_clean_buf()
    local buf = vim.api.nvim_create_buf(false, false)

    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(buf, 'filetype', 'codex')

    -- Apply configured quit keybinding

    if config.keymaps.quit then
      local quit_cmd = [[<cmd>lua require('codex').close()<CR>]]
      vim.api.nvim_buf_set_keymap(buf, 't', config.keymaps.quit, [[<C-\><C-n>]] .. quit_cmd, { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(buf, 'n', config.keymaps.quit, quit_cmd, { noremap = true, silent = true })
    end

    return buf
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    if focus_window then
      vim.api.nvim_set_current_win(state.win)
    end
    return
  end

  local cmd_args = build_cmd_args()
  local executable_cmd = check_cmd(cmd_args)

  if executable_cmd and vim.fn.executable(executable_cmd) == 0 then
    if config.autoinstall then
      installer.prompt_autoinstall(function(success)
        if success then
          M.open(options) -- Try again after installing
        else
          -- Show failure message *after* buffer is created
          if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
            state.buf = create_clean_buf()
          end
          vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
            'Autoinstall cancelled or failed.',
            '',
            'You can install manually with:',
            '  npm install -g @openai/codex',
          })
          if config.panel then open_panel(focus_window) else open_window(focus_window) end
        end
      end)
      return
    else
      -- Show fallback message
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        state.buf = vim.api.nvim_create_buf(false, false)
      end
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
        'Codex CLI not found, autoinstall disabled.',
        '',
        'Install with:',
        '  npm install -g @openai/codex',
        '',
        'Or enable autoinstall in setup: require("codex").setup{ autoinstall = true }',
      })
      if config.panel then open_panel(focus_window) else open_window(focus_window) end
      return
    end
  end

  local function is_buf_reusable(buf)
    return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
  end

  if not is_buf_reusable(state.buf) then
    state.buf = create_clean_buf()
  end

  local job_cwd = nil
  if not state.job then
    job_cwd = resolve_job_cwd()
  end

  if config.panel then open_panel(focus_window) else open_window(focus_window) end

  if not state.job then
    reset_session_send_state()

    if config.use_buffer then
      -- capture stdout/stderr into normal buffer
      state.job = vim.fn.jobstart(cmd_args, {
        cwd = job_cwd,
        stdout_buffered = true,
        on_stdout = function(_, data)
          if not data then return end
          for _, line in ipairs(data) do
            if line ~= '' then
              vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { line })
            end
          end
        end,
        on_stderr = function(_, data)
          if not data then return end
          for _, line in ipairs(data) do
            if line ~= '' then
              vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { '[ERR] ' .. line })
            end
          end
        end,
        on_exit = function(_, code)
          state.job = nil
          reset_session_send_state()
          vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, {
            ('[Codex exit: %d]'):format(code),
          })
        end,
      })
    else
      -- use a terminal buffer
      local term_options = {
        cwd = job_cwd,
        on_stdout = function(_, data)
          if not state.job or state.ready then
            return
          end

          if data and #data > 0 then
            schedule_ready_probe(120, 'probe')
          end
        end,
        on_exit = function()
          state.job = nil
          reset_session_send_state()
        end,
      }

      local function open_terminal()
        return vim.fn.termopen(cmd_args, term_options)
      end

      if state.win and vim.api.nvim_win_is_valid(state.win) then
        local opened_job = nil
        local ok = pcall(vim.api.nvim_win_call, state.win, function()
          opened_job = open_terminal()
        end)

        if ok then
          state.job = opened_job
        else
          state.job = open_terminal()
        end
      else
        state.job = open_terminal()
      end

      if state.job then
        schedule_session_ready_fallback()
      end
    end
  end
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

function M.statusline()
  if state.job and not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return '[Codex]'
  end
  return ''
end

function M.status()
  return {
    function()
      return M.statusline()
    end,
    cond = function()
      return M.statusline() ~= ''
    end,
    icon = '',
    color = { fg = '#51afef' },
  }
end

return setmetatable(M, {
  __call = function(_, opts)
    M.setup(opts)
    return M
  end,
})
