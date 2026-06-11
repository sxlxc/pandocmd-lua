local util = require("util")

local M = {}

local default_block_specs = {
  { class = "Theorem", title = "Theorem", numbered = true },
  { class = "Conjecture", title = "Conjecture", numbered = true },
  { class = "Definition", title = "Definition", numbered = true },
  { class = "Example", title = "Example", numbered = true },
  { class = "Lemma", title = "Lemma", numbered = true },
  { class = "Problem", title = "Problem", numbered = true },
  { class = "Proposition", title = "Proposition", numbered = true },
  { class = "Corollary", title = "Corollary", numbered = true },
  { class = "Observation", title = "Observation", numbered = true },
  { class = "Figure", title = "Figure", numbered = true },
  { class = "Table", title = "Table", numbered = true },
  { class = "Proof", title = "Proof", numbered = false },
  { class = "Remark", title = "Remark", numbered = false },
}

function M.build_block_specs(meta)
  local specs = {}
  local order = {}
  for _, spec in ipairs(default_block_specs) do
    local key = util.title_case(spec.class)
    specs[key] = { class = key, title = spec.title, numbered = spec.numbered }
    table.insert(order, key)
  end

  local blocks = meta.blocks
  if blocks and pandoc.utils.type(blocks) == "table" then
    for class, block in pairs(blocks) do
      local key = util.title_case(class)
      if not specs[key] then
        table.insert(order, key)
      end
      local block_meta = pandoc.utils.type(block) == "table" and block or {}
      specs[key] = {
        class = key,
        title = util.meta_to_text(block_meta.title) or util.title_case(class),
        numbered = not util.meta_bool_false(block_meta.counter),
      }
    end
  end

  return specs, order
end

local function matched_block_spec(attr, specs, order)
  for _, cls in ipairs(attr.classes) do
    local normalized = util.title_case(cls)
    for _, key in ipairs(order) do
      if key == normalized then
        return specs[key]
      end
    end
  end
  return nil
end

local function normalize_theorem_class(el, specs, order, spec)
  local classes = pandoc.List({ spec.class })
  for _, cls in ipairs(el.attr.classes) do
    local normalized = util.title_case(cls)
    local registered = false
    for _, key in ipairs(order) do
      if key == normalized then
        registered = true
        break
      end
    end
    if not registered then
      classes:insert(cls)
    end
  end
  el.attr.classes = classes
  return el
end

function M.preprocess_blocks(blocks, specs, order)
  local index = 1
  return util.walk_blocks(blocks, function(block)
    if block.t == "Div" then
      local spec = matched_block_spec(block.attr, specs, order)
      if spec then
        normalize_theorem_class(block, specs, order, spec)
        block.attr.attributes.type = spec.title
        if spec.numbered then
          block.attr.attributes.index = tostring(index)
          index = index + 1
        end
      end
    end
    return block
  end)
end

function M.links(blocks)
  local links = {}
  util.walk_blocks(blocks, function(block)
    if block.t == "Div" then
      local typ = block.attr.attributes.type
      local index = block.attr.attributes.index
      if typ and index and block.attr.identifier ~= "" then
        links[block.attr.identifier] = typ .. " " .. index
      end
    end
  end)
  return links
end

local function theorem_name_inlines(raw)
  if raw == nil or raw == "" then
    return {}
  end
  local doc = pandoc.read(raw, "markdown+tex_math_double_backslash+tex_math_single_backslash+latex_macros+raw_tex")
  for i = #doc.blocks, 1, -1 do
    local block = doc.blocks[i]
    if block.t == "Plain" or block.t == "Para" then
      return block.content
    end
  end
  return {}
end

function M.render_blocks(blocks)
  return util.walk_blocks(blocks, function(block)
    if block.t == "Div" and block.attr.attributes.type then
      util.add_class(block.attr, "theorem-environment")
      local header = pandoc.Span({
        pandoc.Span(util.inline_text(block.attr.attributes.type), util.attr("", { "type" }, {})),
        block.attr.attributes.index and pandoc.Span(util.inline_text(block.attr.attributes.index), util.attr("", { "index" }, {})) or pandoc.Str(""),
        block.attr.attributes.title and pandoc.Span(theorem_name_inlines(block.attr.attributes.title), util.attr("", { "name" }, {})) or pandoc.Str(""),
      }, util.attr("", { "theorem-header" }, {}))
      block.content:insert(1, pandoc.Plain({ header }))
    end
    return block
  end)
end

return M
