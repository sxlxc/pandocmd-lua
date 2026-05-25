local util = require("util")

local M = {}

function M.section_numbers(blocks)
  local links = {}
  local nums = {}
  local function bump(level)
    for i = #nums + 1, level do
      nums[i] = 0
    end
    nums[level] = (nums[level] or 0) + 1
    for i = level + 1, #nums do
      nums[i] = nil
    end
  end
  local function render()
    local parts = {}
    for _, n in ipairs(nums) do
      table.insert(parts, tostring(n))
    end
    return table.concat(parts, ".")
  end
  local function walk(block_list)
    for _, block in ipairs(block_list) do
      if block.t == "Header" and not util.has_class(block.attr, "unnumbered") then
        bump(block.level)
        if util.starts_with(block.attr.identifier, "sec:") then
          links[block.attr.identifier] = "Section " .. render()
        end
      elseif block.content and block.t ~= "Header" then
        walk(block.content)
      end
    end
  end
  walk(blocks)
  return links
end

local function autoref_inlines(inlines, links)
  for i, inline in ipairs(inlines) do
    if inline.t == "Cite" and #inline.citations > 0 then
      local citeid = inline.citations[1].id
      local title = links[citeid]
      if title then
        inlines[i] = pandoc.Link(util.inline_text(title), "#" .. citeid, title)
      end
    elseif inline.content then
      inline.content = autoref_inlines(inline.content, links)
    end
  end
  return inlines
end

function M.autoref_blocks(blocks, links)
  for _, block in ipairs(blocks) do
    if block.t == "Para" or block.t == "Plain" or block.t == "Header" then
      block.content = autoref_inlines(block.content, links)
    elseif block.content then
      M.autoref_blocks(block.content, links)
    end
  end
  return blocks
end

return M
