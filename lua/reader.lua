-- Pandoc reader for pandocmd Markdown.
--
-- This keeps the pre-parse parts of ChaoDoc.hs in Lua:
--   * normalize theorem fence titles written after the attribute block
--   * inject source-line marker comments
--   * prepend TeX macros before Pandoc's markdown reader runs

local script_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or ""
package.path = script_dir .. "?.lua;" .. package.path

local util = require("util")
local theorems = require("theorems")
local source_line_preprocess = require("source-line-preprocess")

local reader_format = "markdown+tex_math_double_backslash+tex_math_single_backslash+latex_macros+raw_tex"
local stringify = pandoc.utils.stringify

local function split_lines(text)
  local lines = {}
  if text == "" then
    return lines
  end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  for line in text:gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return lines
end

local function yaml_front_matter(text)
  local lines = split_lines(text)
  if not lines[1] or util.trim(lines[1]) ~= "---" then
    return nil, 1, lines
  end

  local yaml_lines = {}
  for i = 2, #lines do
    local stripped = util.trim(lines[i])
    if stripped == "---" or stripped == "..." then
      local body_start = i + 1
      local body_lines = {}
      for j = body_start, #lines do
        table.insert(body_lines, lines[j])
      end
      return table.concat(yaml_lines, "\n"), body_start, body_lines
    end
    table.insert(yaml_lines, lines[i])
  end

  return nil, 1, lines
end

local function front_matter(text, reader_options)
  local yaml, body_start, body_lines = yaml_front_matter(text)
  if not yaml then
    return {}, body_start, body_lines, nil
  end
  local doc = pandoc.read("---\n" .. yaml .. "\n---\n", reader_format, reader_options)
  return doc.meta, body_start, body_lines, yaml
end

local function attr_tokens(attrs)
  local tokens = {}
  local token = {}
  local quote = nil
  local escaped = false

  local function flush()
    if #token > 0 then
      table.insert(tokens, table.concat(token))
      token = {}
    end
  end

  for i = 1, #attrs do
    local c = attrs:sub(i, i)
    if quote then
      table.insert(token, c)
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
      table.insert(token, c)
    elseif c:match("%s") then
      flush()
    else
      table.insert(token, c)
    end
  end

  flush()
  return tokens
end

local function attr_token_id(token)
  return token:match("^#(.+)$")
end

local function attr_token_class(token)
  return token:match("^%.([^=]+)$")
end

local function is_theorem_attr(tokens, specs)
  for _, token in ipairs(tokens) do
    local cls = attr_token_class(token)
    if cls and specs[util.title_case(cls)] then
      return true
    end
  end
  return false
end

local function has_attr_key(tokens, key)
  for _, token in ipairs(tokens) do
    if token:match("^" .. key .. "=") then
      return true
    end
  end
  return false
end

local function normalize_fenced_div_attrs(attrs)
  local tokens = attr_tokens(attrs)
  local ids = {}
  local classes = {}
  local others = {}

  for _, token in ipairs(tokens) do
    if attr_token_id(token) then
      table.insert(ids, token)
    elseif attr_token_class(token) then
      table.insert(classes, token)
    else
      table.insert(others, token)
    end
  end

  local normalized = {}
  for _, group in ipairs({ ids, classes, others }) do
    for _, token in ipairs(group) do
      table.insert(normalized, token)
    end
  end

  return table.concat(normalized, " "), tokens
end

local function escape_attr_value(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function normalize_fenced_div(line, specs)
  local indent, rest = line:match("^(%s*)(.*)$")
  local fence, after_fence = rest:match("^(:+)(.*)$")
  if not fence or #fence < 3 then
    return line
  end
  local attr_body, after_attr = util.trim(after_fence):match("^%{(.-)%}(.*)$")
  if not attr_body then
    return line
  end
  local normalized_attrs, tokens = normalize_fenced_div_attrs(attr_body)
  local suffix = after_attr
  local title = util.trim(after_attr)
  if is_theorem_attr(tokens, specs) and title ~= "" then
    suffix = ""
    if not has_attr_key(tokens, "title") then
      normalized_attrs = normalized_attrs .. ' title="' .. escape_attr_value(title) .. '"'
    end
  end

  if normalized_attrs == attr_body and suffix == after_attr then
    return line
  end
  return indent .. fence .. " {" .. normalized_attrs .. "}" .. suffix
end

local function resolve_assets_dir(source_name, meta)
  local cli_assets = os.getenv("PANDOCMD_ASSETS_DIR")
  if cli_assets and cli_assets ~= "" then
    return cli_assets
  end
  local env_assets = os.getenv("HAKYLL_PANDOCMD_ASSETS")
  if env_assets and env_assets ~= "" then
    return env_assets
  end
  local assets_dir = util.map_field(meta.pandocmd, "assets-dir")
  if assets_dir then
    return util.join_path(util.dirname(source_name), stringify(assets_dir))
  end
  return "assets"
end

local function render_extra_macros(math_meta)
  local lines = {}
  if pandoc.utils.type(math_meta) ~= "table" then
    return ""
  end
  for name, body in pairs(math_meta or {}) do
    local macro_name = name
    if not util.starts_with(macro_name, "\\") then
      macro_name = "\\" .. macro_name
    end
    table.insert(lines, "\\providecommand{" .. macro_name .. "}{}")
    table.insert(lines, "\\renewcommand{" .. macro_name .. "}{" .. stringify(body) .. "}")
  end
  return table.concat(lines, "\n")
end

local function source_name(input)
  if input and input[1] and input[1].name and input[1].name ~= "" then
    return input[1].name
  end
  return "."
end

local function absolute_path(path)
  if path == nil or path == "" or path == "." then
    return path
  end
  if pandoc.path.is_absolute(path) then
    return pandoc.path.normalize(path)
  end
  return pandoc.path.normalize(pandoc.path.join({ pandoc.system.get_working_directory(), path }))
end

function Reader(input, reader_options)
  local source = source_name(input)
  local text = tostring(input)
  local meta, body_start, body_lines, yaml = front_matter(text, reader_options)
  local assets_dir = resolve_assets_dir(source, meta)
  local macro_file = util.map_field(meta.pandocmd, "macro-file")
  local macro_rel = macro_file and stringify(macro_file) or "math-macros.tex"
  local macros = util.read_file(util.join_path(assets_dir, macro_rel)) or util.read_file(macro_rel) or ""
  local extra_macros = render_extra_macros(meta.math)
  local specs = theorems.build_block_specs(meta)
  local normalized = {}

  for _, line in ipairs(body_lines) do
    table.insert(normalized, normalize_fenced_div(line, specs))
  end

  local annotated = source_line_preprocess.annotate_source_lines(body_start, normalized)
  local meta_prefix = yaml and ("---\n" .. yaml .. "\n---\n\n") or ""
  local prepared = meta_prefix .. macros .. "\n\n" .. extra_macros .. "\n\n" .. annotated
  local doc = pandoc.read(prepared, reader_format, reader_options)

  doc.meta["pandocmd-source-file"] = absolute_path(source)
  doc.meta["pandocmd-assets-dir"] = assets_dir
  return doc
end
