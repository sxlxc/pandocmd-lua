local util = require("util")

local M = {}

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

local function opens_display_math(line)
  local stripped = strip_leading_space(line)
  if util.starts_with(stripped, "$$") then
    return "$$"
  elseif util.starts_with(stripped, "\\[") then
    return "\\]"
  end
  return nil
end

local function closes_math_fence(fence, line)
  return util.trim(line):find(fence, 1, true) ~= nil
end

local function closes_display_math_on_opening_line(fence, line)
  local stripped = strip_leading_space(line)
  if fence == "$$" then
    -- Count every "$$" pair; two or more means the display closes on this line.
    local _, count = stripped:gsub("%$%$", "")
    return count >= 2
  elseif fence == "\\]" then
    return stripped:sub(3):find("\\]", 1, true) ~= nil
  end
  return false
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

function M.annotate_source_lines(start_line, lines)
  local out = {}
  local in_paragraph = false
  local code_fence = nil
  local math_fence = nil
  local math_resumes_paragraph = false

  for i, line in ipairs(lines) do
    local line_no = start_line + i - 1
    if code_fence then
      table.insert(out, line)
      if closes_code_fence(code_fence, line) then
        code_fence = nil
      end
      in_paragraph = false
    elseif math_fence then
      table.insert(out, line)
      if closes_math_fence(math_fence, line) then
        in_paragraph = math_resumes_paragraph
        math_fence = nil
      end
    elseif util.trim(line) == "" then
      table.insert(out, line)
      in_paragraph = false
    elseif is_indented_code_start(line) then
      table.insert(out, line)
      in_paragraph = false
    else
      local fence = opens_code_fence(line)
      local math = opens_display_math(line)
      if fence then
        table.insert(out, line)
        code_fence = fence
        in_paragraph = false
      elseif math then
        table.insert(out, marker_line(line_no, line))
        table.insert(out, line)
        math_resumes_paragraph = in_paragraph
        in_paragraph = closes_display_math_on_opening_line(math, line) and math_resumes_paragraph
        if not closes_display_math_on_opening_line(math, line) then
          math_fence = math
        end
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
      else
        table.insert(out, marker_line(line_no, line))
        table.insert(out, line)
        in_paragraph = true
      end
    end
  end

  return table.concat(out, "\n")
end

return M
