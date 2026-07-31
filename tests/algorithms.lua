local script_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or ""
package.path = script_dir .. "../lua/?.lua;" .. package.path

local algorithms = require("algorithms")

local function assert_equal(actual, expected, name)
  if actual ~= expected then
    error(name .. ": expected " .. expected .. ", got " .. actual, 0)
  end
end

local indented = algorithms.preserve_source_indentation({
  '::: {.algo #alg:test title="Test."}',
  "$x$:",
  "  while $y$",
  "    return $z$",
  ":::",
})
assert_equal(indented[2], "$x$:", "unindented algorithm line")
assert_equal(indented[3], "&nbsp;&nbsp;while $y$", "two-space algorithm indent")
assert_equal(indented[4], "&nbsp;&nbsp;&nbsp;&nbsp;return $z$", "four-space algorithm indent")

local first = pandoc.Div({ pandoc.Para({
  pandoc.Str("first"),
  pandoc.SoftBreak(),
  pandoc.Str("  indented"),
}) }, pandoc.Attr("alg:first", { "algo" }))
local second = pandoc.Div({ pandoc.Para({ pandoc.Str("second") }) }, pandoc.Attr("alg:second", { "algo" }))
local blocks, links = algorithms.preprocess_blocks(pandoc.Blocks({ first, second }))
assert_equal(blocks[1].attr.attributes["algo-index"], "1", "first algorithm index")
assert_equal(blocks[2].attr.attributes["algo-index"], "2", "second algorithm index")
assert_equal(links["alg:second"], "ALG 2", "algorithm reference label")

local rendered = algorithms.render_blocks(blocks)
assert_equal(rendered[1].attr.identifier, "alg:first", "rendered algorithm identifier")
assert_equal(rendered[1].attr.classes[1], "algorithm", "rendered algorithm class")
assert_equal(rendered[1].content[1].attr.classes[1], "algo-box", "algorithm box class")
assert_equal(rendered[1].content[1].content[1].content[1].attr.classes[1], "algo-line", "algorithm line class")
assert_equal(rendered[1].content[1].content[1].content[2].attr.attributes.style, "--algo-indent: 1.0rem", "algorithm line indent")
assert_equal(rendered[1].content[1].content[1].content[2].content[1].text, "indented", "algorithm indent characters removed")
