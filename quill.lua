-- Small text editor inspired by Nano for CraftOS
--[[Copyright 2026 Alexander Osipov

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the “Software”), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished to do so, subject
to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.]]

-- Default terminal colors
default_colors = {
  fg = term.getTextColor(),
  bg = term.getBackgroundColor()
}

-- COMMON FUNCTION SECTION

-- Invert the terminal's color scheme
function invertTermColors(state)
  if state then
    term.setBackgroundColor(default_colors.fg)
    term.setTextColor(default_colors.bg)
  else
    term.setBackgroundColor(default_colors.bg)
    term.setTextColor(default_colors.fg)
  end
end

-- Write aligned text in the terminal
function writeAligned(text, alignment)
  local screen_width = term.getSize()
  local text_width = #text
  local cursor = {term.getCursorPos()}
  if alignment == 'center' then
    cursor[1] = math.floor((screen_width - text_width) / 2)
  elseif alignment == 'right' then
    cursor[1] = screen_width - text_width
  end
  term.setCursorPos(table.unpack(cursor))
  term.write(text)
end

-- Split text at the provided position or character
function split(text, delim)
  local result = {}
  if type(delim) == 'string' then
    -- Split by position
    local pos = text:find(delim)
    while pos do
      table.insert(result, text:sub(1, pos - 1))
      text = text:sub(pos + 1)
      pos = text:find(delim)
    end
    -- Insert the leftover of text
    if #text > 0 then
      table.insert(result, text)
    end
  else
    result[1] = text:sub(1, delim)
    result[2] = text:sub(delim + 1)
  end
  return result
end

-- END OF COMMON FUNCTIONS

-- Modifier key control
mod_pressed = {
  ctrl = false,
  shift = false,
  alt = false
}

-- File buffers
-- Each buffer is a table of line strings with numeric indices.
-- Two special indices are used in the buffer table:
-- 'name' = buffer name
-- 'path' = save path
-- 'cursor' = cursor position: {x = 1, y = 1}
-- 'viewport' = viewport offset: {x = 1, y = 1}
-- 'modified' = boolean indicating if the buffer has unsaved changes
-- 'is_new' = the buffer belongs to a new/non-existing file
-- 'mime' = MIME type detected from file name or content
-- 'indent' = sub-table to describe indentation settings for the file buffer
file_buffers = {}

-- Index of the current text buffer
file_buffers.current = 0

-- Clipboard / kill ring
-- A multi-slot clipboard for copied/cut text (do not confuse with the host OS clipboard).
-- Kill ring entites have the same structure as file buffers but they do not contain 'special' fields.
kill_ring = {}

-- Maximum length of the kill ring
KILL_RING_MAX_LENGTH = 1


-- Main interface table
local ui = {
  -- Interface header
  prog_name = "Quill 0.1",  -- Program name
  -- Main section
  text = nil,  -- Displayed text buffer
  -- Interface footer
  input = "",  -- Input line content
  input_invition = "", -- User input invition
  -- Input line mode:
  -- * 'label' = show a label in the input line,
  -- * 'text' = text input,
  -- * 'prompt' = yes/no prompt  
  input_mode = 'label',
  -- Input cursor position (X only)
  input_cursor = 1,
  -- Keyboard hints: {line1, line2}
  -- Line content: {{'^X', 'Exit'}, {'^G', 'Help'}, ...}
  key_hints = {{}, {}},
  -- Show keyboard hints?
  show_key_hints = true
}

-- Selection mark table
ui.selection = {
  state = 'unset', -- 'unset', 'changed' or 'set'
  x1 = 1, y1 = 1,  -- first position
  x2 = 1, y2 = 1   -- second position
}

-- Create a new empty file buffer
function file_buffers.new()
  local buf = {
    name = "Untitled",
    path = nil,
    cursor = {x = 1, y = 1},
    viewport = {x = 1, y = 1},
    modified = false,
    is_new = true,
    mime = "text/plain",
    indent = {
        char = ' ',  -- Indent character: ' ' or '\t'
        width = 2,   -- Width of one indent
        auto = true  -- Enable auto-indentation
    }
  }
  -- Add a blank line
  buf[1] = ""
  -- Insert the buffer into file_buffers and return it
  table.insert(file_buffers, buf)
  if file_buffers.current == 0 then
    file_buffers.current = #file_buffers
  end
  return buf
end

-- Count the total width of indent in characters
function file_buffers.indentLen(indent)
    if indent == nil then
        return 0
    end
    return #indent.char * indent.width * indent.count
end

-- Get type and number of indents in selected line
function file_buffers.getIndent(buf, y)
  if y < 1 then
    return nil
  end
  local b, e, s = buf[y]:find('^(%s*)')  -- Find line's first indents
  if b == nil then
    return nil -- No indent in this line 
  end
  local s_len = e - b + 1  -- same as #s
  local indent = {char = s:sub(1, 1)}
  if indent.char == '\t' then
    indent.width = 1
    indent.count = s_len
  elseif buf.indent.char == ' ' then
    -- NOTE: the default and minimal space indent width is equal to 2.
    -- On file openning, space indent width should be determinated by comparing with other lines.
    indent.width = math.max(buf.indent.width, 2)
    indent.count = math.floor(s_len / indent.width)
  else
    -- This case is possible if the previous author mixed up tabs and spaces
    indent.width = 4  -- Tab is usually assumed to be as wide as 4 spaces
    indent.count = math.floor(s_len / 4)
  end
  return indent
end

-- Create a new file buffer from an existing file
function file_buffers.load(path, new_on_error)
  -- Split the path to determine the file name
  local path_s = split(path, '/')
  -- Create an empty buffer
  local buf = file_buffers.new()
  -- Insert file lines into the buffer
  local file, err = io.open(path, 'r')
  if not file then
    if new_on_error then
      buf.path = path
      buf.name = path_s[#path_s]
      return true, nil
    else
      return false, err
    end
  else
    buf[1] = nil -- Clear the blank line
    local least_indent
    for line in file:lines() do
      table.insert(buf, line)
      local indent = file_buffers.getIndent(buf, #buf)
      if indent and indent.count > 0 then
        if not least_indent or indent.width * indent.count < least_indent.width * least_indent.count then
          least_indent = indent
        end
      end
    end
    file:close()
    buf.is_new = false
    buf.path = path
    buf.name = path_s[#path_s]
    if #buf == 0 then
      -- Return the blank line if file is empty
      buf[1] = ""
    elseif least_indent then
      -- Change the indent style from gathered data
      buf.indent.char = least_indent.char
      if buf.indent.char == ' ' then
          buf.indent.width = math.min(buf.indent.width * least_indent.count, 8)
      else
          buf.indent.width = 1
      end
    end
    -- Determine the MIME type
    buf.mime = file_buffers.guessMimeType(buf)
    -- Move the cursor and viewport to the last line
    local text_height = select(2, term.getSize()) - 2
    if ui.show_key_hints then
      text_height = text_height - 2
    end
    buf.cursor.y = #buf
    buf.viewport.y = math.max(1, buf.cursor.y - text_height + 1)
    return true, nil
  end
end

-- Save the file_buffer content
function file_buffers.save(buf)
  local file, err = io.open(buf.path, 'w')
  if not file then
    return file, err
  end
  file, err = file:write(table.concat(buf, '\n'))
  file:flush()
  file:close()
  if err then
    return false, err
  end
  -- Update the MIME type
  buf.mime = file_buffers.guessMimeType(buf)
  return true, nil
end

-- Determine the MIME type from its extension or content
function file_buffers.guessMimeType(buf)
  -- TODO: content analysis
  if buf.name then
    local ext = buf.name:lower():match("%.(%w+)$")
    if ext == nil or ext == "lua" then
      -- Lua files in ComputerCraft may have no extension
      return "text/x-lua"
    end
  end
  return "text/plain"  -- Fallback option
end

-- Return the least and greatest position of the selection
function ui.selection.points()
  local x1, y1 = ui.selection.x1, ui.selection.y1
  local x2, y2 = ui.selection.x2, ui.selection.y2
  if y2 < y1 or (y2 == y1 and x2 < x1) then
    return {x = x2, y = y2}, {x = x1, y = y1}
  else
    return {x = x1, y = y1}, {x = x2, y = y2}
  end
end

-- Determine if the cursor is focused on the input line or the file buffer
function ui.cursorTarget()
  if ui.input_mode == 'label' then
    return 'buffer'
  end
  return 'input'
end

-- Draw/update the interface
function ui.draw()
  -- Get current terminal size
  local screen_width, screen_height = term.getSize()
  local buf = file_buffers[file_buffers.current]
  -- Clear the terminal
  term.clear()
  term.setCursorPos(1, 1)
  -- Draw the header line
  invertTermColors(true)
  term.clearLine() -- Fill the line with the text color
  term.setCursorPos(1, 1)
  term.write(ui.prog_name)
  local title = buf.name
  if buf.is_new then
    title = title .. "*[NEW]"
  elseif buf.modified then
    title = title .. '*'
  end
  writeAligned(title, 'right')
  invertTermColors(false)
  -- Draw the current text buffer
  local text_height = screen_height - 2
  if ui.show_key_hints then
    text_height = text_height - 2
  end
  for y = 1, text_height do
    local i = buf.viewport.y + y - 1
    if i > #buf then
      break
    end
    term.setCursorPos(1, y + 1)
    if ui.selection.state == 'unset' then
      term.write(buf[i])
    else
      local sel_start, sel_end = ui.selection.points()
      if i == sel_start.y then
        local s = split(buf[i], sel_start.x - 1)
        term.write(s[1])
        invertTermColors(true)
        if sel_start.y == sel_end.y then
          s = split(buf[i], sel_end.x)
          term.write(s[1]:sub(sel_start.x))
          invertTermColors(false)
          term.write(s[2])
        else
          term.write(s[2])
          invertTermColors(false)
        end
      elseif i == sel_end.y then
        local s = split(buf[i], sel_end.x - 1)
        invertTermColors(true)
        term.write(s[1])
        invertTermColors(false)
        term.write(s[2])
      elseif i > sel_start.y and i < sel_end.y then
        invertTermColors(true)
        term.write(buf[i])
        invertTermColors(false)
      else
        term.write(buf[i])
      end
    end
  end
  -- Draw the footer
  term.setCursorPos(1, screen_height - 2)
  invertTermColors(true)
  local input_line = ui.input
  if ui.input_mode == 'label' then
    if input_line and #input_line > 0 then
      writeAligned(input_line, 'center') -- TODO: input line
    end
  else
    term.clearLine()
    if ui.input_invition and #ui.input_invition > 0 then
      input_line = ui.input_invition .. ' ' .. input_line      
    end
    term.write(input_line)
  end
  invertTermColors(false)
  if ui.show_key_hints then
    for y, hints in ipairs(ui.key_hints) do
      for x, hint in ipairs(hints) do
        local x_pos = 1 + (x - 1) * 8
        if x_pos + 2 + math.min(#hint[2], 5) > screen_width then
          break
        end
        term.setCursorPos(x_pos, screen_height - 2 + y)
        invertTermColors(true)
        term.write(hint[1])
        invertTermColors(false)
        term.write(' ' .. hint[2]:sub(1, 5))
      end
    end
  end
  -- Set cursor position
  local target = ui.cursorTarget()
  if target == 'buffer' then
    local cursor_x = buf.cursor.x - buf.viewport.x + 1
    local cursor_y = buf.cursor.y - buf.viewport.y + 2
    -- TODO: Correct visual cursor position for wide characters like tabs
    term.setCursorPos(cursor_x, cursor_y)
    term.setCursorBlink(true)
  elseif target == 'input' then
    local cursor_x = #input_line - #ui.input + ui.input_cursor
    term.setCursorPos(cursor_x, screen_height - 2)
    term.setCursorBlink(true)
  else
    term.setCursorBlink(false)
  end
end

-- Enter a character into the input line or the current buffer
function ui.enterChar(ch, pos)
  local target = ui.cursorTarget()
  if target == 'input' then
    if pos == nil then
      pos = {x = ui.input_cursor, y = 1}
    end
    if ch == '\n' then
      -- Request for input processing
      return false, target
    elseif ch == '\t' then
      -- Ignore indents/tabs in input line
      return false, target
    else
      local s = split(ui.input, pos.x - 1)
      ui.input = s[1] .. ch .. s[2]
      return true, target
    end
  elseif target == 'buffer' then
    local buf = file_buffers[file_buffers.current]
    if pos == nil then
      pos = buf.cursor
    end
    local s = split(buf[pos.y], pos.x - 1)
    if ch == '\n' then
      buf[pos.y] = s[1]
      ui.insertLine(buf, pos.y + 1, s[2])
      return true, target
    elseif ch == '\t' then
      if buf.indent.char ~= '\t' then
        local w = buf.indent.width
        ch = string.rep(buf.indent.char, w - (pos.x - 1) % w)
      end
      buf[pos.y] = s[1] .. ch .. s[2]
      buf.modified = true
      return true, target
    else
      buf[pos.y] = s[1] .. ch .. s[2]
      buf.modified = true
      return true, target
    end
  end
  return false, target
end

-- Remove N characters in the input line or the current buffer
-- If N < 0 then removal goes backwards
function ui.deleteChar(n, pos)
  local target = ui.cursorTarget()
  if target == 'input' then
    if pos == nil then
      pos = {x = ui.input_cursor, y = 1}
    end
    local s = split(ui.input, pos.x - 1)
    if n < 0 then
      local new_s1 = s[1]:sub(1, n - 1)
      ui.input = new_s1 .. s[2]
      return (s[1] ~= new_s1), target
    else
      local new_s2 = s[2]:sub(n + 1)
      ui.input = s[1] .. new_s2
      return (s[2] ~= new_s2), target
    end
  elseif target == 'buffer' then
    local buf = file_buffers[file_buffers.current]
    if pos == nil then
      pos = buf.cursor
    end
    local s = split(buf[pos.y], pos.x - 1)
    if n < 0 then
      local new_s1 = s[1]:sub(1, n - 1)
      buf[pos.y] = new_s1 .. s[2]
      if pos.x + n < 1 and pos.y > 1 then
        -- Line removal
        buf[pos.y - 1] = buf[pos.y - 1] .. buf[pos.y]
        table.remove(buf, pos.y)
        buf.modified = true
        if n < -1 then
            pos.y = pos.y - 1
            pos.x = #buf[pos.y]
            return ui.deleteChar(n + 1, pos)
        end
        return true, 'buffer'
      end
      buf.modified = buf.modified or (s[1] ~= new_s1)
      return (s[1] ~= new_s1), target
    else
      local new_s2 = s[2]:sub(n + 1)
      buf[pos.y] = s[1] .. new_s2
      if pos.x + n > #buf[pos.y] and pos.y < #buf then
        -- Line removal
        buf[pos.y] = buf[pos.y] .. buf[pos.y + 1]
        table.remove(buf, pos.y + 1)
        buf.modified = true
        return true, 'buffer'
      end
      buf.modified = buf.modified or (s[2] ~= new_s2)
      return (s[2] ~= new_s2), target
    end
  end
  return false, target
end

-- Insert a new line into the provided Y position
function ui.insertLine(buf, y, content)
  local indent = file_buffers.getIndent(buf, y - 1)
  table.insert(buf, y, content or "")
  if indent then
    if buf.mime == "text/x-lua" then
      -- Primitive auto-indentation for Lua files
      local prev_indent = file_buffers.getIndent(buf, y - 2)
      local prev_line = buf[y - 1]:lower()
      local first_word = prev_line:match("^%s*(%w+)")
      local last_word = prev_line:match("%w+$")
      if first_word == "function" or first_word == "repeat" then
        indent.count = indent.count + 1
      elseif last_word == "else" or last_word == "do" then
        indent.count = indent.count + 1
      elseif last_word == "then" then
        if first_word == "if" then
          indent.count = indent.count + 1
        elseif first_word == "elseif" then
          if prev_indent and prev_indent.count > indent.count then
            -- 'esleif' is already un-indented manually
            indent.count = indent.count + 1
          else
            -- 'elseif' must be un-indented while the new line must have
            -- the same indentation as the previous code block
            ui.deleteIndent(buf, y - 1)
          end
        end
      elseif last_word == "end" or first_word == "until" then
        if prev_indent and indent.count >= prev_indent.count then
          ui.deleteIndent(buf, y - 1)
        end
        indent.count = math.max(indent.count - 1, 0)
      end
    end
    indent = string.rep(indent.char, indent.width * indent.count)
    buf[y] = indent .. buf[y]
  end
  buf.modified = true
end

-- Un-indent the indexed line
function ui.deleteIndent(buf, y)
  local old_cursor = {x = buf.cursor.x, y = buf.cursor.y}
  local indent = file_buffers.getIndent(buf, y)
  if indent and indent.count > 0 then
    buf.cursor.x = file_buffers.indentLen(indent) + 1
    buf.cursor.y = y
    ui.deleteChar(-indent.width * #indent.char)
    buf.cursor = old_cursor
    return true
  end
  return false
end

-- Move the cursor to the beginning or the end of the current line
function ui.moveCursorX(buf, pos)
  local screen_width = term.getSize()
  local target = ui.cursorTarget()
  if pos == 'begin' then
    if target == 'buffer' then
      local indent = file_buffers.getIndent(buf, buf.cursor.y)
      buf.cursor.x = file_buffers.indentLen(indent) + 1
      if buf.viewport.x >= screen_width then
        buf.viewport.x = 1
      end
    elseif target == 'input' then
      ui.input_cursor = 1
    end
  elseif pos == 'end' then
    if target == 'buffer' then
      buf.cursor.x = #buf[buf.cursor.y] + 1
      if buf.cursor.x >= buf.viewport.x + screen_width then
        buf.viewport.x = buf.cursor.x - math.floor(screen_width / 2)
      end
    elseif target == 'input' then
      ui.input_cursor = #ui.input + 1
    end
  elseif type(pos) == 'number' then
    if target == 'buffer' then
      buf.cursor.x = pos
      -- TODO: fit the viewport to the arbirary position
    elseif target == 'input' then
      ui.input_cursor = pos
    end
  else
    error("Invalid cursor position")
  end
end

-- Make an input dialogue
-- mode - input mode;
-- invition - input invition;
-- handler - object with a function to process input from interface.input
-- or a key combination provided in the arguments and return
-- dialog closing flag and a status line or a new invition line,
-- for example:
-- function handler.onKey(key)
-- if mod_pressed.ctrl and key == keys.c then
--   return true, "Aborted"
-- elseif mod_pressed.alt and key == keys.a then
--   return false, "Append to file:"
-- elseif key == keys.enter then
--   return true, "Saved"
-- end
-- end
-- key_hints - dialog key hints
function ui.dialog(mode, invition, handler, key_hints)
  ui.input_mode = mode
  ui.input_invition = invition
  ui.input_handler = handler
  ui.key_hints = key_hints
end

-- Set the default key hints
function ui.resetKeyHints()
  ui.key_hints = {
    {{'^G', 'Help'}, {'^O', 'Save'}, {'mA', 'Mark'}},
    {{'^X', 'Exit'}, {'^L', 'Load'}}
  }
end

-- Clean up the terminal after the program exit
function ui.cleanUp()
  term.clear()
  term.setCursorPos(1, 1)
end

-- Read event handler
load_input_handler = {}
function load_input_handler.onKey(key)
  -- TODO: Append to the cureent buffer and reading into a new buffer
  if mod_pressed.ctrl and key == keys.c then
    return true, 'Aborted'
  elseif key == keys.enter then
    local ok, msg = file_buffers.load(ui.input)
    if ok then
      -- Currently, we just replace the current buffer with the new one
      file_buffers[1] = file_buffers[2]
      file_buffers[2] = nil
      return true, string.format("%d line(s) read", #file_buffers[1])
    else
      local s = split(msg, ': ')
      return true, 'Error reading:' .. table.concat(s, ': ', 2)
    end
  end
  return false, nil  -- Prevent the dialog from closing
end

-- Save event handler
save_input_handler = {}
function save_input_handler.onKey(key)
  local buf = file_buffers[file_buffers.current]
  local old_path = buf.path
  if mod_pressed.ctrl and key == keys.c then
    return true, 'Aborted'
  elseif key == keys.enter then
    buf.path = ui.input
    buf.name = split(buf.path, '/')  -- Use buf.name as a split buffer
    buf.name = buf.name[#buf.name]
    local ok, msg = file_buffers.save(buf)
    if ok then
      buf.modified = false
      buf.is_new = false
      return true, string.format("[%d line(s) written in %s]", #buf, buf.path)
    else
      buf.path = old_path
      local s = split(msg, ': ')
      return true, 'Error saving:' .. table.concat(s, ': ', 2)
    end
  end
  return false, nil  -- Prevent the dialog from closing
end

-- Default input handler
ui.default_input_handler = {
  exit_prompt = false
}
function ui.default_input_handler.onKey(key)
  local screen_width, screen_height = term.getSize()
  local buf = file_buffers[file_buffers.current]
  -- Local function to activate the save input handler
  local function gotoSave()
    ui.input = buf.path or ""
    ui.input_cursor = #ui.input + 1
    ui.dialog('text', 'Write to file:', save_input_handler,
    {{{'^C', 'Abort'}}, {}})
  end
  -- Key processing
  if ui.default_input_handler.exit_prompt then
    ui.default_input_handler.exit_prompt = false
    if key == keys.y then
      if buf.path then
        local ok, err = file_buffers.save(buf)
        if ok then
          return true, nil -- Normal exit
        else
          local s = split(msg, ': ')
          ui.input_mode = 'label'
          ui.input = 'Error saving:' .. table.concat(s, ': ', 2)
          return false, ui.input
        end
      else
        gotoSave()
      end
    elseif key == keys.n then
      return true, nil -- Normal exit
    elseif mod_pressed.ctrl and key == keys.c then
      ui.input_mode = 'label'
      ui.input = "Aborted"
      ui.resetKeyHints()
      return false, "Aborted"
    end
  elseif mod_pressed.ctrl then
    if key == keys.x then
      if buf.modified then
        -- Exit prompt
        ui.default_input_handler.exit_prompt = true
        ui.input = ''
        ui.input_cursor = 1
        ui.input_mode = 'prompt'
        ui.key_hints = {{{'Y', "Yes"}}, {{'N', "No"}, {"^C", "Abort"}}}
        return false, "Save changes before exit?"
      end
      return true, nil -- Normal exit
    elseif key == keys.g then
      -- TODO: Show help
      ui.input = "Not implemented"
    elseif key == keys.l then
      ui.input = ""
      ui.input_cursor = 1
      ui.dialog('text', 'Read from file:', load_input_handler,
      {{{'^C', 'Abort'}}, {}})
    elseif key == keys.o then
      gotoSave()
    end
  elseif mod_pressed.alt then
    if key == keys.a then
      if ui.selection.state == 'unset' then
        ui.selection.state = 'changed'
        ui.selection.x1 = buf.cursor.x
        ui.selection.y1 = buf.cursor.y
        ui.selection.x2 = buf.cursor.x
        ui.selection.y2 = buf.cursor.y
        ui.input = "Mark set"
      else
        ui.selection.state = 'unset'
        ui.input = "Mark unset"
      end
    end
  end
end
ui.input_handler = ui.default_input_handler


-- Main code
local start_ok = true
if arg[1] == nil then
  file_buffers.new()
else
  local ok, err = file_buffers.load(arg[1], true)
  if not ok then
    printError(err)
    start_ok = false
  end
end

-- Interface initialization
if start_ok then
  ui.resetKeyHints()
  ui.draw()

  -- Event loop
  while true do
    local screen_width, screen_height = term.getSize()
    local text_height = screen_height - 2
    if ui.show_key_hints then
      text_height = text_height - 2
    end
    local buf = file_buffers[file_buffers.current]
    local event = {os.pullEventRaw()}
    local target = ui.cursorTarget()
    if event[1] == "terminate" then
      break  -- Program termination
    elseif event[1] == "char" and not (mod_pressed.ctrl or mod_pressed.alt) then
      local ch = event[2]
      if target == 'buffer' then
        ui.selection.state = 'unset'
        ui.enterChar(ch)
        buf.cursor.x = buf.cursor.x + 1
        if buf.cursor.x >= screen_width then
          buf.viewport.x = buf.viewport.x + 1
        end
      elseif ui.input_mode == 'prompt' then
        -- Let the key event handler to do the job
      else
        ui.enterChar(ch)
        ui.input_cursor = ui.input_cursor + 1
      end
    elseif event[1] == 'key' then
      local key, is_held = event[2], event[3]
      if key == keys.leftCtrl or key == keys.rightCtrl then
        mod_pressed.ctrl = true
      elseif key == keys.leftAlt or key == keys.rightAlt then
        mod_pressed.alt = true
      elseif key == keys.leftShift or key == keys.rightShift then
        mod_pressed.shift = true
      else
        if key == keys.enter then
          ui.enterChar('\n')
          if target == 'buffer' then
            ui.selection.state = 'unset'
            buf.cursor.y = buf.cursor.y + 1
            if buf.cursor.y >= buf.viewport.y + text_height then
              buf.viewport.y = buf.viewport.y + 1
            end
            local indent = file_buffers.getIndent(buf, buf.cursor.y)
            if indent and indent.count > 0 then
              ui.moveCursorX(buf, file_buffers.indentLen(indent) + 1)
            else
              ui.moveCursorX(buf, "begin")
            end
          elseif target == 'input' then
            -- Let the input handler to do the job
          end
        elseif key == keys.tab then
          if target == 'buffer' then
            ui.selection.state = 'unset'
            if mod_pressed.shift then
              if ui.deleteIndent(buf, buf.cursor.y) then
                ui.moveCursorX(buf, buf.cursor.x - buf.indent.width)
              end
            else
              ui.enterChar('\t')
              ui.moveCursorX(buf, buf.cursor.x + buf.indent.width)
            end
          else
            ui.enterChar('\t')
          end
        elseif key == keys.backspace then
          local old_prev_line_len = (buf.cursor.y > 1 and #buf[buf.cursor.y - 1] or 0)
          ui.deleteChar(-1)
          if target == 'buffer' then
            ui.selection.state = 'unset'
            if buf.cursor.x > 1 then
              buf.cursor.x = buf.cursor.x - 1
            elseif buf.cursor.y > 1 then
              buf.cursor.y = buf.cursor.y - 1
              buf.cursor.x = old_prev_line_len + 1
            end
          else
            ui.input_cursor = math.max(ui.input_cursor - 1, 1)
          end
        elseif key == keys.delete then
          ui.deleteChar(1)
        elseif key == keys.up then
          if target == 'buffer' then
            buf.cursor.y = math.max(buf.cursor.y - 1, 1)
            if buf.cursor.y < buf.viewport.y then
              buf.viewport.y = buf.viewport.y - 1
            end
            if buf.cursor.x > #buf[buf.cursor.y] then
              ui.moveCursorX(buf, 'end')
            end
          else
            -- TODO: Input history browsing
          end
        elseif key == keys.down then
          if target == 'buffer' then
            buf.cursor.y = math.min(buf.cursor.y + 1, #buf)
            if buf.cursor.y >= buf.viewport.y + text_height then
              buf.viewport.y = buf.viewport.y + 1
            end
            if buf.cursor.x > #buf[buf.cursor.y] then
              ui.moveCursorX(buf, 'end')
            end
          elseif target == 'input' then
            -- TODO: Input history browsing
          end
        elseif key == keys.left then
          if target == 'buffer' then
            if buf.cursor.x > 1 then
              buf.cursor.x = buf.cursor.x - 1
            else
              buf.cursor.y = math.max(buf.cursor.y - 1, 1)
              ui.moveCursorX(buf, 'end')
            end
          elseif target == 'input' then
            ui.input_cursor = math.max(ui.input_cursor - 1, 1)
          end
        elseif key == keys.right then
          if target == 'buffer' then
            if buf.cursor.x < #buf[buf.cursor.y] + 1 then
              buf.cursor.x = buf.cursor.x + 1
            else
              buf.cursor.y = math.min(buf.cursor.y + 1, #buf)
              ui.moveCursorX(buf, 'begin')
            end
          elseif target == 'input' then
            ui.input_cursor = math.min(ui.input_cursor + 1, #ui.input + 1)
          end
        elseif key == keys.home then
          ui.moveCursorX(buf, 'begin')
        elseif key == keys['end'] then  -- Dot syntax does not work correctly with 'end'
          ui.moveCursorX(buf, 'end')
        elseif ui.input_handler == nil then
          printError("No input handler attached")
          break
        end
        -- Move the selection anchor on 'changed' mode
        if ui.selection.state == 'changed' and target == 'buffer' then
          ui.selection.x2 = buf.cursor.x
          ui.selection.y2 = buf.cursor.y
        end
        -- Call the input handler
        local close, status = ui.input_handler.onKey(key)
        if close then
          if ui.input_handler == ui.default_input_handler then
            -- Exit from interface.default_input_handler finishes the program 
            if status then
              printError(status)
            end
            break
          else
            ui.input = status or ""
            ui.dialog('label', '', ui.default_input_handler)
            ui.resetKeyHints()
          end
        elseif status ~= nil then
          ui.input_invition = status
        end
      end
    elseif event[1] == 'key_up' then
      local key = event[2]
      if key == keys.leftCtrl or key == keys.rightCtrl then
        mod_pressed.ctrl = false
      elseif key == keys.leftAlt or key == keys.rightAlt then
        mod_pressed.alt = false
      elseif key == keys.leftShift or key == keys.rightShift then
        mod_pressed.shift = false
      end
    end
    ui.draw()
  end
  ui.cleanUp()
end
