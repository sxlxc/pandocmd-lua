local util = require("util")

local M = {}

local source_line_marker_pattern = "<!%-%- pandocmd%-source%-line:%d+ %-%->"
local source_line_marker_lf_pattern = "[ \t]*" .. source_line_marker_pattern .. "\n"
local source_line_marker_crlf_pattern = "[ \t]*" .. source_line_marker_pattern .. "\r\n"

local function leading_indent(line)
  -- Capture all whitespace from the beginning of the line.
  return line:match("^(%s*)")
end

local function strip_leading_space(line)
  -- Remove one or more whitespace characters from the beginning of the line.
  return line:gsub("^%s+", "")
end

local function marker_line(line_no, line)
  return leading_indent(line) .. "<!-- pandocmd-source-line:" .. tostring(line_no) .. " -->"
end

local function opens_code_fence(line)
  local stripped = strip_leading_space(line)
  local c = stripped:sub(1, 1)
  if c ~= "`" and c ~= "~" then
    return nil
  end
  -- Match a run of backticks or tildes at the beginning of the stripped line.
  local fence = stripped:match("^" .. c .. "+")
  if fence and #fence >= 3 then
    return fence
  end
  return nil
end

local function closes_code_fence(fence, line)
  local c = fence:sub(1, 1)
  local stripped = strip_leading_space(line)
  -- Match the closing run of the same fence character at line start.
  local closing = stripped:match("^" .. c .. "+") or ""
  local rest = stripped:sub(#closing + 1)
  -- A closing fence must be at least as long as the opening fence and followed only by whitespace.
  return #closing >= #fence and rest:match("^%s*$") ~= nil
end

local display_math_openers = {
  -- Check the double-backslash form before the single-backslash form.
  { opening = "\\\\[", closing = "\\\\]" },
  { opening = "\\[", closing = "\\]" },
  { opening = "$$", closing = "$$", respects_escapes = true },
}

local function is_escaped(line, pos)
  local backslashes = 0
  pos = pos - 1
  while pos >= 1 and line:sub(pos, pos) == "\\" do
    backslashes = backslashes + 1
    pos = pos - 1
  end
  return backslashes % 2 == 1
end

local function display_math_opener_at(line, pos)
  for _, delimiter in ipairs(display_math_openers) do
    if line:sub(pos, pos + #delimiter.opening - 1) == delimiter.opening
      and (not delimiter.respects_escapes or not is_escaped(line, pos))
    then
      return delimiter
    end
  end
  return nil
end

local function backtick_run_length(line, pos)
  local ticks = 0
  while line:sub(pos + ticks, pos + ticks) == "`" do
    ticks = ticks + 1
  end
  return ticks
end

local function matching_code_span_end(line, search_from, ticks)
  while search_from <= #line do
    local candidate = line:find("`", search_from, true)
    if not candidate then
      return nil
    end

    local closing_ticks = 0
    while line:sub(candidate + closing_ticks, candidate + closing_ticks) == "`" do
      closing_ticks = closing_ticks + 1
    end
    if closing_ticks == ticks then
      return candidate + closing_ticks
    end
    search_from = candidate + closing_ticks
  end
  return nil
end

local function matching_code_span(lines, line_index, start_pos, ticks)
  for i = line_index, #lines do
    local line = lines[i]
    if i > line_index and util.trim(line) == "" then
      return nil
    end

    local search_from = i == line_index and start_pos or 1
    local code_end = matching_code_span_end(line, search_from, ticks)
    if code_end then
      return i, code_end
    end
  end
  return nil
end

local function matching_inline_math_end(line, pos)
  if line:sub(pos + 1, pos + 1) == "" or line:sub(pos + 1, pos + 1):match("%s") then
    return nil
  end

  local search_from = pos + 1
  while search_from <= #line do
    local candidate = line:find("$", search_from, true)
    if not candidate then
      return nil
    end
    local before = line:sub(candidate - 1, candidate - 1)
    local after = line:sub(candidate + 1, candidate + 1)
    if not is_escaped(line, candidate)
      and before ~= ""
      and not before:match("%s")
      and not after:match("%d")
    then
      return candidate + 1
    end
    search_from = candidate + 1
  end
  return nil
end

local function has_math_close(lines, line_index, start_pos, closing)
  local opening = strip_leading_space(lines[line_index])
  local opening_indent = #(lines[line_index]:match("^(%s*)") or "")
  local opening_is_list = opening:match("^[-+*]%s") ~= nil
    or opening:match("^%d+[.)]%s") ~= nil

  for i = line_index, #lines do
    local line = lines[i]
    if i > line_index and util.trim(line) == "" then
      return false
    end
    if i > line_index and opening_is_list then
      local stripped = strip_leading_space(line)
      local indent = #(line:match("^(%s*)") or "")
      if indent <= opening_indent
        and (stripped:match("^[-+*]%s") or stripped:match("^%d+[.)]%s"))
      then
        return false
      end
    end

    local search_from = i == line_index and start_pos or 1
    local close_pos = line:find(closing, search_from, true)
    if i == line_index and close_pos == start_pos then
      -- Pandoc requires at least one character between delimiters on one line.
      return false
    end
    if close_pos then
      return true
    end
  end
  return false
end

local function scan_display_math_line(lines, line_index, math_fence, code_span_ticks)
  local line = lines[line_index]
  local pos = 1

  while pos <= #line do
    if math_fence then
      if line:sub(pos, pos + #math_fence - 1) == math_fence then
        pos = pos + #math_fence
        -- Dollar delimiters are symmetric. If another matched pair follows in
        -- this block, keep suppressing markers so an opaque earlier "$$" cannot
        -- phase-shift the scanner and put a marker into the next real display.
        if math_fence ~= "$$" or not has_math_close(lines, line_index, pos, math_fence) then
          math_fence = nil
        end
      else
        pos = pos + 1
      end
    elseif code_span_ticks then
      local code_end = matching_code_span_end(line, pos, code_span_ticks)
      if code_end then
        code_span_ticks = nil
        pos = code_end
      else
        pos = #line + 1
      end
    elseif line:sub(pos, pos) == "`" and not is_escaped(line, pos) then
      local ticks = backtick_run_length(line, pos)
      local close_line, code_end = matching_code_span(lines, line_index, pos + ticks, ticks)
      if close_line == line_index then
        pos = code_end
      elseif close_line then
        code_span_ticks = ticks
        pos = #line + 1
      else
        pos = pos + ticks
      end
    else
      local delimiter = display_math_opener_at(line, pos)
      if delimiter
        and has_math_close(lines, line_index, pos + #delimiter.opening, delimiter.closing)
      then
        math_fence = delimiter.closing
        pos = pos + #delimiter.opening
      elseif line:sub(pos, pos) == "$" and not is_escaped(line, pos) then
        pos = matching_inline_math_end(line, pos) or (pos + 1)
      else
        pos = pos + 1
      end
    end
  end

  return math_fence, code_span_ticks
end

local function opens_display_math(lines, line_index, line)
  local first_nonspace = line:find("%S")
  if not first_nonspace then
    return nil
  end
  local delimiter = display_math_opener_at(line, first_nonspace)
  if delimiter
    and has_math_close(lines, line_index, first_nonspace + #delimiter.opening, delimiter.closing)
  then
    return delimiter.closing
  end
  return nil
end

local function starts_with_space(text)
  -- Check whether the first character is whitespace.
  return text:match("^%s") ~= nil
end

local function is_indented_code_start(line)
  return util.starts_with(line, "    ") or util.starts_with(line, "\t")
end

local function is_header_start(line)
  -- ATX headers start with "#" and then either end or continue with whitespace.
  local rest = line:match("^#(.*)$")
  return rest ~= nil and (rest == "" or starts_with_space(rest))
end

local function is_list_start(line)
  -- Unordered Markdown list marker: "-", "+", or "*" followed by whitespace.
  if line:match("^[-+*]%s") then
    return true
  end
  -- Ordered Markdown list marker: one or more digits, "." or ")", then whitespace.
  return line:match("^%d+[.)]%s") ~= nil
end

local function is_thematic_break(line)
  -- Ignore spaces, then accept three or more of only "-", "*", or "_".
  local chars = line:gsub("%s+", "")
  return #chars >= 3 and (chars:match("^%-+$") or chars:match("^%*+$") or chars:match("^_+$"))
end

local function is_fenced_div_opening(line)
  local stripped = strip_leading_space(line)
  -- Capture a leading colon fence and everything after it.
  local fence, rest = stripped:match("^(:+)(.*)$")
  if not fence or #fence < 3 then
    return false
  end
  rest = util.trim(rest)
  -- Pandoc fenced div openings use either "{...}" attributes or class shorthand.
  return rest:match("^%{.*%}$") ~= nil or rest:match("^[%w_%-]+$") ~= nil
end

local function is_fenced_div_closing(line)
  local stripped = strip_leading_space(line)
  -- A closing fenced div is only a colon fence, with optional surrounding whitespace.
  local fence, rest = stripped:match("^(:+)(.*)$")
  return fence ~= nil and #fence >= 3 and util.trim(rest) == ""
end

local function is_non_paragraph_block_start(line)
  local stripped = strip_leading_space(line)
  return is_indented_code_start(line)
    or is_header_start(stripped)
    or util.starts_with(stripped, ">")
    or is_list_start(stripped)
    or is_thematic_break(stripped)
    or util.starts_with(stripped, "|")
    or util.starts_with(stripped, "<")
    or (util.starts_with(stripped, "[") and stripped:find("]:", 1, true) ~= nil)
    or util.starts_with(stripped, "{#")
    or util.starts_with(stripped, "{.")
end

local function can_contain_multiline_display_math(line)
  local stripped = strip_leading_space(line)
  return is_header_start(stripped)
    or util.starts_with(stripped, ">")
    or is_list_start(stripped)
end

function M.annotate_source_lines(start_line, lines)
  local out = {}
  local in_paragraph = false
  local code_fence = nil
  local code_span_ticks = nil
  local code_span_resumes_paragraph = false
  local math_fence = nil
  local math_resumes_paragraph = false

  local function scan_new_inline_state(line_index)
    math_fence, code_span_ticks = scan_display_math_line(lines, line_index, nil, nil)
    if math_fence then
      math_resumes_paragraph = in_paragraph
    elseif code_span_ticks then
      code_span_resumes_paragraph = in_paragraph
    end
  end

  for i, line in ipairs(lines) do
    local line_no = start_line + i - 1
    if code_fence then
      table.insert(out, line)
      if closes_code_fence(code_fence, line) then
        code_fence = nil
      end
      in_paragraph = false
    elseif (math_fence or code_span_ticks) and util.trim(line) == "" then
      table.insert(out, line)
      math_fence = nil
      code_span_ticks = nil
      in_paragraph = false
    elseif math_fence then
      table.insert(out, line)
      math_fence, code_span_ticks = scan_display_math_line(lines, i, math_fence, nil)
      if not math_fence then
        in_paragraph = math_resumes_paragraph
        if code_span_ticks then
          code_span_resumes_paragraph = in_paragraph
        end
      end
    elseif code_span_ticks then
      table.insert(out, line)
      math_fence, code_span_ticks = scan_display_math_line(lines, i, nil, code_span_ticks)
      if not code_span_ticks then
        in_paragraph = code_span_resumes_paragraph
        if math_fence then
          math_resumes_paragraph = in_paragraph
        end
      end
    elseif util.trim(line) == "" then
      table.insert(out, line)
      in_paragraph = false
    elseif is_indented_code_start(line) then
      table.insert(out, line)
      in_paragraph = false
    else
      local fence = opens_code_fence(line)
      local math = opens_display_math(lines, i, line)
      if fence then
        table.insert(out, line)
        code_fence = fence
        in_paragraph = false
      elseif math then
        table.insert(out, marker_line(line_no, line))
        table.insert(out, line)
        math_resumes_paragraph = in_paragraph
        scan_new_inline_state(i)
        in_paragraph = math_resumes_paragraph
      elseif is_fenced_div_closing(line) then
        table.insert(out, line)
        in_paragraph = false
      elseif in_paragraph then
        table.insert(out, line)
      elseif is_fenced_div_opening(line) then
        table.insert(out, marker_line(line_no, line))
        table.insert(out, line)
        in_paragraph = false
      elseif is_non_paragraph_block_start(line) then
        table.insert(out, line)
        in_paragraph = false
        if can_contain_multiline_display_math(line) then
          scan_new_inline_state(i)
        end
      else
        table.insert(out, marker_line(line_no, line))
        table.insert(out, line)
        in_paragraph = true
      end
    end
  end

  return table.concat(out, "\n")
end

function M.strip_source_line_markers_from_math(doc)
  return doc:walk({
    Math = function(math)
      -- Markers are emitted on their own physical line, so remove that line
      -- before falling back to removing a bare marker.
      math.text = math.text:gsub(source_line_marker_crlf_pattern, "")
      math.text = math.text:gsub(source_line_marker_lf_pattern, "")
      math.text = math.text:gsub(source_line_marker_pattern, "")
      return math
    end,
  })
end

return M
