-- Hakyll-style page writer for the pandocmd Pandoc Lua prototype.
--
-- Pandoc's template engine reindents multiline variables. Hakyll's
-- loadAndApplyTemplate substitutes the already-rendered HTML fragment
-- literally, so this writer keeps the final page closer to the current output.

local stringify = pandoc.utils.stringify

local function read_file(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

local function join_path(a, b)
  if b == nil or b == "" then
    return a
  end
  if starts_with(b, "/") or b:match("^%a:[/\\]") then
    return b
  end
  if a == nil or a == "" or a == "." then
    return b
  end
  return a:gsub("[/\\]$", "") .. "/" .. b
end

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

local function template_path(meta)
  local from_env = os.getenv("PANDOCMD_TEMPLATE")
  if from_env and from_env ~= "" then
    return from_env
  end
  if meta.pandocmd and meta.pandocmd.template then
    return stringify(meta.pandocmd.template)
  end
  local assets = stringify(meta["pandocmd-assets-dir"] or "assets")
  return join_path(assets, "templates/default.html")
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

local function apply_title_conditional(template, has_title)
  return apply_conditional(template, "title", has_title)
end

local function replace_field(template, name, value)
  local escaped = name:gsub("([^%w])", "%%%1")
  return template:gsub("%$" .. escaped .. "%$", function()
    return value
  end)
end

local function live_reload_script()
  local enabled = os.getenv("PANDOCMD_PREVIEW_LIVE_RELOAD")
  if not enabled or enabled == "" then
    return ""
  end

  local token = enabled:gsub("[^%w%-]", "")
  if token == "" or token == "1" then
    token = (tostring(os.time()) .. "-" .. tostring({})):gsub("[^%w%-]", "")
  end
  local script = [==[
    <script data-pandocmd-live-reload-token="__TOKEN__">
        (function () {
            var baseline = "__TOKEN__";
            var delay = 150;
            var path = window.location.pathname;
            var signalPath = path.replace(/\.html$/, ".reload");

            function poll() {
                window.fetch(signalPath, { cache: "no-store" })
                    .then(function (response) {
                        if (!response.ok) {
                            return null;
                        }

                        return response.text();
                    })
                    .then(function (next) {
                        if (typeof next === "string") {
                            next = next.trim();
                        }

                        if (next === null) {
                            return;
                        }

                        if (next === baseline) {
                            return;
                        }

                        if (next) {
                            window.location.reload();
                        }
                    })
                    .catch(function () {
                        return;
                    });
            }

            window.setInterval(poll, delay);
        }());
    </script>
]==]

  return script:gsub("__TOKEN__", token)
end

function Writer(doc, opts)
  local html_opts = pandoc.WriterOptions({
    html_math_method = "mathml",
    number_sections = false,
    toc_depth = 2,
  })
  local body = pandoc.write(doc, "html5", html_opts)
  local title = stringify(doc.meta.title or "")
  local has_title = title ~= ""
  local abstract = raw_meta_blocks(doc.meta.abstract)
  local has_abstract = abstract ~= ""
  local abstract_title = stringify(doc.meta["abstract-title"] or "Abstract")
  local template = read_file(template_path(doc.meta))
    or error("could not read pandocmd template")

  template = apply_title_conditional(template, has_title)
  template = apply_conditional(template, "abstract", has_abstract)
  local stylesheets = raw_meta_blocks(doc.meta.stylesheets)
  if stylesheets ~= "" then
    stylesheets = stylesheets .. "\n"
  end
  template = replace_field(template, "title", title)
  template = replace_field(template, "abstract-title", abstract_title)
  template = replace_field(template, "abstract", abstract)
  template = replace_field(template, "stylesheets", stylesheets)
  template = replace_field(template, "toc", raw_meta_blocks(doc.meta.toc))
  template = replace_field(template, "live-reload", live_reload_script())
  template = replace_field(template, "body", body)

  return template
end
