local M = {}

local cjk_ranges = {
  { 0x2e80, 0x2eff },
  { 0x2f00, 0x2fdf },
  { 0x3040, 0x309f },
  { 0x30a0, 0x30fa },
  { 0x30fc, 0x30ff },
  { 0x3100, 0x312f },
  { 0x3200, 0x32ff },
  { 0x3400, 0x4dbf },
  { 0x4e00, 0x9fff },
  { 0xf900, 0xfaff },
}

local function is_cjk_char(c)
  if c == nil or c == "" then
    return false
  end
  local code = utf8.codepoint(c)
  for _, range in ipairs(cjk_ranges) do
    if code >= range[1] and code <= range[2] then
      return true
    end
  end
  return false
end

local function first_utf8_char(s)
  local _, end_pos = utf8.offset(s, 2)
  if end_pos then
    return s:sub(1, end_pos - 1)
  end
  return s
end

local function last_utf8_char(s)
  local start_pos = utf8.offset(s, -1)
  if start_pos then
    return s:sub(start_pos)
  end
  return s
end

local function last_char(inline)
  if inline.t == "Str" then
    return last_utf8_char(inline.text)
  elseif inline.content and #inline.content > 0 then
    return last_char(inline.content[#inline.content])
  end
  return nil
end

local function first_char(inline)
  if inline.t == "Str" then
    return first_utf8_char(inline.text)
  elseif inline.content and #inline.content > 0 then
    return first_char(inline.content[1])
  end
  return nil
end

local function convert_fullwidth(c)
  local map = {
    [":"] = "：",
    ["."] = "。",
    ["~"] = "～",
    ["!"] = "！",
    ["?"] = "？",
    [","] = "，",
    [";"] = "；",
    ['"'] = "”",
    ["'"] = "’",
  }
  return map[c] or c
end

local function pangu_text(s)
  local contains_cjk = false
  for _, code in utf8.codes(s) do
    for _, range in ipairs(cjk_ranges) do
      if code >= range[1] and code <= range[2] then
        contains_cjk = true
        break
      end
    end
    if contains_cjk then
      break
    end
  end
  if not contains_cjk then
    return s
  end

  s = s:gsub("([一-龯])%s*(:+)%s*([一-龯])", function(a, sym, b)
    return a .. sym:gsub(".", convert_fullwidth) .. b
  end)
  s = s:gsub("([一-龯])%s*([%.])%s*([一-龯])", function(a, sym, b)
    return a .. convert_fullwidth(sym) .. b
  end)
  s = s:gsub("([一-龯])%s*([~!?,;]+)%s*", function(a, sym)
    return a .. sym:gsub(".", convert_fullwidth)
  end)
  s = s:gsub("([%w@$%%%^&%*%-%+\\=|/])([一-龯])", "%1 %2")
  s = s:gsub("([一-龯])([%w@$%%%^&%*%-%+\\=|/])", "%1 %2")
  return s
end

local pangu_inlines

local function pangu_inline(inline)
  if inline.t == "Str" then
    inline.text = pangu_text(inline.text)
  elseif inline.content then
    inline.content = pangu_inlines(inline.content)
  end
  return inline
end

pangu_inlines = function(inlines)
  local out = pandoc.List({})
  for _, inline in ipairs(inlines) do
    local current = pangu_inline(inline)
    local previous = out[#out]
    if previous then
      local lc = last_char(previous)
      local fc = first_char(current)
      if lc and fc and is_cjk_char(lc) ~= is_cjk_char(fc) then
        out:insert(pandoc.Space())
      end
    end
    out:insert(current)
  end
  return out
end

function M.blocks(blocks)
  for _, block in ipairs(blocks) do
    if block.t == "Para" then
      block.content = pangu_inlines(block.content)
    elseif block.content then
      M.blocks(block.content)
    end
  end
  return blocks
end

return M
