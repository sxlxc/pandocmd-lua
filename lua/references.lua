local util = require("util")

local M = {}

local function alpha_number(n)
  local out = ""
  while n > 0 do
    n = n - 1
    out = string.char(65 + (n % 26)) .. out
    n = math.floor(n / 26)
  end
  return out
end

local function render_parts(parts, first_part_renderer)
  local out = {}
  for i, n in ipairs(parts) do
    if i == 1 and first_part_renderer then
      table.insert(out, first_part_renderer(n))
    else
      table.insert(out, tostring(n))
    end
  end
  return table.concat(out, ".")
end

local function new_section_state()
  local nums = {}
  local appendix_level = nil
  local appendix_nums = {}

  local function bump(parts, level)
    for i = #parts + 1, level do
      parts[i] = 0
    end
    parts[level] = (parts[level] or 0) + 1
    for i = level + 1, #parts do
      parts[i] = nil
    end
  end

  return {
    next = function(block)
      local starts_appendix = util.has_class(block.attr, "appendix")
      if appendix_level and block.level <= appendix_level and not starts_appendix then
        appendix_level = nil
        appendix_nums = {}
      end
      if starts_appendix and (appendix_level == nil or block.level < appendix_level) then
        appendix_level = block.level
        appendix_nums = {}
      end
      if util.has_class(block.attr, "unnumbered") then
        return nil
      end
      if appendix_level and block.level >= appendix_level then
        bump(appendix_nums, block.level - appendix_level + 1)
        return { label = "Appendix", number = render_parts(appendix_nums, alpha_number) }
      end

      bump(nums, block.level)
      return { label = "Section", number = render_parts(nums) }
    end,
  }
end

function M.walk_numbered_headers(blocks, callback)
  local state = new_section_state()
  local function walk(block_list)
    for _, block in ipairs(block_list) do
      if block.t == "Header" then
        callback(block, state.next(block))
      elseif block.content then
        walk(block.content)
      end
    end
  end
  walk(blocks)
end

local function header_number_span(number)
  return pandoc.Span(util.inline_text(number), util.attr("", { "header-section-number" }, {}))
end

function M.render_header_numbers(blocks)
  M.walk_numbered_headers(blocks, function(block, info)
    if info then
      block.attr.attributes["data-number"] = info.number
      block.content:insert(1, pandoc.Space())
      block.content:insert(1, header_number_span(info.number))
    end
  end)
  return blocks
end

function M.section_numbers(blocks)
  local links = {}
  M.walk_numbered_headers(blocks, function(block, info)
    if info and block.attr.identifier ~= "" then
      links[block.attr.identifier] = info.label .. " " .. info.number
    end
  end)
  return links
end

local function autoref_cite(inline, links)
  if #inline.citations > 0 then
    local citeid = inline.citations[1].id
    local title = links[citeid]
    if title then
      return pandoc.Link(util.inline_text(title), "#" .. citeid, title)
    end
  end
end

function M.autoref_blocks(blocks, links)
  local filter = {
    Cite = function(inline)
      return autoref_cite(inline, links)
    end,
  }
  for i, block in ipairs(blocks) do
    blocks[i] = pandoc.walk_block(block, filter)
  end
  return blocks
end

return M
