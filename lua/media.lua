-- Late preview-only media pass for standard Pandoc Image nodes.
--
-- When the preview wrapper supplies PANDOCMD_MEDIA_DIR, local images are
-- copied into that staging directory and rewritten to the matching preview
-- URL. Direct Pandoc builds do not set the variable and remain unchanged.

local util = require("util")

local M = {}

local function is_remote(target)
  if target:match("^//") or target:match("^#") then
    return true
  end
  local scheme = target:match("^([%a][%w+%.%-]*):")
  return scheme ~= nil and scheme:lower() ~= "file"
end

local function percent_decode(value)
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function local_target(target)
  local path = target:gsub("[?#].*$", "")
  if path:match("^file://localhost/") then
    path = path:sub(#"file://localhost" + 1)
  elseif path:match("^file:///") then
    path = path:sub(#"file://" + 1)
  end
  return percent_decode(path)
end

local function absolute_path(path)
  if pandoc.path.is_absolute(path) then
    return pandoc.path.normalize(path)
  end
  return pandoc.path.normalize(pandoc.path.join({ pandoc.system.get_working_directory(), path }))
end

local function split_resource_path(value)
  local paths = {}
  if not value or value == "" then
    return paths
  end
  -- This preview runtime targets macOS, where ':' is the path-list separator.
  for path in (value .. ":"):gmatch("(.-):") do
    if path ~= "" then
      table.insert(paths, path)
    end
  end
  return paths
end

local function file_exists(path)
  local handle = io.open(path, "rb")
  if not handle then
    return false
  end
  handle:close()
  return true
end

local function resolve_source(path, source_dir)
  local candidates = {}
  if pandoc.path.is_absolute(path) then
    table.insert(candidates, pandoc.path.normalize(path))
  else
    table.insert(candidates, pandoc.path.normalize(pandoc.path.join({ source_dir, path })))
    for _, root in ipairs(split_resource_path(os.getenv("PANDOCMD_RESOURCE_PATH"))) do
      local candidate = pandoc.path.normalize(pandoc.path.join({ root, path }))
      local duplicate = false
      for _, existing in ipairs(candidates) do
        if candidate == existing then
          duplicate = true
          break
        end
      end
      if not duplicate then
        table.insert(candidates, candidate)
      end
    end
  end
  for _, candidate in ipairs(candidates) do
    if file_exists(candidate) then
      return absolute_path(candidate), absolute_path(candidates[1])
    end
  end
  return nil, absolute_path(candidates[1] or path)
end

local function path_within(path, directory)
  local prefix = directory:gsub("/$", "") .. "/"
  return path:sub(1, #prefix) == prefix
end

local function short_hash(value)
  if pandoc.utils.sha1 then
    return pandoc.utils.sha1(value):sub(1, 8)
  end
  local hash = 5381
  for i = 1, #value do
    hash = (hash * 33 + value:byte(i)) % 4294967296
  end
  return string.format("%08x", hash)
end

local function basename(path)
  return path:match("([^/\\]+)$") or "media"
end

local function destination_relative(source, source_dir)
  source_dir = source_dir:gsub("/$", "")
  if path_within(source, source_dir) then
    return source:sub(#source_dir + 2)
  end
  return short_hash(source) .. "-" .. basename(source)
end

local function add_hash_suffix(path, source)
  local stem, extension = path:match("^(.*)(%.[^./]+)$")
  if not stem then
    stem, extension = path, ""
  end
  return stem .. "-" .. short_hash(source) .. extension
end

local function url_encode_path(path)
  return (path:gsub("([^%w%-%._~/])", function(character)
    local encoded = {}
    for i = 1, #character do
      table.insert(encoded, string.format("%%%02X", character:byte(i)))
    end
    return table.concat(encoded)
  end))
end

local function copy_file(source, destination)
  local input, input_error = io.open(source, "rb")
  if not input then
    error("pandocmd media: could not read " .. source .. ": " .. tostring(input_error))
  end
  pandoc.system.make_directory(util.dirname(destination), true)
  local output, output_error = io.open(destination, "wb")
  if not output then
    input:close()
    error("pandocmd media: could not write " .. destination .. ": " .. tostring(output_error))
  end
  while true do
    local chunk = input:read(1024 * 1024)
    if not chunk then
      break
    end
    output:write(chunk)
  end
  input:close()
  output:close()
end

local function manifest_recorder(path)
  local recorded = {}
  if not path or path == "" then
    return function() end
  end
  local handle, open_error = io.open(path, "w")
  if not handle then
    error("pandocmd media: could not create dependency manifest: " .. tostring(open_error))
  end
  handle:close()
  return function(dependency)
    if recorded[dependency] then
      return
    end
    recorded[dependency] = true
    local output, append_error = io.open(path, "a")
    if not output then
      error("pandocmd media: could not update dependency manifest: " .. tostring(append_error))
    end
    output:write(dependency, "\n")
    output:close()
  end
end

function M.process(doc)
  local output_dir = os.getenv("PANDOCMD_MEDIA_DIR")
  if not output_dir or output_dir == "" then
    return doc
  end

  local url_prefix = (os.getenv("PANDOCMD_MEDIA_URL_PREFIX") or "media"):gsub("/$", "")
  local source_file = absolute_path(util.stringify(doc.meta["pandocmd-source-file"] or "."))
  local source_dir = util.dirname(source_file)
  local record = manifest_recorder(os.getenv("PANDOCMD_MEDIA_MANIFEST"))
  local destinations = {}

  return doc:walk({
    Image = function(image)
      if is_remote(image.src) then
        return image
      end
      local requested = local_target(image.src)
      local source, expected = resolve_source(requested, source_dir)
      record(source or expected)
      if not source then
        error(
          "pandocmd media: local image not found: " .. image.src
            .. " (looked relative to " .. source_dir .. ")"
        )
      end

      local relative = destination_relative(source, source_dir)
      if destinations[relative] and destinations[relative] ~= source then
        relative = add_hash_suffix(relative, source)
      end
      destinations[relative] = source
      copy_file(source, util.join_path(output_dir, relative))
      image.src = url_encode_path(url_prefix .. "/" .. relative:gsub("\\", "/"))
      return image
    end,
  })
end

return M
