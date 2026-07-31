local util = require("util")

local M = {}
local nbsp = " "

local function has_algo_class(attr_body)
  for token in attr_body:gmatch("%S+") do
    if token == ".algo" then
      return true
    end
  end
  return false
end

-- Markdown discards indentation at the start of continuation lines. Encode it
-- before parsing so algorithm layout survives as non-breaking spaces.
function M.preserve_source_indentation(lines)
  local output = {}
  local algo_fences = {}

  for _, line in ipairs(lines) do
    local fence, attr_body = line:match("^%s*(:+)%s*%{(.-)%}")
    local closing = line:match("^%s*(:+)%s*$")

    if closing and #algo_fences > 0 and #closing >= algo_fences[#algo_fences] then
      table.remove(algo_fences)
      output[#output + 1] = line
    else
      if #algo_fences > 0 then
        line = line:gsub("^(%s+)", function(indent)
          return (indent:gsub(" ", "&nbsp;"):gsub("\t", "&#9;"))
        end)
      end
      output[#output + 1] = line

      if fence and has_algo_class(attr_body) then
        algo_fences[#algo_fences + 1] = #fence
      end
    end
  end

  return output
end

local function title_inlines(raw)
  if raw == nil or raw == "" then
    return pandoc.List({})
  end
  local doc = pandoc.read(raw, "markdown+tex_math_double_backslash+tex_math_single_backslash+latex_macros+raw_tex")
  for i = #doc.blocks, 1, -1 do
    local block = doc.blocks[i]
    if block.t == "Plain" or block.t == "Para" then
      return block.content
    end
  end
  return pandoc.List({})
end

local function leading_indent(inlines)
  local first = inlines[1]
  if not first or first.t ~= "Str" then
    return 0
  end

  local count = 0
  for _, codepoint in utf8.codes(first.text) do
    if codepoint ~= 160 then
      break
    end
    count = count + 1
  end
  return count
end

local function algorithm_line(inlines)
  local indent = leading_indent(inlines)
  if indent > 0 then
    inlines[1].text = inlines[1].text:sub(indent * #nbsp + 1)
  end
  return pandoc.Span(inlines, util.attr("", { "algo-line" }, {
    style = "--algo-indent: " .. (indent * 0.5) .. "rem",
  }))
end

local function preserve_logical_lines(blocks)
  return pandoc.Blocks(blocks):walk({
    Para = function(block)
      local output = pandoc.List({})
      local line = pandoc.List({})

      for _, inline in ipairs(block.content) do
        if inline.t == "SoftBreak" or inline.t == "LineBreak" then
          output:insert(algorithm_line(line))
          line = pandoc.List({})
        else
          line:insert(inline)
        end
      end
      output:insert(algorithm_line(line))
      return pandoc.Para(output)
    end,
  })
end

function M.preprocess_blocks(blocks)
  local index = 1
  local links = {}

  blocks = util.walk_blocks(blocks, function(block)
    if block.t == "Div" and util.has_class(block.attr, "algo") then
      block.attr.attributes["algo-index"] = tostring(index)
      if block.attr.identifier ~= "" then
        links[block.attr.identifier] = "ALG " .. index
      end
      index = index + 1
    end
    return block
  end)

  return blocks, links
end

function M.render_blocks(blocks)
  return util.walk_blocks(blocks, function(block)
    if block.t ~= "Div" or not util.has_class(block.attr, "algo") then
      return block
    end

    local identifier = block.attr.identifier
    local attributes = block.attr.attributes
    local index = attributes["algo-index"] or ""
    local title = title_inlines(attributes.title)
    local caption = pandoc.List({
      pandoc.Str("ALG"),
      pandoc.Space(),
      pandoc.Str(index .. ":"),
    })
    if #title > 0 then
      caption:insert(pandoc.Space())
      caption:extend(title)
    end

    local box = pandoc.Div(
      preserve_logical_lines(block.content),
      util.attr("", { "algo-box" })
    )
    local caption_block = pandoc.Para({
      pandoc.Span(caption, util.attr("", { "algo-caption" })),
    })

    local outer_attributes = {}
    if attributes["data-source-line"] then
      outer_attributes["data-source-line"] = attributes["data-source-line"]
    end

    return pandoc.Div(
      { box, caption_block },
      util.attr(identifier, { "algorithm" }, outer_attributes)
    )
  end)
end

return M
