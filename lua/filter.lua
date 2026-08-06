-- Pandoc Lua filter entrypoint for the pandocmd AST transforms.
--
-- Expected command order:
--   pandoc -f lua/reader.lua -L lua/filter.lua -t lua/writer.lua ...

local script_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or ""
package.path = script_dir .. "?.lua;" .. package.path

local util = require("util")
local algorithms = require("algorithms")
local equations = require("equations")
local references = require("references")
local source_lines = require("source-lines")
local theorems = require("theorems")
local sidenotes = require("sidenotes")
local page_meta = require("page-meta")
local math_punctuation = require("math-punctuation")
local media = require("media")

function Pandoc(doc)
  local source_file = util.stringify(doc.meta["pandocmd-source-file"] or "")
  local specs = theorems.build_block_specs(doc.meta)
  local custom_section_numbers = references.has_appendix_headers(doc.blocks)
  doc.meta["pandocmd-custom-section-numbers"] = custom_section_numbers

  local algorithm_links, equation_links, theorem_links
  doc.blocks, equation_links = equations.preprocess_blocks(doc.blocks)
  doc.blocks = source_lines.annotate_blocks(source_file, doc.blocks)
  doc.blocks, algorithm_links = algorithms.preprocess_blocks(doc.blocks)
  doc.blocks, theorem_links = theorems.preprocess_blocks(doc.blocks, specs)

  local links = {}
  for k, v in pairs(equation_links) do
    links[k] = "Eq. " .. v
  end
  for k, v in pairs(theorem_links) do
    links[k] = v
  end
  for k, v in pairs(algorithm_links) do
    links[k] = v
  end
  for k, v in pairs(references.section_numbers(doc.blocks)) do
    links[k] = v
  end

  doc.blocks = references.autoref_blocks(doc.blocks, links)
  page_meta.apply(doc)
  if custom_section_numbers then
    doc.blocks = references.render_header_numbers(doc.blocks)
  end
  doc.blocks = theorems.render_blocks(doc.blocks)
  doc.blocks = algorithms.render_blocks(doc.blocks)
  doc.blocks = sidenotes.render_blocks(doc.blocks)

  if doc.meta.bibliography ~= nil then
    doc = pandoc.utils.citeproc(doc)
  end
  doc = doc:walk(math_punctuation)
  doc = media.process(doc)
  return doc
end
