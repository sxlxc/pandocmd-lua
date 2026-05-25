local M = {}

M.stringify = pandoc.utils.stringify

function M.title_case(s)
  return (s:gsub("(%a)([%w_%-]*)", function(first, rest)
    return first:upper() .. rest:lower()
  end))
end

function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.has_class(attr, class)
  for _, c in ipairs(attr.classes) do
    if c == class then
      return true
    end
  end
  return false
end

function M.add_class(attr, class)
  if not M.has_class(attr, class) then
    attr.classes:insert(1, class)
  end
  return attr
end

function M.set_attr(attr, key, value)
  attr.attributes[key] = value
  return attr
end

function M.attr(identifier, classes, attributes)
  return pandoc.Attr(identifier or "", classes or {}, attributes or {})
end

function M.inline_text(text)
  if text == nil or text == "" then
    return {}
  end
  return { pandoc.Str(text) }
end

function M.meta_to_text(value)
  if value == nil then
    return nil
  end
  return M.stringify(value)
end

function M.meta_bool_false(value)
  local text = M.meta_to_text(value)
  return text == "none" or text == "false"
end

function M.escape_html(s)
  return (s:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local inline_writer_options = pandoc.WriterOptions({
  html_math_method = "mathml",
  wrap_text = "none",
})

function M.inline_html(inlines)
  local html = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines) }), "html5", inline_writer_options)
  html = html:gsub("^<p>", ""):gsub("</p>%s*$", "")
  return html
end

return M
