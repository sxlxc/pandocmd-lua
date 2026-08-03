local util = require("util")

local M = {}

local source_line_prefix = "pandocmd-source-line:"
local source_line_attr = "data-source-line"

local function percent_encode_path(path)
  return (path:gsub("([^A-Za-z0-9%-%._~/])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function source_href(source_file, line_no)
  if source_file == nil or source_file == "" then
    return nil
  end
  return "zed://file" .. percent_encode_path(source_file) .. ":" .. line_no
end

local function source_line_label_attr(line_no)
  local label = "Open source line " .. line_no .. " in Zed"
  return util.attr("", { "source-line-link" }, { { "title", label }, { "aria-label", label } })
end

local function source_line_label_inline(source_file, line_no)
  local href = source_href(source_file, line_no)
  if href then
    return pandoc.Link(util.inline_text(line_no), href, "", source_line_label_attr(line_no))
  end
  return pandoc.Span(util.inline_text(line_no), source_line_label_attr(line_no))
end

local function source_line_label_block(source_file, line_no)
  local label = "Open source line " .. line_no .. " in Zed"
  local href = source_href(source_file, line_no)
  if href then
    return pandoc.RawBlock(
      "html",
      '<a class="source-line-link" href="'
        .. util.escape_html(href)
        .. '" title="'
        .. util.escape_html(label)
        .. '" aria-label="'
        .. util.escape_html(label)
        .. '">'
        .. util.escape_html(line_no)
        .. "</a>"
    )
  end
  return pandoc.RawBlock(
    "html",
    '<span class="source-line-link" title="'
      .. util.escape_html(label)
      .. '" aria-label="'
      .. util.escape_html(label)
      .. '">'
      .. util.escape_html(line_no)
      .. "</span>"
  )
end

local function parse_source_line_marker(raw)
  local body = raw:match("^%s*<!%-%-%s*(.-)%s*%-%->%s*$")
  if not body then
    return nil
  end
  body = util.trim(body)
  if util.starts_with(body, source_line_prefix) then
    local line_no = body:sub(#source_line_prefix + 1)
    if line_no:match("^%d+$") then
      return line_no
    end
  end
  return nil
end

local function source_line_marker_block(block)
  if block.t == "RawBlock" and block.format == "html" then
    return parse_source_line_marker(block.text)
  end
  return nil
end

local function source_line_marker_inline(inline)
  if inline.t == "RawInline" and inline.format == "html" then
    return parse_source_line_marker(inline.text)
  end
  return nil
end

local function is_blank_inline(inline)
  return inline.t == "Space"
    or inline.t == "SoftBreak"
    or inline.t == "LineBreak"
    or (inline.t == "Str" and inline.text == "")
end

local function is_display_math_container(inline)
  return inline.t == "Span" and (util.has_class(inline.attr, "equation") or util.has_class(inline.attr, "math-container"))
end

local annotate_source_line_inlines

local function attach_source_line_to_display_math_inline(source_file, line_no, inline)
  if is_display_math_container(inline) then
    util.set_attr(inline.attr, source_line_attr, line_no)
    inline.content:insert(1, source_line_label_inline(source_file, line_no))
    inline.content = annotate_source_line_inlines(source_file, inline.content)
    return inline
  end
  return nil
end

local function attach_source_line_to_next_display_math(source_file, line_no, inlines)
  local out = pandoc.List({})
  local i = 1
  while i <= #inlines and is_blank_inline(inlines[i]) do
    out:insert(inlines[i])
    i = i + 1
  end
  if i <= #inlines then
    local annotated = attach_source_line_to_display_math_inline(source_file, line_no, inlines[i])
    out:insert(annotated or inlines[i])
    i = i + 1
  end
  local rest = pandoc.List({})
  while i <= #inlines do
    rest:insert(inlines[i])
    i = i + 1
  end
  for _, inline in ipairs(annotate_source_line_inlines(source_file, rest)) do
    out:insert(inline)
  end
  return out
end

local function annotate_source_line_inline(source_file, inline)
  if inline.t == "Image" then
    inline.caption = annotate_source_line_inlines(source_file, inline.caption)
  elseif inline.t == "Link" then
    inline.content = annotate_source_line_inlines(source_file, inline.content)
  elseif inline.content then
    inline.content = annotate_source_line_inlines(source_file, inline.content)
  elseif inline.t == "Cite" then
    inline.content = annotate_source_line_inlines(source_file, inline.content)
  end
  return inline
end

annotate_source_line_inlines = function(source_file, inlines)
  local out = pandoc.List({})
  local i = 1
  while i <= #inlines do
    local line_no = source_line_marker_inline(inlines[i])
    if line_no then
      local rest = pandoc.List({})
      for j = i + 1, #inlines do
        rest:insert(inlines[j])
      end
      for _, inline in ipairs(attach_source_line_to_next_display_math(source_file, line_no, rest)) do
        out:insert(inline)
      end
      return out
    else
      out:insert(annotate_source_line_inline(source_file, inlines[i]))
    end
    i = i + 1
  end
  return out
end

local function is_standalone_display_math(inlines)
  local count = 0
  local only = nil
  for _, inline in ipairs(inlines) do
    if not is_blank_inline(inline) then
      count = count + 1
      only = inline
    end
  end
  return count == 1 and only ~= nil and is_display_math_container(only)
end

local function attach_source_line_to_span_class(source_file, class_name, line_no, inlines)
  for _, inline in ipairs(inlines) do
    if inline.t == "Span" and util.has_class(inline.attr, class_name) then
      util.set_attr(inline.attr, source_line_attr, line_no)
      inline.content:insert(1, source_line_label_inline(source_file, line_no))
      return inlines
    elseif inline.t == "Span" then
      local nested = attach_source_line_to_span_class(source_file, class_name, line_no, inline.content)
      if nested then
        inline.content = nested
        return inlines
      end
    end
  end
  return nil
end

local function attach_source_line_to_display_math(source_file, line_no, inlines)
  return attach_source_line_to_span_class(source_file, "equation", line_no, inlines)
    or attach_source_line_to_span_class(source_file, "math-container", line_no, inlines)
end

function M.annotate_blocks(source_file, blocks)
  local out = pandoc.List({})
  local i = 1
  while i <= #blocks do
    local line_no = source_line_marker_block(blocks[i])
    if line_no then
      i = i + 1
      while i <= #blocks and source_line_marker_block(blocks[i]) do
        line_no = source_line_marker_block(blocks[i])
        i = i + 1
      end
      if i <= #blocks then
        out:insert((function(block)
          if block.t == "Div" then
            local div_line_no = line_no
            local children = block.content
            if #children >= 2 and source_line_marker_block(children[1]) then
              local child_line = source_line_marker_block(children[1])
              local first = children[2]
              if (first.t == "Para" or first.t == "Plain") then
                first.content = annotate_source_line_inlines(source_file, first.content)
                if not is_standalone_display_math(first.content) then
                  div_line_no = child_line
                  local new_children = pandoc.List({ first })
                  for j = 3, #children do
                    new_children:insert(children[j])
                  end
                  children = new_children
                end
              end
            end
            util.set_attr(block.attr, source_line_attr, div_line_no)
            block.content = M.annotate_blocks(source_file, children)
            block.content:insert(1, source_line_label_block(source_file, div_line_no))
            return block
          elseif block.t == "Para" or block.t == "Plain" then
            block.content = annotate_source_line_inlines(source_file, block.content)
            if is_standalone_display_math(block.content) and attach_source_line_to_display_math(source_file, line_no, block.content) then
              return block
            end
            return pandoc.Div(
              { source_line_label_block(source_file, line_no), block },
              util.attr("", { "source-line" }, { [source_line_attr] = line_no })
            )
          end
          return block
        end)(blocks[i]))
        i = i + 1
      end
    else
      local block = blocks[i]
      if block.t == "Div" or block.t == "BlockQuote" then
        block.content = M.annotate_blocks(source_file, block.content)
      elseif block.t == "BulletList" or block.t == "OrderedList" then
        local items = pandoc.List({})
        for _, item in ipairs(block.content) do
          items:insert(M.annotate_blocks(source_file, item))
        end
        block.content = items
      end
      out:insert(block)
      i = i + 1
    end
  end
  return out
end

return M
