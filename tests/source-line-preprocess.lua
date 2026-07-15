package.path = "lua/?.lua;" .. package.path

local source_lines = require("source-line-preprocess")

local reader_format = "markdown+tex_math_double_backslash+tex_math_single_backslash+latex_macros+raw_tex"

local function joined(lines)
  return table.concat(lines, "\n")
end

local function assert_equal(name, actual, expected)
  if actual ~= expected then
    error(name .. "\nexpected:\n" .. tostring(expected) .. "\nactual:\n" .. tostring(actual), 0)
  end
end

local function assert_display_math_is_marker_free(name, markdown, expected_count)
  local count = 0
  local doc = pandoc.read(markdown, reader_format)
  doc:walk({
    Math = function(math)
      if math.mathtype == "DisplayMath" then
        count = count + 1
        if math.text:find("pandocmd-source-line:", 1, true) then
          error(name .. ": source-line marker leaked into display math", 0)
        end
      end
    end,
  })
  assert_equal(name .. ": display math count", count, expected_count)
end

local contaminated_math = pandoc.read(
  joined({
    "$$",
    "x + y",
    "<!-- pandocmd-source-line:2 -->",
    "$$",
  }),
  reader_format
)
contaminated_math = source_lines.strip_source_line_markers_from_math(contaminated_math)
local cleaned_math_count = 0
local cleaned_math_text = nil
contaminated_math:walk({
  Math = function(math)
    if math.mathtype == "DisplayMath" then
      cleaned_math_count = cleaned_math_count + 1
      cleaned_math_text = math.text
      if math.text:find("pandocmd-source-line:", 1, true) then
        error("reserved source marker was not stripped from display math", 0)
      end
    end
  end,
})
assert_equal("source marker cleanup: display math count", cleaned_math_count, 1)
assert_equal("source marker cleanup: exact math text", cleaned_math_text, "\nx + y\n")

local guarded_midline = source_lines.annotate_source_lines(1, {
  "before $$x +",
  "y",
  "$$",
  "then",
  "$$",
  "z",
  "$$",
})
local guarded_doc = pandoc.read(guarded_midline, reader_format)
guarded_doc = source_lines.strip_source_line_markers_from_math(guarded_doc)
local guarded_texts = {}
guarded_doc:walk({
  Math = function(math)
    if math.mathtype == "DisplayMath" then
      table.insert(guarded_texts, math.text)
    end
  end,
})
assert_equal("guarded mid-line display count", #guarded_texts, 2)
assert_equal("guarded first display text", guarded_texts[1], "x +\ny\n")
assert_equal("guarded second display text", guarded_texts[2], "\nz\n")

local placement_cases = {
  {
    name = "link destination before display",
    lines = { "[x](https://example/$$)", "$$", "x", "$$" },
    expected = {
      "<!-- pandocmd-source-line:1 -->",
      "[x](https://example/$$)",
      "<!-- pandocmd-source-line:2 -->",
      "$$",
      "x",
      "$$",
    },
  },
  {
    name = "raw HTML before display",
    lines = { '<span data-x="$$"></span>', "$$", "x", "$$" },
    expected = {
      '<span data-x="$$"></span>',
      "<!-- pandocmd-source-line:2 -->",
      "$$",
      "x",
      "$$",
    },
  },
  {
    name = "autolink before display",
    lines = { "<https://example.test/$$>", "$$", "x", "$$" },
    expected = {
      "<https://example.test/$$>",
      "<!-- pandocmd-source-line:2 -->",
      "$$",
      "x",
      "$$",
    },
  },
  {
    name = "HTML comment before display",
    lines = { "<!-- $$ -->", "$$", "x", "$$" },
    expected = {
      "<!-- $$ -->",
      "<!-- pandocmd-source-line:2 -->",
      "$$",
      "x",
      "$$",
    },
  },
  {
    name = "adjacent inline math before display",
    lines = { "# head $x$$y$", "$$", "x", "$$" },
    expected = {
      "# head $x$$y$",
      "<!-- pandocmd-source-line:2 -->",
      "$$",
      "x",
      "$$",
    },
  },
  {
    name = "inline math ending with a spare dollar",
    lines = { "# $x$$", "$$", "x", "$$" },
    expected = {
      "# $x$$",
      "<!-- pandocmd-source-line:2 -->",
      "$$",
      "x",
      "$$",
    },
  },
  {
    name = "raw TeX before header display",
    lines = { "# raw \\\\foo{$$} then $$", "x", "$$" },
    expected = {
      "# raw \\\\foo{$$} then $$",
      "x",
      "$$",
    },
  },
  {
    name = "reference destination before display",
    lines = { "[id]: https://x.test/$$", "$$", "x", "$$" },
    expected = {
      "[id]: https://x.test/$$",
      "<!-- pandocmd-source-line:2 -->",
      "$$",
      "x",
      "$$",
    },
  },
  {
    name = "pipe table before display",
    lines = { "| literal $$ |", "|---|", "$$", "x", "$$" },
    expected = {
      "| literal $$ |",
      "|---|",
      "<!-- pandocmd-source-line:3 -->",
      "$$",
      "x",
      "$$",
    },
  },
  {
    name = "display after unmatched delimiter in prior list item",
    lines = { "- literal $$", "- $$", "  x", "  $$" },
    expected = {
      "- literal $$",
      "- $$",
      "  x",
      "  $$",
    },
  },
}

for _, case in ipairs(placement_cases) do
  local annotated = source_lines.annotate_source_lines(1, case.lines)
  assert_equal(case.name, annotated, joined(case.expected))
  assert_display_math_is_marker_free(case.name, annotated, 1)
end

local midline_dollars = source_lines.annotate_source_lines(1, {
  "before $$",
  "x + y",
  "$$",
})
assert_equal(
  "mid-line dollar display",
  midline_dollars,
  joined({
    "<!-- pandocmd-source-line:1 -->",
    "before $$",
    "x + y",
    "$$",
  })
)
assert_display_math_is_marker_free("mid-line dollar display", midline_dollars, 1)

local midline_brackets = source_lines.annotate_source_lines(7, {
  "before \\\\[",
  "x + y",
  "\\\\] after",
})
assert_equal(
  "mid-line double-backslash display",
  midline_brackets,
  joined({
    "<!-- pandocmd-source-line:7 -->",
    "before \\\\[",
    "x + y",
    "\\\\] after",
  })
)
assert_display_math_is_marker_free("mid-line double-backslash display", midline_brackets, 1)

local midline_single_brackets = source_lines.annotate_source_lines(11, {
  "before \\[",
  "x + y",
  "\\] after",
})
assert_equal(
  "mid-line single-backslash display",
  midline_single_brackets,
  joined({
    "<!-- pandocmd-source-line:11 -->",
    "before \\[",
    "x + y",
    "\\] after",
  })
)
assert_display_math_is_marker_free("mid-line single-backslash display", midline_single_brackets, 1)

local header_display = source_lines.annotate_source_lines(1, {
  "# heading $$",
  "x + y",
  "$$",
  "",
  "after",
})
assert_equal(
  "display math in a header",
  header_display,
  joined({
    "# heading $$",
    "x + y",
    "$$",
    "",
    "<!-- pandocmd-source-line:5 -->",
    "after",
  })
)
assert_display_math_is_marker_free("display math in a header", header_display, 1)

local no_space_header = source_lines.annotate_source_lines(1, {
  "# foo$$",
  "x",
  "$$",
})
assert_equal(
  "no-space display opener in a header",
  no_space_header,
  joined({
    "# foo$$",
    "x",
    "$$",
  })
)
assert_display_math_is_marker_free("no-space display opener in a header", no_space_header, 1)
local no_space_header_doc = pandoc.read(no_space_header, reader_format)
assert_equal("no-space header identifier", no_space_header_doc.blocks[1].identifier, "foo-x")

local no_space_header_content = source_lines.annotate_source_lines(1, {
  "# foo$$x +",
  "y",
  "$$",
})
assert_equal(
  "no-space display opener with same-line content",
  no_space_header_content,
  joined({
    "# foo$$x +",
    "y",
    "$$",
  })
)
local no_space_header_content_doc = pandoc.read(no_space_header_content, reader_format)
assert_equal(
  "no-space content header identifier",
  no_space_header_content_doc.blocks[1].identifier,
  "foox-y"
)
assert_display_math_is_marker_free(
  "no-space display opener with same-line content",
  no_space_header_content,
  1
)

local list_math_content = source_lines.annotate_source_lines(1, {
  "- item $$",
  "  a",
  "  - b",
  "  $$",
})
assert_equal(
  "list-looking TeX content",
  list_math_content,
  joined({
    "- item $$",
    "  a",
    "  - b",
    "  $$",
  })
)
local list_math_doc = pandoc.read(list_math_content, reader_format)
local list_math_text = nil
list_math_doc:walk({
  Math = function(math)
    if math.mathtype == "DisplayMath" then
      list_math_text = math.text
    end
  end,
})
assert_equal("list-looking exact math text", list_math_text, "\na\n- b\n")

local adjacent_displays = source_lines.annotate_source_lines(1, {
  "$$",
  "a",
  "$$ $$",
  "b",
  "$$",
})
assert_equal(
  "close and reopen on one line",
  adjacent_displays,
  joined({
    "<!-- pandocmd-source-line:1 -->",
    "$$",
    "a",
    "$$ $$",
    "b",
    "$$",
  })
)
assert_display_math_is_marker_free("close and reopen on one line", adjacent_displays, 2)

local overlapping_dollars = source_lines.annotate_source_lines(1, {
  "$$$$",
  "x + y",
  "$$",
})
assert_equal(
  "overlapping dollar opener",
  overlapping_dollars,
  joined({
    "<!-- pandocmd-source-line:1 -->",
    "$$$$",
    "x + y",
    "$$",
  })
)
assert_display_math_is_marker_free("overlapping dollar opener", overlapping_dollars, 1)

assert_equal(
  "escaped dollars and code span",
  source_lines.annotate_source_lines(1, {
    "literal \\$$ and `$$`",
    "",
    "after",
  }),
  joined({
    "<!-- pandocmd-source-line:1 -->",
    "literal \\$$ and `$$`",
    "",
    "<!-- pandocmd-source-line:3 -->",
    "after",
  })
)

local multiline_code = source_lines.annotate_source_lines(1, {
  "before `literal $$",
  "still code` then",
  "$$",
  "x + y",
  "$$",
})
assert_equal(
  "multiline code span",
  multiline_code,
  joined({
    "<!-- pandocmd-source-line:1 -->",
    "before `literal $$",
    "still code` then",
    "<!-- pandocmd-source-line:3 -->",
    "$$",
    "x + y",
    "$$",
  })
)
assert_display_math_is_marker_free("multiline code span", multiline_code, 1)

assert_equal(
  "unmatched display opener",
  source_lines.annotate_source_lines(1, {
    "literal $$",
    "is still a paragraph",
    "",
    "after",
  }),
  joined({
    "<!-- pandocmd-source-line:1 -->",
    "literal $$",
    "is still a paragraph",
    "",
    "<!-- pandocmd-source-line:4 -->",
    "after",
  })
)
