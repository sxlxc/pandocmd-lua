-- Pandoc reader for pandocmd Markdown.
--
-- This keeps the pre-parse parts of ChaoDoc.hs in Lua:
--   * normalize theorem fence titles written after the attribute block
--   * inject source-line marker comments
--   * prepend TeX macros before Pandoc's markdown reader runs

Extensions = {
  tex_math_double_backslash = true,
  tex_math_single_backslash = true,
  latex_macros = true,
  raw_tex = true,
}

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

local function unquote_yaml_scalar(value)
  value = trim(value or "")
  local q = value:sub(1, 1)
  if (q == '"' or q == "'") and value:sub(-1) == q then
    value = value:sub(2, -2)
  end
  return value:gsub('\\"', '"'):gsub("\\\\", "\\")
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

local function parse_front_matter(text)
  local yaml, body_start, body_lines = yaml_front_matter(text)
  local config = {
    pandocmd = {},
    math = {},
    blocks = {},
    bibliography = nil,
  }
  if not yaml then
    return config, body_start, body_lines, yaml
  end

  local section = nil
  local block_name = nil
  for _, line in ipairs(split_lines(yaml)) do
    if line:match("^%s*$") or line:match("^%s*#") then
      goto continue
    end

    local top_key, top_value = line:match("^([%w_%-]+):%s*(.-)%s*$")
    if top_key and not line:match("^%s") then
      section = top_key
      block_name = nil
      if top_key == "bibliography" and top_value ~= "" then
        config.bibliography = unquote_yaml_scalar(top_value)
      end
      goto continue
    end

    if section == "pandocmd" then
      local key, value = line:match("^%s+([%w_%-]+):%s*(.-)%s*$")
      if key and value ~= "" then
        config.pandocmd[key] = unquote_yaml_scalar(value)
      end
    elseif section == "math" then
      local key, value = line:match("^%s+([^:]+):%s*(.-)%s*$")
      if key and value ~= "" then
        config.math[trim(key)] = unquote_yaml_scalar(value)
      end
    elseif section == "blocks" then
      local name = line:match("^%s+([%w_%-]+):%s*$")
      if name then
        block_name = name
        config.blocks[block_name] = config.blocks[block_name] or {}
      else
        local key, value = line:match("^%s+%s+([%w_%-]+):%s*(.-)%s*$")
        if block_name and key and value ~= "" then
          config.blocks[block_name][key] = unquote_yaml_scalar(value)
        end
      end
    end

    ::continue::
  end

  return config, body_start, body_lines, yaml
end

local function title_case(s)
  return (s:gsub("(%a)([%w_%-]*)", function(first, rest)
    return first:upper() .. rest:lower()
  end))
end

local function block_specs(config)
  local specs = {}
  for class, spec in pairs(default_block_specs) do
    specs[class] = { title = spec.title, numbered = spec.numbered }
  end
  for class, spec in pairs(config.blocks or {}) do
    local key = title_case(class)
    local counter = spec.counter
    specs[key] = {
      title = spec.title or title_case(class),
      numbered = not (counter == "none" or counter == "false"),
    }
  end
  return specs
end

local function is_theorem_attr(attrs, specs)
  for cls in attrs:gmatch("%.[%w_%-]+") do
    if specs[title_case(cls:sub(2))] then
      return true
    end
  end
  return false
end

local function escape_attr_value(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function normalize_theorem_fence_title(line, specs)
  local indent, rest = line:match("^(%s*)(.*)$")
  local fence, after_fence = rest:match("^(:+)(.*)$")
  if not fence or #fence < 3 then
    return line
  end
  local attr_body, after_attr = trim(after_fence):match("^%{(.-)%}(.*)$")
  if not attr_body then
    return line
  end
  local title = trim(after_attr)
  if title == "" or not is_theorem_attr(attr_body, specs) then
    return line
  end
  return indent .. fence .. " {" .. attr_body .. ' title="' .. escape_attr_value(title) .. '"}'
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
  return fence ~= nil and #fence >= 3 and trim(rest) ~= ""
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

local function resolve_assets_dir(source_name, config)
  local cli_assets = os.getenv("PANDOCMD_ASSETS_DIR")
  if cli_assets and cli_assets ~= "" then
    return cli_assets
  end
  local env_assets = os.getenv("HAKYLL_PANDOCMD_ASSETS")
  if env_assets and env_assets ~= "" then
    return env_assets
  end
  if config.pandocmd and config.pandocmd["assets-dir"] then
    return join_path(dirname(source_name), config.pandocmd["assets-dir"])
  end
  return "assets"
end

local function render_extra_macros(math)
  local lines = {}
  for name, body in pairs(math or {}) do
    if not starts_with(name, "\\") then
      name = "\\" .. name
    end
    table.insert(lines, "\\providecommand{" .. name .. "}{}")
    table.insert(lines, "\\renewcommand{" .. name .. "}{" .. body .. "}")
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
  local config, body_start, body_lines, yaml = parse_front_matter(text)
  local assets_dir = resolve_assets_dir(source, config)
  local macro_rel = (config.pandocmd and config.pandocmd["macro-file"]) or "math-macros.tex"
  local macros = read_file(join_path(assets_dir, macro_rel)) or read_file(macro_rel) or ""
  local extra_macros = render_extra_macros(config.math)
  local specs = block_specs(config)
  local normalized = {}

  for _, line in ipairs(body_lines) do
    table.insert(normalized, normalize_theorem_fence_title(line, specs))
  end

  local annotated = annotate_source_lines(body_start, normalized)
  local meta_prefix = yaml and ("---\n" .. yaml .. "\n---\n\n") or ""
  local prepared = meta_prefix .. macros .. "\n\n" .. extra_macros .. "\n\n" .. annotated
  local doc = pandoc.read(prepared, "markdown+tex_math_double_backslash+tex_math_single_backslash+latex_macros+raw_tex", reader_options)

  doc.meta["pandocmd-source-file"] = absolute_path(source)
  doc.meta["pandocmd-assets-dir"] = assets_dir
  return doc
end
