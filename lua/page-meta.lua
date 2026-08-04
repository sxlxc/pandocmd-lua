local util = require("util")
local references = require("references")

local M = {}

local function asset_url(meta, path)
  local base = util.stringify(meta["pandocmd-asset-base-url"] or ""):gsub("/+$", "")
  return base .. "/" .. path:gsub("^/", "")
end

local function stylesheet_tags(meta)
  local css = {
    "css/fonts.css",
    "css/default.css",
    "css/pygentize.css",
    "css/chao-theorems.css",
    "css/sidenotes.css",
  }
  local pandocmd = pandoc.utils.type(meta.pandocmd) == "table" and meta.pandocmd or {}
  local configured_css = pandocmd.css
  if configured_css and pandoc.utils.type(configured_css) == "List" then
    css = {}
    for _, value in ipairs(configured_css) do
      table.insert(css, util.stringify(value))
    end
  elseif configured_css then
    css = { util.stringify(configured_css) }
  end
  local lines = {}
  for _, path in ipairs(css) do
    if not util.starts_with(path, "css/") then
      path = "css/" .. path:match("[^/\\]+$")
    end
    table.insert(lines, '<link rel="stylesheet" href="'
      .. util.escape_html(asset_url(meta, path:gsub("\\", "/"))) .. '" />')
  end
  return table.concat(lines, "\n")
end

function M.add_citeproc_meta(doc)
  if doc.meta.bibliography ~= nil then
    doc.meta["link-citations"] = true
    doc.meta["reference-section-title"] = pandoc.MetaInlines({ pandoc.Str("References") })
    if doc.meta.csl == nil and doc.meta["pandocmd-assets-dir"] ~= nil then
      doc.meta.csl = util.stringify(doc.meta["pandocmd-assets-dir"]) .. "/bib_style.csl"
    end
  end
end

local function toc_entries(blocks)
  local entries = {}
  references.walk_numbered_headers(blocks, function(block, info)
    if block.level <= 2 and block.attr.identifier ~= "" then
      entries[#entries + 1] = {
        level = block.level,
        identifier = block.attr.identifier,
        number = info and info.number or nil,
        content = block.content,
      }
    end
  end)
  return entries
end

local function generate_toc(doc)
  local entries = toc_entries(doc.blocks)
  if doc.meta.bibliography ~= nil then
    -- citeproc runs after the TOC is generated; it appends a references
    -- section headed by an unnumbered "References" header with this id.
    entries[#entries + 1] = {
      level = 1,
      identifier = "bibliography",
      content = { pandoc.Str("References") },
    }
  end
  if #entries == 0 then
    return ""
  end

  local out = { "<ul>" }
  local open_h1 = false
  local open_sub = false

  local function link(entry)
    local number = entry.number and ('<span class="toc-section-number">' .. entry.number .. "</span> ") or ""
    -- Nested anchors are invalid HTML, so autoref/citation links inside
    -- headers are reduced to their text, matching pandoc's own TOC.
    local content = pandoc.Inlines(entry.content):walk({
      Link = function(l)
        return l.content
      end,
    })
    return '<a href="#' .. util.escape_html(entry.identifier) .. '">' .. number .. util.inline_html(content) .. "</a>"
  end

  local function close_h1()
    if not open_h1 then
      return
    end
    if open_sub then
      table.insert(out, "</ul></li>")
      open_sub = false
    else
      out[#out] = out[#out] .. "</li>"
    end
    open_h1 = false
  end

  for _, entry in ipairs(entries) do
    if entry.level <= 1 then
      close_h1()
      table.insert(out, "<li>" .. link(entry))
      open_h1 = true
    elseif entry.level == 2 then
      if not open_h1 then
        table.insert(out, "<li>")
        open_h1 = true
      end
      if not open_sub then
        table.insert(out, "<ul>")
        open_sub = true
      end
      table.insert(out, "<li>" .. link(entry) .. "</li>")
    end
  end

  close_h1()
  table.insert(out, "</ul>")

  return table.concat(out, "\n")
end

function M.apply(doc)
  doc.meta.stylesheets = pandoc.MetaBlocks({ pandoc.RawBlock("html", stylesheet_tags(doc.meta)) })
  doc.meta.toc = pandoc.MetaBlocks({ pandoc.RawBlock("html", generate_toc(doc)) })
  M.add_citeproc_meta(doc)
end

return M
