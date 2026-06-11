-- Pandoc reader for pandocmd Markdown.
--
-- This keeps the pre-parse parts of ChaoDoc.hs in Lua:
--   * normalize theorem fence titles written after the attribute block
--   * inject source-line marker comments
--   * prepend TeX macros before Pandoc's markdown reader runs

local reader_format = "markdown+tex_math_double_backslash+tex_math_single_backslash+latex_macros+raw_tex"
local stringify = pandoc.utils.stringify

local default_block_specs = {
  Theorem = { title = "Theorem", numbered = true },
  Conjecture = { title = "Conjecture", numbered = true },
  Definition = { title = "Definition", numbered = true },
  Example = { title = "Example", numbered = true },
  Lemma = { title = "Lemma", numbered = true },
  Problem = { title = "Problem", numbered = true },
  Proposition = { title = "Proposition", numbered = true },
  Corollary = { title = "Corollary", numbered = true },
  Observation = { title = "Observation", numbered = true },
  Figure = { title = "Figure", numbered = true },
  Table = { title = "Table", numbered = true },
  Proof = { title = "Proof", numbered = false },
  Remark = { title = "Remark", numbered = false },
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

local function map_field(value, key)
  if value and pandoc.utils.type(value) == "table" then
    return value[key]
  end
  return nil
end

local function dirname(path)
  local dir = path:match("^(.*)[/\\][^/\\]*$")
  if dir == nil or dir == "" then
    return "."
  end
  return dir
end

local function join_path(a, b)
  if b == nil or b == "" then
    return a
  end
  if b:match("^/") or b:match("^%a:[/\\]") then
    return b
  end
  if a == nil or a == "" or a == "." then
    return b
  end
  return a:gsub("[/\\]$", "") .. "/" .. b
end

local function read_file(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

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
  if not lines[1] or trim(lines[1]) ~= "---" then
    return nil, 1, lines
  end

  local yaml_lines = {}
  for i = 2, #lines do
    local stripped = trim(lines[i])
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

local function title_case(s)
  return (s:gsub("(%a)([%w_%-]*)", function(first, rest)
    return first:upper() .. rest:lower()
  end))
end

local function block_specs(meta)
  local specs = {}
  for class, spec in pairs(default_block_specs) do
    specs[class] = { title = spec.title, numbered = spec.numbered }
  end
  local blocks = meta.blocks
  if pandoc.utils.type(blocks) ~= "table" then
    return specs
  end
  for class, spec in pairs(blocks) do
    local key = title_case(class)
    local counter = map_field(spec, "counter")
    local title = map_field(spec, "title")
    counter = counter and stringify(counter) or nil
    specs[key] = {
      title = title and stringify(title) or title_case(class),
      numbered = not (counter == "none" or counter == "false"),
    }
  end
  return specs
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
    if cls and specs[title_case(cls)] then
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
  for _, token in ipairs(ids) do
    table.insert(normalized, token)
  end
  for _, token in ipairs(classes) do
    table.insert(normalized, token)
  end
  for _, token in ipairs(others) do
    table.insert(normalized, token)
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
  local attr_body, after_attr = trim(after_fence):match("^%{(.-)%}(.*)$")
  if not attr_body then
    return line
  end
  local normalized_attrs, tokens = normalize_fenced_div_attrs(attr_body)
  local suffix = after_attr
  local title = trim(after_attr)
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

local function leading_indent(line)
  return line:match("^(%s*)")
end

local function marker_line(line_no, line)
  return leading_indent(line) .. "<!-- pandocmd-source-line:" .. tostring(line_no) .. " -->"
end

local function opens_code_fence(line)
  local stripped = line:gsub("^%s+", "")
  local c = stripped:sub(1, 1)
  if c ~= "`" and c ~= "~" then
    return nil
  end
  local fence = stripped:match("^" .. c:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "+")
  if fence and #fence >= 3 then
    return fence
  end
  return nil
end

local function closes_code_fence(fence, line)
  local c = fence:sub(1, 1)
  local stripped = line:gsub("^%s+", "")
  local closing = stripped:match("^" .. c:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "+") or ""
  local rest = stripped:sub(#closing + 1)
  return #closing >= #fence and rest:match("^%s*$") ~= nil
end

local function opens_display_math(line)
  local stripped = line:gsub("^%s+", "")
  if starts_with(stripped, "$$") then
    return "$$"
  elseif starts_with(stripped, "\\[") then
    return "\\]"
  end
  return nil
end

local function closes_math_fence(fence, line)
  return trim(line):find(fence, 1, true) ~= nil
end

local function closes_display_math_on_opening_line(fence, line)
  local stripped = line:gsub("^%s+", "")
  if fence == "$$" then
    local _, count = stripped:gsub("%$%$", "")
    return count >= 2
  elseif fence == "\\]" then
    return stripped:sub(3):find("\\]", 1, true) ~= nil
  end
  return false
end

local function starts_with_space(text)
  return text:match("^%s") ~= nil
end

local function is_indented_code_start(line)
  return starts_with(line, "    ") or starts_with(line, "\t")
end

local function is_header_start(line)
  local rest = line:match("^#(.*)$")
  return rest ~= nil and (rest == "" or starts_with_space(rest))
end

local function is_list_start(line)
  if line:match("^[-+*]%s") then
    return true
  end
  return line:match("^%d%d?%d?%d?%d?%d?%d?%d?%d?[.)]%s") ~= nil
end

local function is_thematic_break(line)
  local chars = line:gsub("%s+", "")
  return #chars >= 3 and (chars:match("^%-+$") or chars:match("^%*+$") or chars:match("^_+$"))
end

local function is_fenced_div_opening(line)
  local stripped = line:gsub("^%s+", "")
  local fence, rest = stripped:match("^(:+)(.*)$")
  if not fence or #fence < 3 then
    return false
  end
  rest = trim(rest)
  return rest:match("^%{.*%}$") ~= nil or rest:match("^[%w_%-]+$") ~= nil
end

local function is_fenced_div_closing(line)
  local stripped = line:gsub("^%s+", "")
  local fence, rest = stripped:match("^(:+)(.*)$")
  return fence ~= nil and #fence >= 3 and trim(rest) == ""
end

local function is_non_paragraph_block_start(line)
  local stripped = line:gsub("^%s+", "")
  return is_indented_code_start(line)
    or is_header_start(stripped)
    or starts_with(stripped, ">")
    or is_list_start(stripped)
    or is_thematic_break(stripped)
    or starts_with(stripped, "|")
    or starts_with(stripped, "<")
    or (starts_with(stripped, "[") and stripped:find("]:", 1, true) ~= nil)
    or starts_with(stripped, "{#")
    or starts_with(stripped, "{.")
end

local function annotate_source_lines(start_line, lines)
  local out = {}
  local in_paragraph = false
  local code_fence = nil
  local math_fence = nil
  local math_resumes_paragraph = false

  for i, line in ipairs(lines) do
    local line_no = start_line + i - 1
    if code_fence then
      table.insert(out, line)
      if closes_code_fence(code_fence, line) then
        code_fence = nil
      end
      in_paragraph = false
    elseif math_fence then
      table.insert(out, line)
      if closes_math_fence(math_fence, line) then
        in_paragraph = math_resumes_paragraph
        math_fence = nil
      end
    elseif trim(line) == "" then
      table.insert(out, line)
      in_paragraph = false
    elseif is_indented_code_start(line) then
      table.insert(out, line)
      in_paragraph = false
    else
      local fence = opens_code_fence(line)
      local math = opens_display_math(line)
      if fence then
        table.insert(out, line)
        code_fence = fence
        in_paragraph = false
      elseif math then
        table.insert(out, marker_line(line_no, line))
        table.insert(out, line)
        math_resumes_paragraph = in_paragraph
        in_paragraph = closes_display_math_on_opening_line(math, line) and math_resumes_paragraph
        if not closes_display_math_on_opening_line(math, line) then
          math_fence = math
        end
      elseif is_fenced_div_closing(line) then
        table.insert(out, line)
        in_paragraph = false
      elseif in_paragraph then
        table.insert(out, line)
      elseif is_fenced_div_opening(line) then
        table.insert(out, marker_line(line_no, line))
        table.insert(out, line)
        in_paragraph = false
      elseif is_non_paragraph_block_start(line) then
        table.insert(out, line)
        in_paragraph = false
      else
        table.insert(out, marker_line(line_no, line))
        table.insert(out, line)
        in_paragraph = true
      end
    end
  end

  return table.concat(out, "\n")
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
  local assets_dir = map_field(meta.pandocmd, "assets-dir")
  if assets_dir then
    return join_path(dirname(source_name), stringify(assets_dir))
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
    if not starts_with(macro_name, "\\") then
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
  local macro_file = map_field(meta.pandocmd, "macro-file")
  local macro_rel = macro_file and stringify(macro_file) or "math-macros.tex"
  local macros = read_file(join_path(assets_dir, macro_rel)) or read_file(macro_rel) or ""
  local extra_macros = render_extra_macros(meta.math)
  local specs = block_specs(meta)
  local normalized = {}

  for _, line in ipairs(body_lines) do
    table.insert(normalized, normalize_fenced_div(line, specs))
  end

  local annotated = annotate_source_lines(body_start, normalized)
  local meta_prefix = yaml and ("---\n" .. yaml .. "\n---\n\n") or ""
  local prepared = meta_prefix .. macros .. "\n\n" .. extra_macros .. "\n\n" .. annotated
  local doc = pandoc.read(prepared, reader_format, reader_options)

  doc.meta["pandocmd-source-file"] = absolute_path(source)
  doc.meta["pandocmd-assets-dir"] = assets_dir
  return doc
end
