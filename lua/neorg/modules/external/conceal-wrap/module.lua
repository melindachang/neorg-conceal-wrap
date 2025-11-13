--[[
    file: Conceal-Wrap
    title: Hard wrap text based on its concealed width
    ---

    Features:
    - Avoid joining text into headers
    - Avoid joining list items
--]]

---@alias BlockType 'header' | 'list' | 'blank' | 'text'

local neorg = require('neorg.core')
local modules, log = neorg.modules, neorg.log

local module = modules.create('external.conceal-wrap')

module.setup = function()
  return {
    success = true,
  }
end

module.load = function()
  local ns = vim.api.nvim_create_augroup('neorg-conceal-wrap', { clear = true })

  module.private.break_at = vim
    .iter(vim.split(vim.o.breakat, ''))
    :filter(function(x)
      return not vim.tbl_contains(module.config.private.no_break_at, x)
    end)
    :totable()

  vim.api.nvim_create_autocmd('BufEnter', {
    desc = 'Set the format expression on norg buffers',
    pattern = '*.norg',
    group = ns,
    callback = function(ev)
      -- set the format expression for the buffer.
      vim.api.nvim_set_option_value(
        'formatexpr',
        "v:lua.require'neorg.modules.external.conceal-wrap.module'.public.format()",
        { buf = ev.buf }
      )
    end,
  })
end

module.config.public = {}

module.config.private = {}

---Chars that we remove from break-at when wrapping lines. Break-at is global, and we don't want to
---mess with it. We will respect it until it starts to break syntax... Hmm. these are all valid in
---between words though, so maybe we could check that? Like this/that is fine, and doesn't start an
---italic section. so it would be okay to break there. Then we also have to consider when they touch
---against new lines though, that's annoying too. I think I will just remove them from breakat for
---now then.
module.config.private.no_break_at = { '.', '/', ',', '!', '-', '*', ':' }

---join lines defined by the 0 index start and end into a single line. Lines are separated by single
---spaces.
---@param buf integer
---@param start integer 0 based start
---@param _end integer 0 based exclusive end
module.private.join_lines = function(buf, start, _end)
  local og_lines = vim.api.nvim_buf_get_lines(buf, start, _end, false)
  local joined = vim
    .iter(og_lines)
    :map(function(x)
      x = x:gsub('^%s+', '')
      x = x:gsub('%s+$', '')
      return x
    end)
    :join(' ')
  vim.api.nvim_buf_set_lines(buf, start, _end, false, { joined })
end

---Function to be used as `:h 'formatexpr'` which will hard wrap text in such a way that lines will
---be `textwidth` long when conceal is active
---@return number
module.public.format = function()
  if vim.api.nvim_get_mode().mode == 'i' then
    -- Returning 1 will tell nvim to fallback to the normal format method (which is capable of
    -- handling insert mode much better than we can currently)
    -- TODO: I think the issue might be that we remove blank spaces from the end when in insert
    -- mode, which causes problems
    return 1
  end
  local buf = vim.api.nvim_get_current_buf()
  local tree, query = module.private.ts_parse_buf(buf)
  if not tree or not query then
    return 1
  end

  local current_row = vim.v.lnum - 1

  -- group the lines by header/list items, etc..
  local groups = {}
  local next_group = {}
  local lines = vim.api.nvim_buf_get_lines(
    buf,
    current_row,
    current_row + vim.v.count,
    true
  )
  for i, line in ipairs(lines) do
    local ln = i + current_row - 1
    local t = module.private.get_line_type(line)
    if not t == 'text' then
      table.insert(next_group, ln)
    else
      if #next_group > 0 then
        table.insert(groups, next_group)
      end
      next_group = (t == 'header' or t == 'list') and { ln } or {}
      if t == 'header' then
        table.insert(groups, { ln })
      end
    end
  end
  if #next_group > 0 then
    table.insert(groups, next_group)
  end

  local offset = 0
  for _, group in ipairs(groups) do
    if #group == 0 then
      goto continue
    end
    module.private.join_lines(
      buf,
      group[1] + offset,
      group[#group] + 1 + offset
    )
    local new_line_len =
      module.private.format_joined_line(buf, tree, query, group[1] + offset)
    offset = offset + (new_line_len - #group)
    ::continue::
  end

  return 0
end

---@param buf integer
---@return TSTree?, vim.treesitter.Query?
module.private.ts_parse_buf = function(buf)
  local parser = vim.treesitter.get_parser(buf)
  if not parser then
    return
  end

  local tree = parser:parse()[1]
  if not tree then
    return
  end

  local query = vim.treesitter.query.get('norg', 'highlights')
  if not query then
    return
  end

  return tree, query
end

---@param line string
---@return BlockType
module.private.get_line_type = function(line)
  if line:match('^%s*%*+%s') then
    return 'header'
  elseif line:match('^%s*[%-%~]+%s+') then
    return 'list'
  elseif line:match('^%s*$') then
    return 'blank'
  end

  return 'text'
end

---Format a single line that's been joined
---@param buf integer
---@param tree TSTree
---@param query vim.treesitter.Query
---@param line_idx integer 0 based line index
---@return integer lines the integer of lines the formatted text takes up
module.private.format_joined_line = function(buf, tree, query, line_idx)
  local ok, err = pcall(function()
    local line =
      vim.api.nvim_buf_get_lines(buf, line_idx, line_idx + 1, false)[1]
    if not line or line == '' then
      return 1
    end

    -- ---kinda like a byte index, It's just how far we are in the string of text.
    local width_limit = vim.bo.textwidth
    if width_limit == 0 then
      width_limit = 80 -- this is the value the built-in formatter defaults to when tw=0
    end

    -- account for breakindent
    vim.v.lnum = line_idx + 1
    local indent = tonumber(vim.fn.eval(vim.bo.indentexpr)) or 0
    local extra_indent = 0
    local match = line:match('^%s*([%-%~]+%s+)')
    print('match:', match)
    if match then
      extra_indent = #match + 1
      print('extra_indent:', extra_indent)
    end

    local concealed =
      module.private.get_concealed_chars(buf, tree, query, line_idx)

    local new_lines = {}
    local col_index = 0
    local first_line = true
    while col_index < #line do
      local applied_indent = first_line and indent or (indent + extra_indent)
      first_line = false

      local width = math.max(width_limit - applied_indent, 5)
      local visible_count = 0
      local last_break
      local end_col = #line - 1

      for c = col_index, end_col do
        if not concealed[c] then
          visible_count = visible_count + 1
        end

        if visible_count > width then
          break
        end

        local char = line:sub(c + 1, c + 1)
        if
          vim.list_contains(module.private.break_at, char) or char:match('%s')
        then
          last_break = c
        end
      end

      local split_at
      if visible_count <= width then
        split_at = end_col
      elseif last_break then
        split_at = last_break
      else
        split_at = math.min(col_index + width - 1, end_col)
      end

      local chunk = line:sub(col_index + 1, split_at + 1)
      chunk = (' '):rep(applied_indent) .. chunk:gsub('^%s+', '')
      chunk = chunk:gsub('%s+$', '')
      table.insert(new_lines, chunk)

      col_index = split_at + 1
      while
        col_index < #line and line:sub(col_index + 1, col_index + 1):match('%s')
      do
        col_index = col_index + 1
      end
    end

    vim.api.nvim_buf_set_lines(buf, line_idx, line_idx + 1, false, new_lines)
    return #new_lines
  end)
  if not ok then
    log.error(err)
  end
  return err
end

---Compute the (in)visible characters in a line
---@param buf integer
---@param tree TSTree
---@param query vim.treesitter.Query
---@param line_idx integer 0 based line integer
---@return boolean[]
module.private.get_concealed_chars = function(buf, tree, query, line_idx)
  local concealed = {}

  for id, node in query:iter_captures(tree:root(), buf, line_idx, line_idx + 1) do
    if query.captures[id] == 'conceal' then
      local _, start_col, _, end_col = node:range()
      for c = start_col, end_col - 1 do
        concealed[c] = true
      end
    end
  end

  return concealed
end

return module
