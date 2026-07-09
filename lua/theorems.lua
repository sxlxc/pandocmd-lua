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
  for _, spec in ipairs(default_block_specs) do
    specs[spec.class] = { class = spec.class, title = spec.title, numbered = spec.numbered }
  end

  local blocks = meta.blocks
  if blocks and pandoc.utils.type(blocks) == "table" then
    for class, block in pairs(blocks) do
      local key = util.title_case(class)
      local block_meta = pandoc.utils.type(block) == "table" and block or {}
      specs[key] = {
        class = key,
        title = util.meta_to_text(block_meta.title) or key,
        numbered = not util.meta_bool_false(block_meta.counter),
      }
    end
  end

  return specs
end

local function matched_block_spec(attr, specs)
  for _, cls in ipairs(attr.classes) do
    local spec = specs[util.title_case(cls)]
    if spec then
      return spec
    end
  end
  return nil
end

local function normalize_theorem_class(el, specs, spec)
  local classes = pandoc.List({ spec.class })
  for _, cls in ipairs(el.attr.classes) do
    if not specs[util.title_case(cls)] then
      classes:insert(cls)
    end
  end
  el.attr.classes = classes
end

-- Tags matching divs with type/index attributes; returns the blocks plus a map
-- from identifier to reference label, e.g. links["thm-x"] = "Theorem 1".
function M.preprocess_blocks(blocks, specs)
  local index = 1
  local links = {}
  blocks = util.walk_blocks(blocks, function(block)
    if block.t == "Div" then
      local spec = matched_block_spec(block.attr, specs)
      if spec then
        normalize_theorem_class(block, specs, spec)
        block.attr.attributes.type = spec.title
        if spec.numbered then
          block.attr.attributes.index = tostring(index)
          if block.attr.identifier ~= "" then
            links[block.attr.identifier] = spec.title .. " " .. index
          end
          index = index + 1
        end
      end
    end
    return block
  end)
  return blocks, links
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
    local attributes = block.t == "Div" and block.attr.attributes
    if attributes and attributes.type then
      util.add_class(block.attr, "theorem-environment")
      local parts = pandoc.List({
        pandoc.Span(util.inline_text(attributes.type), util.attr("", { "type" })),
      })
      if attributes.index then
        parts:insert(pandoc.Span(util.inline_text(attributes.index), util.attr("", { "index" })))
      end
      if attributes.title then
        parts:insert(pandoc.Span(theorem_name_inlines(attributes.title), util.attr("", { "name" })))
      end
      block.content:insert(1, pandoc.Plain({ pandoc.Span(parts, util.attr("", { "theorem-header" })) }))
    end
    return block
  end)
end

return M
