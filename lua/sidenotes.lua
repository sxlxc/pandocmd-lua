local util = require("util")

local M = {}

local html_writer_options = pandoc.WriterOptions({ html_math_method = "mathml" })

local function note_html(blocks)
  local html = pandoc.write(pandoc.Pandoc(blocks), "html5", html_writer_options)
  html = html:gsub("^<p>", ""):gsub("</p>%s*$", "")
  return html
end

function M.render_blocks(blocks)
  local counter = -1
  local function render_inlines(inlines)
    local out_blocks = pandoc.List({})
    local acc = pandoc.List({})
    local function flush()
      out_blocks:insert(pandoc.Plain(acc))
      acc = pandoc.List({})
    end
    for _, inline in ipairs(inlines) do
      if inline.t == "Note" then
        local note_body = note_html(inline.content)
        local typ = "Sidenote"
        if util.starts_with(note_body, "{-} ") then
          typ = "Marginnote"
          note_body = note_body:sub(5)
        end
        counter = counter + 1
        acc:insert(pandoc.RawInline("html", "<!--"))
        flush()
        local cls = typ == "Sidenote" and "sidenote" or "marginnote"
        local label_class = typ == "Sidenote" and "margin-toggle sidenote-number" or "margin-toggle"
        local symbol = typ == "Sidenote" and "" or "&#8853;"
        out_blocks:insert(pandoc.RawBlock(
          "html",
          "-->"
            .. '<label for="sn-'
            .. counter
            .. '" class="'
            .. label_class
            .. '">'
            .. symbol
            .. "</label>"
            .. '<input type="checkbox" id="sn-'
            .. counter
            .. '" class="margin-toggle"/>'
            .. '<div class="'
            .. cls
            .. '">'
            .. note_body
            .. "</div>"
            .. "<!--"
        ))
        acc:insert(pandoc.RawInline("html", "-->"))
      else
        acc:insert(inline)
      end
    end
    flush()
    return out_blocks
  end

  local function walk(block_list)
    local out = pandoc.List({})
    for _, block in ipairs(block_list) do
      if block.t == "Para" then
        out:insert(pandoc.Para({ pandoc.Str("") }))
        for _, b in ipairs(render_inlines(block.content)) do
          out:insert(b)
        end
      elseif block.t == "Plain" then
        for _, b in ipairs(render_inlines(block.content)) do
          out:insert(b)
        end
      elseif block.t == "BulletList" or block.t == "OrderedList" then
        local items = pandoc.List({})
        for _, item in ipairs(block.content) do
          items:insert(walk(item))
        end
        block.content = items
        out:insert(block)
      elseif block.content then
        block.content = walk(block.content)
        out:insert(block)
      else
        out:insert(block)
      end
    end
    if #out > 0 and out[1].t == "Para" and #out[1].content == 1 and out[1].content[1].t == "Str" and out[1].content[1].text == "" then
      out:remove(1)
    end
    return out
  end

  return walk(blocks)
end

return M
