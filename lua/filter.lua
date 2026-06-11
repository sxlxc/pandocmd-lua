-- Pandoc Lua filter entrypoint for the pandocmd AST transforms.
--
-- Expected command order:
--   pandoc -f lua/reader.lua -L lua/filter.lua -t lua/writer.lua ...

local script_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or ""
package.path = script_dir .. "?.lua;" .. package.path

local util = require("util")
local equations = require("equations")
local references = require("references")
local source_lines = require("source-lines")
local theorems = require("theorems")
local sidenotes = require("sidenotes")
local page_meta = require("page-meta")

local function is_source_line_div(block)
  return util.has_class(block.attr, "source-line")
end

local function is_source_line_label(block)
  return block.t == "RawBlock"
    and block.format == "html"
    and block.text:find('class="source-line-link"', 1, true) ~= nil
end

local function is_theorem_header(block)
  if block.t ~= "Plain" or #block.content ~= 1 then
    return false
  end
  local inline = block.content[1]
  return inline.t == "Span" and util.has_class(inline.attr, "theorem-header")
end

local function unwrap_div_paragraphs(blocks)
  return util.walk_blocks(blocks, function(block)
    if block.t ~= "Div" or is_source_line_div(block) then
      return block
    end

    local has_theorem_header = false
    local first_body_seen = false
    local first_body_para_index = nil
    local para_index = nil
    local only_single_para_body = true

    for i, child in ipairs(block.content) do
      if child.t == "Para" then
        if not first_body_seen then
          first_body_seen = true
          first_body_para_index = i
        end
        if para_index ~= nil then
          only_single_para_body = false
        else
          para_index = i
        end
      elseif is_theorem_header(child) then
        has_theorem_header = true
      elseif not is_source_line_label(child) then
        first_body_seen = true
        only_single_para_body = false
      end
    end

    if has_theorem_header and first_body_para_index then
      block.content[first_body_para_index] = pandoc.Plain(block.content[first_body_para_index].content)
    elseif only_single_para_body and para_index ~= nil then
      block.content[para_index] = pandoc.Plain(block.content[para_index].content)
    end
    return block
  end)
end

function Pandoc(doc)
  local source_file = util.stringify(doc.meta["pandocmd-source-file"] or "")
  local specs, order = theorems.build_block_specs(doc.meta)
  local custom_section_numbers = references.has_appendix_headers(doc.blocks)
  doc.meta["pandocmd-custom-section-numbers"] = custom_section_numbers

  doc.blocks = equations.preprocess_blocks(doc.blocks)
  local equation_links = {}
  equations.collect_links(doc.blocks, equation_links)
  doc.blocks = references.autoref_blocks(doc.blocks, (function()
    local links = {}
    for k, v in pairs(equation_links) do
      links[k] = "Eq. " .. v
    end
    return links
  end)())

  doc.blocks = source_lines.annotate_blocks(source_file, doc.blocks)
  doc.blocks = theorems.preprocess_blocks(doc.blocks, specs, order)

  local links = theorems.links(doc.blocks)
  for k, v in pairs(references.section_numbers(doc.blocks)) do
    links[k] = v
  end
  page_meta.apply(doc, { custom_section_numbers = custom_section_numbers })
  doc.blocks = references.autoref_blocks(doc.blocks, links)
  if custom_section_numbers then
    doc.blocks = references.render_header_numbers(doc.blocks)
  end
  doc.blocks = theorems.render_blocks(doc.blocks)
  doc.blocks = sidenotes.render_blocks(doc.blocks)
  doc.blocks = unwrap_div_paragraphs(doc.blocks)

  if doc.meta.bibliography ~= nil then
    doc = pandoc.utils.citeproc(doc)
  end
  return doc
end
