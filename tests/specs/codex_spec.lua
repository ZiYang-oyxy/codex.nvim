-- tests/codex_spec.lua
-- luacheck: globals describe it assert eq
-- luacheck: ignore a            -- “a” is imported but unused
local a = require 'plenary.async.tests'
local eq = assert.equals

local function reload_codex()
  package.loaded['codex'] = nil
  package.loaded['codex.state'] = nil
  return require 'codex'
end

local function normalize_path(path)
  return vim.loop.fs_realpath(path) or path
end

describe('codex.nvim', function()
  before_each(function()
    vim.cmd 'set noswapfile' -- prevent side effects
    vim.cmd 'silent! bwipeout!' -- close any open codex windows

    local state = require 'codex.state'
    state.buf = nil
    state.win = nil
    state.job = nil
  end)

  it('loads the module', function()
    local ok, codex = pcall(require, 'codex')
    assert(ok, 'codex module failed to load')
    assert(codex.open, 'codex.open missing')
    assert(codex.close, 'codex.close missing')
    assert(codex.toggle, 'codex.toggle missing')
  end)

  it('creates Codex commands', function()
    require('codex').setup { keymaps = {} }

    local cmds = vim.api.nvim_get_commands {}
    assert(cmds['Codex'], 'Codex command not found')
    assert(cmds['CodexToggle'], 'CodexToggle command not found')
    assert(cmds['CodexSendSelection'], 'CodexSendSelection command not found')
  end)

  it('opens a floating terminal window', function()
    require('codex').setup { cmd = { 'echo', 'test' } }
    require('codex').open()

    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.api.nvim_buf_get_option(buf, 'filetype')
    eq(ft, 'codex')

    require('codex').close()
  end)

  it('toggles the window', function()
    require('codex').setup { cmd = { 'echo', 'test' } }

    require('codex').toggle()
    local win1 = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win1)

    assert(vim.api.nvim_win_is_valid(win1), 'Codex window should be open')

    -- Optional: manually mark it clean
    vim.api.nvim_buf_set_option(buf, 'modified', false)

    require('codex').toggle()

    local ok, _ = pcall(vim.api.nvim_win_get_buf, win1)
    assert(not ok, 'Codex window should be closed')
  end)

  it('shows statusline only when job is active but window is not', function()
    require('codex').setup { cmd = { 'sleep', '1000' } }
    require('codex').open()

    vim.defer_fn(function()
      require('codex').close()
      local status = require('codex').statusline()
      eq(status, '[Codex]')
    end, 100)
  end)

  it('passes -m <model> to termopen when configured', function()
    local original_fn = vim.fn
    local termopen_called = false
    local received_cmd = {}

    -- Mock vim.fn with proxy
    vim.fn = setmetatable({
      termopen = function(cmd, opts)
        termopen_called = true
        received_cmd = cmd
        if type(opts.on_exit) == 'function' then
          vim.defer_fn(function()
            opts.on_exit(0)
          end, 10)
        end
        return 123
      end,
    }, { __index = original_fn })

    -- Reload module fresh
    local codex = reload_codex()

    codex.setup {
      cmd = 'codex',
      model = 'o3-mini',
    }

    codex.open()

    vim.wait(500, function()
      return termopen_called
    end, 10)

    assert(termopen_called, 'termopen should be called')
    assert(type(received_cmd) == 'table', 'cmd should be passed as a list')
    assert(vim.tbl_contains(received_cmd, '-m'), 'should include -m flag')
    assert(vim.tbl_contains(received_cmd, 'o3-mini'), 'should include specified model name')

    -- Restore original
    vim.fn = original_fn
  end)

  it('uses cmd list as command arguments', function()
    local original_fn = vim.fn
    local received_cmd = nil

    vim.fn = setmetatable({
      termopen = function(cmd, opts)
        received_cmd = cmd
        if type(opts.on_exit) == 'function' then
          vim.defer_fn(function()
            opts.on_exit(0)
          end, 10)
        end
        return 321
      end,
    }, { __index = original_fn })

    local codex = reload_codex()
    codex.setup {
      cmd = { 'echo', 'from-cmd' },
      autoinstall = false,
    }

    codex.open()

    vim.wait(500, function()
      return received_cmd ~= nil
    end, 10)

    assert(type(received_cmd) == 'table', 'cmd should be passed as list')
    eq(received_cmd[1], 'echo')
    eq(received_cmd[2], 'from-cmd')

    vim.fn = original_fn
  end)

  it('keeps process cwd when cwd_from_buffer is false', function()
    local original_fn = vim.fn
    local received_cwd = nil

    vim.fn = setmetatable({
      termopen = function(_, opts)
        received_cwd = opts.cwd
        if type(opts.on_exit) == 'function' then
          vim.defer_fn(function()
            opts.on_exit(0)
          end, 10)
        end
        return 222
      end,
    }, { __index = original_fn })

    vim.cmd 'enew'

    local codex = reload_codex()
    codex.setup {
      cmd = { 'echo', 'test' },
      cwd_from_buffer = false,
    }

    codex.open()

    vim.wait(500, function()
      return received_cwd ~= nil
    end, 10)

    eq(received_cwd, vim.loop.cwd())
    vim.fn = original_fn
  end)

  it('uses current buffer directory when cwd_from_buffer is true', function()
    local original_fn = vim.fn
    local received_cwd = nil

    vim.fn = setmetatable({
      termopen = function(_, opts)
        received_cwd = opts.cwd
        if type(opts.on_exit) == 'function' then
          vim.defer_fn(function()
            opts.on_exit(0)
          end, 10)
        end
        return 223
      end,
    }, { __index = original_fn })

    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, 'p')
    local file_path = temp_dir .. '/cwd_test.lua'
    vim.fn.writefile({ 'print("hello")' }, file_path)
    vim.cmd('edit ' .. vim.fn.fnameescape(file_path))

    local codex = reload_codex()
    codex.setup {
      cmd = { 'echo', 'test' },
      cwd_from_buffer = true,
    }

    codex.open()

    vim.wait(500, function()
      return received_cwd ~= nil
    end, 10)

    eq(normalize_path(received_cwd), normalize_path(temp_dir))
    vim.fn = original_fn
  end)

  it('falls back to process cwd when buffer has no file path', function()
    local original_fn = vim.fn
    local received_cwd = nil

    vim.fn = setmetatable({
      termopen = function(_, opts)
        received_cwd = opts.cwd
        if type(opts.on_exit) == 'function' then
          vim.defer_fn(function()
            opts.on_exit(0)
          end, 10)
        end
        return 224
      end,
    }, { __index = original_fn })

    vim.cmd 'enew'

    local codex = reload_codex()
    codex.setup {
      cmd = { 'echo', 'test' },
      cwd_from_buffer = true,
    }

    codex.open()

    vim.wait(500, function()
      return received_cwd ~= nil
    end, 10)

    eq(received_cwd, vim.loop.cwd())
    vim.fn = original_fn
  end)

  it('sends payload via actions.send and respects submit option', function()
    local codex = reload_codex()
    codex.setup { cmd = { 'echo', 'test' } }

    local original_fn = vim.fn
    local sent = {}

    vim.fn = setmetatable({
      chansend = function(_, payload)
        sent[#sent + 1] = payload
        return 1
      end,
    }, { __index = original_fn })

    local state = require 'codex.state'
    state.job = 999

    local ok_plain = codex.actions.send('hello')
    local ok_submit = codex.actions.send('world', { submit = true })

    assert(ok_plain, 'send should succeed without submit')
    assert(ok_submit, 'send should succeed with submit')
    eq(sent[1], 'hello')
    eq(sent[2], 'world\n')

    vim.fn = original_fn
  end)

  it('send_selection builds payload and calls actions.send', function()
    local codex = reload_codex()
    codex.setup { cmd = { 'echo', 'test' } }

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_name(buf, vim.loop.cwd() .. '/selection_test.lua')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'alpha',
      'beta',
      'gamma',
    })

    local original_fn = vim.fn
    vim.fn = setmetatable({
      mode = function()
        return 'v'
      end,
      visualmode = function()
        return 'v'
      end,
      getpos = function(mark)
        if mark == 'v' then
          return { 0, 1, 1, 0 }
        end
        return { 0, 2, 4, 0 }
      end,
      fnamemodify = original_fn.fnamemodify,
      isdirectory = original_fn.isdirectory,
    }, { __index = original_fn })

    local captured_payload = nil
    local captured_submit = nil
    local original_send = codex.actions.send
    codex.actions.send = function(payload, opts)
      captured_payload = payload
      captured_submit = opts and opts.submit
      return true
    end

    local ok = codex.actions.send_selection()

    assert(ok, 'send_selection should succeed')
    assert(captured_payload:find('File: selection_test.lua:1%-2', 1, false), 'payload should include file and line range')
    assert(captured_payload:find('alpha\nbet', 1, true), 'payload should include selected text')
    eq(captured_submit, false)

    codex.actions.send = original_send
    vim.fn = original_fn
  end)

  it('send_selection returns false when selection is empty', function()
    local codex = reload_codex()
    codex.setup { cmd = { 'echo', 'test' } }

    local original_fn = vim.fn
    vim.fn = setmetatable({
      mode = function()
        return 'v'
      end,
      visualmode = function()
        return 'v'
      end,
      getpos = function()
        return { 0, 0, 0, 0 }
      end,
    }, { __index = original_fn })

    local called = false
    local original_send = codex.actions.send
    codex.actions.send = function()
      called = true
      return true
    end

    local ok = codex.actions.send_selection()
    assert(not ok, 'send_selection should fail on empty selection')
    assert(not called, 'actions.send should not be called for empty selection')

    codex.actions.send = original_send
    vim.fn = original_fn
  end)
end)
