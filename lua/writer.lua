-- Hakyll-style page writer for the pandocmd Pandoc Lua prototype.
--
-- Pandoc's template engine reindents multiline variables. Hakyll's
-- loadAndApplyTemplate substitutes the already-rendered HTML fragment
-- literally, so this writer keeps the final page closer to the current output.
--
-- The table of contents is generated ahead of time by page-meta.lua and
-- arrives in doc.meta.toc, so the document body is only rendered once here.

local script_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or ""
package.path = script_dir .. "?.lua;" .. package.path

local util = require("util")
local stringify = pandoc.utils.stringify

local function raw_meta_blocks(value)
  if value == nil then
    return ""
  end
  local lines = {}
  for _, block in ipairs(value) do
    if block.t == "RawBlock" and block.format == "html" then
      table.insert(lines, block.text)
    end
  end
  if #lines == 0 then
    local ok, rendered = pcall(function()
      return pandoc.write(pandoc.Pandoc(value), "html5")
    end)
    if ok then
      return rendered
    end
  end
  return table.concat(lines, "\n")
end

local function meta_inlines(value)
  if value == nil then
    return pandoc.List({})
  end
  local value_type = pandoc.utils.type(value)
  if value_type == "Inlines" then
    return value
  elseif value_type == "Blocks" then
    return pandoc.utils.blocks_to_inlines(value)
  end
  return pandoc.List({ pandoc.Str(stringify(value)) })
end

local function meta_inline_html(value)
  return util.inline_html(meta_inlines(value))
end

local function template_path(meta)
  local from_env = os.getenv("PANDOCMD_TEMPLATE")
  if from_env and from_env ~= "" then
    return from_env
  end
  local template = util.map_field(meta.pandocmd, "template")
  if template then
    return stringify(template)
  end
  local assets = stringify(meta["pandocmd-assets-dir"] or "assets")
  return util.join_path(assets, "templates/default.html")
end

local function apply_conditional(template, name, enabled)
  local escaped = name:gsub("([^%w])", "%%%1")
  return template:gsub("%$if%(" .. escaped .. "%)%$(.-)%$endif%$", function(content)
    if enabled then
      return content
    end
    return ""
  end)
end

local function replace_field(template, name, value)
  local escaped = name:gsub("([^%w])", "%%%1")
  return template:gsub("%$" .. escaped .. "%$", function()
    return value
  end)
end

local function stylesheet_assets(meta, stylesheets)
  local assets_dir = stringify(meta["pandocmd-assets-dir"] or "assets")
  local contents = { stylesheets }
  local versions = {}
  local line_breaking_css = util.read_file(util.join_path(assets_dir, "css/line-breaking.css"))
    or error("could not read stylesheet asset css/line-breaking.css")

  local function version_for_href(href)
    local path = href:gsub("[?#].*$", "")
    local basename = path:match("/css/([^/]+)$") or path:match("^css/([^/]+)$")
    if not basename then
      return nil
    end
    if not versions[basename] then
      local content = util.read_file(util.join_path(assets_dir, "css/" .. basename)) or href
      versions[basename] = pandoc.sha1(content)
      contents[#contents + 1] = basename .. "\0" .. content
    end
    return versions[basename]
  end

  for href in stylesheets:gmatch('href="([^"]+)"') do
    version_for_href(href)
  end

  contents[#contents + 1] = "line-breaking.css\0" .. line_breaking_css
  local fingerprint = pandoc.sha1(table.concat(contents, "\0"))
  local versioned = stylesheets:gsub('(href=")([^"]+)(")', function(prefix, href, suffix)
    local version = version_for_href(href)
    if not version then
      return prefix .. href .. suffix
    end
    local separator = href:find("?", 1, true) and "&amp;" or "?"
    return prefix .. href .. separator .. "v=" .. version .. suffix
  end)

  return versioned, fingerprint, pandoc.sha1(line_breaking_css)
end

local function page_runtime_assets(meta, stylesheet_fingerprint, template_source)
  local assets_dir = stringify(meta["pandocmd-assets-dir"] or "assets")
  local asset_base = stringify(meta["pandocmd-asset-base-url"] or ""):gsub("/+$", "")
  local page_js = util.read_file(util.join_path(assets_dir, "js/page.js"))
    or error("could not read page runtime asset js/page.js")
  local page_js_fingerprint = pandoc.sha1(page_js)
  local fingerprint = pandoc.sha1(template_source .. "\0" .. page_js)
  local tags = {
    '<meta name="pandocmd-page-fingerprint" content="' .. fingerprint .. '" />',
    '<meta name="pandocmd-stylesheet-fingerprint" content="' .. stylesheet_fingerprint .. '" />',
  }
  local endpoint = os.getenv("PANDOCMD_PREVIEW_LIVE_RELOAD_URL")
  if endpoint and endpoint ~= "" then
    tags[#tags + 1] = '<meta name="pandocmd-live-reload-url" content="'
      .. util.escape_html(endpoint) .. '" />'
  end
  tags[#tags + 1] = '<script defer src="' .. util.escape_html(asset_base .. "/js/page.js")
    .. "?v=" .. page_js_fingerprint .. '"></script>'
  return table.concat(tags, "\n")
end

local line_breaking_files = {
  "js/vendor/typeset/linked-list.js",
  "js/vendor/typeset/linebreak.js",
  "js/vendor/hypher/hypher.browser.js",
  "js/vendor/hyphenation-patterns/en-us.js",
  "js/line-breaking.js",
}

local function line_breaking_assets(meta, line_breaking_stylesheet_fingerprint)
  local assets_dir = stringify(meta["pandocmd-assets-dir"] or "assets")
  local asset_base = stringify(meta["pandocmd-asset-base-url"] or ""):gsub("/+$", "")
  local contents = {}
  for _, relative_path in ipairs(line_breaking_files) do
    local path = util.join_path(assets_dir, relative_path)
    contents[#contents + 1] = util.read_file(path)
      or error("could not read line-breaking asset " .. path)
  end
  local fingerprint = pandoc.sha1(table.concat(contents, "\0"))
  local query = "?v=" .. fingerprint
  local function asset_url(path)
    return util.escape_html(asset_base .. "/" .. path)
  end
  local tags = {
    '<meta name="pandocmd-line-breaking-fingerprint" content="' .. fingerprint .. '" />',
    '<link rel="stylesheet" href="' .. asset_url("css/line-breaking.css")
      .. "?v=" .. line_breaking_stylesheet_fingerprint .. '" />',
    '<script defer src="' .. asset_url("js/vendor/typeset/linked-list.js") .. query .. '"></script>',
    '<script defer src="' .. asset_url("js/vendor/typeset/linebreak.js") .. query .. '"></script>',
    '<script defer src="' .. asset_url("js/vendor/hypher/hypher.browser.js") .. query .. '"></script>',
    '<script defer src="' .. asset_url("js/vendor/hyphenation-patterns/en-us.js") .. query .. '"></script>',
    '<script defer src="' .. asset_url("js/line-breaking.js") .. query .. '"></script>',
  }
  return table.concat(tags, "\n")
end

function Writer(doc, opts)
  local custom_section_numbers = doc.meta["pandocmd-custom-section-numbers"] == true
  local html_opts = pandoc.WriterOptions({
    html_math_method = "katex",
    number_sections = not custom_section_numbers,
  })
  local body = pandoc.write(doc, "html5", html_opts)
  local title = meta_inline_html(doc.meta.title)
  local abstract = raw_meta_blocks(doc.meta.abstract)
  local abstract_title = meta_inline_html(doc.meta["abstract-title"] or pandoc.List({ pandoc.Str("Abstract") }))
  local asset_base = stringify(doc.meta["pandocmd-asset-base-url"] or ""):gsub("/+$", "")
  local template = util.read_file(template_path(doc.meta))
    or error("could not read pandocmd template")
  local template_source = template

  template = apply_conditional(template, "title", title ~= "")
  template = apply_conditional(template, "abstract", abstract ~= "")
  local stylesheets = raw_meta_blocks(doc.meta.stylesheets)
  local stylesheet_fingerprint
  local line_breaking_stylesheet_fingerprint
  if stylesheets ~= "" then
    stylesheets = stylesheets .. "\n"
  end
  stylesheets, stylesheet_fingerprint, line_breaking_stylesheet_fingerprint =
    stylesheet_assets(doc.meta, stylesheets)
  template = replace_field(template, "title", title)
  template = replace_field(template, "abstract-title", abstract_title)
  template = replace_field(template, "abstract", abstract)
  template = replace_field(template, "asset-base", asset_base)
  template = replace_field(template, "stylesheets", stylesheets)
  template = replace_field(
    template,
    "line-breaking-assets",
    line_breaking_assets(doc.meta, line_breaking_stylesheet_fingerprint)
  )
  template = replace_field(
    template,
    "page-runtime-assets",
    page_runtime_assets(doc.meta, stylesheet_fingerprint, template_source)
  )
  template = replace_field(template, "toc", raw_meta_blocks(doc.meta.toc))
  template = replace_field(template, "body", body)

  return template
end
