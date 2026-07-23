return {
  Inlines = function(inlines)
    local out = pandoc.List({})
    for _, inline in ipairs(inlines) do
      local previous = out[#out]
      if previous
        and previous.t == "Math"
        and previous.mathtype == "InlineMath"
        and inline.t == "Str"
        and inline.text:sub(1, 1) == "," then
        previous.text = previous.text .. ","
        if #inline.text > 1 then
          out:insert(pandoc.Str(inline.text:sub(2)))
        end
      else
        out:insert(inline)
      end
    end
    return out
  end,
}
