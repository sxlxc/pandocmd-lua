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
local pangu = require("pangu")
local theorems = require("theorems")
local sidenotes = require("sidenotes")
local page_meta = require("page-meta")

function Pandoc(doc)
  local source_file = util.stringify(doc.meta["pandocmd-source-file"] or "")
  local specs, order = theorems.build_block_specs(doc.meta)

  page_meta.apply(doc)

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
  doc.blocks = pangu.blocks(doc.blocks)
  doc.blocks = theorems.preprocess_blocks(doc.blocks, specs, order)

  local links = theorems.links(doc.blocks)
  for k, v in pairs(references.section_numbers(doc.blocks)) do
    links[k] = v
  end
  doc.blocks = references.autoref_blocks(doc.blocks, links)
  doc.blocks = theorems.render_blocks(doc.blocks)
  doc.blocks = sidenotes.render_blocks(doc.blocks)

  if doc.meta.bibliography ~= nil then
    doc = pandoc.utils.citeproc(doc)
  end
  return doc
end
