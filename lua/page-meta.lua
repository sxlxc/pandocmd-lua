local util = require("util")

local M = {}

local function stylesheet_tags(meta)
  local css = {
    "css/fonts.css",
    "css/default.css",
    "css/pygentize.css",
    "css/chao-theorems.css",
    "css/sidenotes.css",
  }
  if meta.pandocmd and meta.pandocmd.css and meta.pandocmd.css.t == "MetaList" then
    css = {}
    for _, value in ipairs(meta.pandocmd.css) do
      table.insert(css, util.stringify(value))
    end
  end
  local lines = {}
  for _, path in ipairs(css) do
    if not util.starts_with(path, "css/") then
      path = "css/" .. path:match("[^/\\]+$")
    end
    table.insert(lines, '<link rel="stylesheet" href="/' .. path:gsub("\\", "/") .. '" />')
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

  local function render_number()
    local parts = {}
    for _, n in ipairs(nums) do
      table.insert(parts, tostring(n))
    end
    return table.concat(parts, ".")
  end

  local function walk(block_list)
    for _, block in ipairs(block_list) do
      if block.t == "Header" then
        if not util.has_class(block.attr, "unnumbered") then
          bump(block.level)
        end
        if block.level <= 2 and block.attr.identifier ~= "" then
          entries[#entries + 1] = {
            level = block.level,
            identifier = block.attr.identifier,
            number = util.has_class(block.attr, "unnumbered") and nil or render_number(),
            content = block.content,
          }
        end
      elseif block.content then
        walk(block.content)
      end
    end
  end

  walk(blocks)
  return entries
end

local function generate_toc(blocks)
  local entries = toc_entries(blocks)
  if #entries == 0 then
    return ""
  end

  local out = { "<ul>" }
  local open_h1 = false
  local open_sub = false

  local function link(entry)
    local number = entry.number and ('<span class="toc-section-number">' .. entry.number .. "</span> ") or ""
    return '<a href="#' .. util.escape_html(entry.identifier) .. '">' .. number .. util.inline_html(entry.content) .. "</a>"
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
  doc.meta.toc = pandoc.MetaBlocks({ pandoc.RawBlock("html", generate_toc(doc.blocks)) })
  M.add_citeproc_meta(doc)
end

return M
