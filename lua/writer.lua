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

local function js_string(value)
  local replacements = {
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["<"] = "\\u003c",
    [">"] = "\\u003e",
    ["&"] = "\\u0026",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
  }
  return '"' .. value:gsub('[\\"<>&\n\r\t]', replacements) .. '"'
end

local function live_reload_script()
  local endpoint = os.getenv("PANDOCMD_PREVIEW_LIVE_RELOAD_URL")
  if not endpoint or endpoint == "" then
    return ""
  end

  local script = [==[
    <script>
        (function () {
            if (!("WebSocket" in window)) {
                return;
            }

            var endpoint = __ENDPOINT__;
            var retryDelay = 1000;

            function socketUrl() {
                if (/^wss?:\/\//.test(endpoint)) {
                    return endpoint;
                }

                return (window.location.protocol === "https:" ? "wss://" : "ws://") +
                    window.location.host + endpoint;
            }

            function connect() {
                var socket;

                try {
                    socket = new WebSocket(socketUrl());
                } catch (error) {
                    retry();
                    return;
                }

                socket.addEventListener("open", function () {
                    socket.send(JSON.stringify({
                        command: "hello",
                        protocols: ["http://livereload.com/protocols/official-7"]
                    }));
                });

                socket.addEventListener("message", function (event) {
                    var message;

                    try {
                        message = JSON.parse(event.data);
                    } catch (error) {
                        return;
                    }

                    if (message.command === "reload") {
                        if (window.__pandocmd && typeof window.__pandocmd.softReload === "function") {
                            window.__pandocmd.softReload();
                        } else {
                            window.location.reload();
                        }
                    }
                });

                socket.addEventListener("close", retry);
            }

            function retry() {
                window.setTimeout(connect, retryDelay);
            }

            connect();
        }());
    </script>
]==]

  return script:gsub("__ENDPOINT__", js_string(endpoint))
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

  template = apply_conditional(template, "title", title ~= "")
  template = apply_conditional(template, "abstract", abstract ~= "")
  local stylesheets = raw_meta_blocks(doc.meta.stylesheets)
  if stylesheets ~= "" then
    stylesheets = stylesheets .. "\n"
  end
  template = replace_field(template, "title", title)
  template = replace_field(template, "abstract-title", abstract_title)
  template = replace_field(template, "abstract", abstract)
  template = replace_field(template, "asset-base", asset_base)
  template = replace_field(template, "stylesheets", stylesheets)
  template = replace_field(template, "toc", raw_meta_blocks(doc.meta.toc))
  template = replace_field(template, "live-reload", live_reload_script())
  template = replace_field(template, "body", body)

  return template
end
