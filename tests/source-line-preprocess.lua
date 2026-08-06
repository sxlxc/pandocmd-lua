package.path = "lua/?.lua;" .. package.path

local source_lines = require("source-line-preprocess")
local source_line_annotations = require("source-lines")
local theorems = require("theorems")

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

local rich_image_doc = pandoc.read(
  '<!-- pandocmd-source-line:1 -->\n\n![*rich* `alt`](image.png "title")',
  reader_format
)
rich_image_doc.blocks = source_line_annotations.annotate_blocks(nil, rich_image_doc.blocks)
local rich_image_caption = nil
rich_image_doc:walk({
  Image = function(image)
    rich_image_caption = pandoc.utils.stringify(image.caption)
  end,
})
assert_equal("image caption source-line traversal", rich_image_caption, "rich alt")

local theorem_markdown = source_lines.annotate_source_lines(20, {
  "::: {#first-source-line-theorem .theorem}",
  "The first theorem establishes the numbering.",
  ":::",
  "",
  "::: {#second-source-line-theorem .theorem}",
  "The second theorem keeps its first paragraph.",
  "",
  "Its second paragraph has an independent source line.",
  ":::",
  "",
  "::: {.proof}",
  "Choose a maximum matching of the original presentation. It matches $r$ elements of $X$ to $r$ distinct vertices of $R$. Match the $k-r$ universal elements of $Z$ to the remaining presentation vertices. Thus the new presentation has rank $k$.",
  "",
  "The restriction...",
  ":::",
})
local theorem_doc = pandoc.read(theorem_markdown, reader_format)
theorem_doc = source_lines.strip_source_line_markers_from_math(theorem_doc)
theorem_doc.blocks = source_line_annotations.annotate_blocks(nil, theorem_doc.blocks)
local theorem_specs = theorems.build_block_specs(theorem_doc.meta)
theorem_doc.blocks = theorems.preprocess_blocks(theorem_doc.blocks, theorem_specs)
theorem_doc.blocks = theorems.render_blocks(theorem_doc.blocks)

local second_theorem = theorem_doc.blocks[2]
local first_theorem_body = second_theorem.content[2]
local second_theorem_body = second_theorem.content[3]
assert_equal("fenced theorem type", second_theorem.t, "Div")
assert_equal("fenced theorem source line", second_theorem.attr.attributes["data-source-line"], "25")
assert_equal("fenced theorem index", second_theorem.attr.attributes.index, "2")
assert_equal(
  "fenced theorem source label",
  second_theorem.content[1].text:find(">25</", 1, true) ~= nil,
  true
)
assert_equal("theorem first body stays a paragraph", first_theorem_body.t, "Para")
assert_equal("theorem header is inside first paragraph", first_theorem_body.content[1].t, "Span")
assert_equal(
  "theorem header class",
  first_theorem_body.content[1].attr.classes[1],
  "theorem-header"
)
assert_equal("theorem first body text follows header", first_theorem_body.content[2].text, "The")
assert_equal("theorem second body source wrapper", second_theorem_body.t, "Div")
assert_equal(
  "theorem second body source line",
  second_theorem_body.attr.attributes["data-source-line"],
  "27"
)

local proof = theorem_doc.blocks[3]
local proof_first_body = proof.content[2]
local proof_math_count = 0
for _, inline in ipairs(proof_first_body.content) do
  if inline.t == "Math" then
    proof_math_count = proof_math_count + 1
  end
end
assert_equal("fenced proof type", proof.t, "Div")
assert_equal("fenced proof source line", proof.attr.attributes["data-source-line"], "31")
assert_equal("proof first body stays a paragraph", proof_first_body.t, "Para")
assert_equal("proof header is inside first paragraph", proof_first_body.content[1].t, "Span")
assert_equal("proof first body text follows header", proof_first_body.content[2].text, "Choose")
assert_equal("proof inline math is retained", proof_math_count, 7)
