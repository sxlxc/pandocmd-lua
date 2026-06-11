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
  if value == false then
    return true
  end
  local text = M.meta_to_text(value)
  text = text and text:lower() or nil
  return text == "none" or text == "false"
end

function M.escape_html(s)
  return (s:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function M.walk_blocks(blocks, visit)
  for i, block in ipairs(blocks) do
    if block.t == "BulletList" or block.t == "OrderedList" then
      for _, item in ipairs(block.content) do
        M.walk_blocks(item, visit)
      end
    elseif block.t == "DefinitionList" then
      for _, item in ipairs(block.content) do
        for _, definition in ipairs(item[2]) do
          M.walk_blocks(definition, visit)
        end
      end
    elseif (block.t == "Div" or block.t == "BlockQuote") and block.content then
      block.content = M.walk_blocks(block.content, visit)
    elseif block.content and block.t ~= "Header" and pandoc.utils.type(block.content) == "Blocks" then
      block.content = M.walk_blocks(block.content, visit)
    end

    local replacement = visit(block)
    if replacement ~= nil then
      blocks[i] = replacement
    end
  end
  return blocks
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
