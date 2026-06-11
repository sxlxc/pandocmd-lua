local util = require("util")

local M = {}
local equation_counter = 1

local function extract_equation_tag(math)
  local i = 1
  while true do
    local start_pos = math:find("\\tag", i, true)
    if not start_pos then
      return math, nil
    end
    if start_pos > 1 and math:sub(start_pos - 1, start_pos - 1) == "\\" then
      i = start_pos + 4
    else
      local pos = start_pos + 4
      local starred = false
      if math:sub(pos, pos) == "*" then
        starred = true
        pos = pos + 1
      end
      while math:sub(pos, pos):match("%s") do
        pos = pos + 1
      end
      if math:sub(pos, pos) == "{" then
        local depth = 1
        local chars = {}
        local j = pos + 1
        while j <= #math do
          local c = math:sub(j, j)
          if c == "\\" and j < #math then
            table.insert(chars, c)
            table.insert(chars, math:sub(j + 1, j + 1))
            j = j + 2
          elseif c == "{" then
            depth = depth + 1
            table.insert(chars, c)
            j = j + 1
          elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
              local before = math:sub(1, start_pos - 1)
              local after = math:sub(j + 1)
              return before .. after, { text = table.concat(chars), parenthesized = not starred }
            end
            table.insert(chars, c)
            j = j + 1
          else
            table.insert(chars, c)
            j = j + 1
          end
        end
      end
      i = start_pos + 4
    end
  end
end

local function render_equation_tag(tag)
  if tag.parenthesized then
    return "(" .. tag.text .. ")"
  end
  return tag.text
end

local function wrap_display_math(math)
  return pandoc.Span({ pandoc.Math("DisplayMath", math) }, util.attr("", { "math-container" }, {}))
end

local function equation_number(number_text)
  return pandoc.Span(util.inline_text(number_text), util.attr("", { "equation-number" }, {}))
end

local function make_equation(eq_id, idx, math)
  local clean_math, tag = extract_equation_tag(math)
  local number_text = tag and render_equation_tag(tag) or ("(" .. tostring(idx) .. ")")
  local attrs = { index = tostring(idx) }
  if tag then
    attrs.reference = number_text
  end
  return pandoc.Span(
    { wrap_display_math(clean_math), equation_number(number_text) },
    util.attr(eq_id, { "equation" }, attrs)
  )
end

local function make_tagged_equation(math, tag)
  local number_text = render_equation_tag(tag)
  return pandoc.Span(
    { wrap_display_math(math), equation_number(number_text) },
    util.attr("", { "equation" }, { reference = number_text })
  )
end

local function preprocess_equation_inlines(inlines)
  local out = pandoc.List({})
  local i = 1
  while i <= #inlines do
    local inline = inlines[i]
    if inline.t == "Math" and inline.mathtype == "DisplayMath" then
      local next_i = i + 1
      if inlines[next_i] and inlines[next_i].t == "Space" then
        next_i = next_i + 1
      end
      local label = nil
      if inlines[next_i] and inlines[next_i].t == "Str" then
        label = inlines[next_i].text:match("^%{#(eq:[^}]+)%}$")
      end
      if label then
        out:insert(make_equation(label, equation_counter, inline.text))
        equation_counter = equation_counter + 1
        i = next_i + 1
      else
        local clean_math, tag = extract_equation_tag(inline.text)
        if tag then
          out:insert(make_tagged_equation(clean_math, tag))
        else
          out:insert(wrap_display_math(clean_math))
        end
        i = i + 1
      end
    else
      out:insert(inline)
      i = i + 1
    end
  end
  return out
end

function M.preprocess_blocks(blocks)
  equation_counter = 1
  return util.walk_blocks(blocks, function(block)
    if block.t == "Para" or block.t == "Plain" then
      block.content = preprocess_equation_inlines(block.content)
    end
    return block
  end)
end

local function collect_equation_links(inlines, links)
  for _, inline in ipairs(inlines) do
    if inline.t == "Span" and util.has_class(inline.attr, "equation") and inline.attr.identifier ~= "" then
      local ref = inline.attr.attributes.reference or inline.attr.attributes.index
      if inline.attr.attributes.index and not inline.attr.attributes.reference then
        ref = "(" .. inline.attr.attributes.index .. ")"
      end
      if ref then
        links[inline.attr.identifier] = ref
      end
    end
    if inline.content then
      collect_equation_links(inline.content, links)
    end
  end
end

function M.collect_links(blocks, links)
  util.walk_blocks(blocks, function(block)
    if block.t == "Para" or block.t == "Plain" or block.t == "Header" then
      collect_equation_links(block.content, links)
    end
  end)
end

return M
