---
title: Line breaking fixture
lang: en-US
---

# Excluded heading with extraordinarilylongheadingword

This deliberately long paragraph contains *nested emphasis with a
[semantic link](#target)*, a citation-shaped [reference](#target), `inline code`,
<span data-raw-inline="kept">raw inline HTML</span>, an extraordinarily
hyphenatable representation, and inline mathematics $a + b = c$ so that a
narrow measure produces several justified lines while preserving author nodes.

This paragraph has a forced  
line break, a nonbreaking word pair alpha&nbsp;beta, an authored soft hyphen
extraor&shy;dinary, a <wbr> word break, and punctuation after math $z$, together
with the adjacent expression $T$-path.

This run contains a long URL
<https://example.test/a/very/long/path/that/cannot/fit/in/the/available/measure>.

这段中文应该只使用浏览器原生换行，不进行自定义断行。

- A bare list item with enough explanatory prose to require line breaking in
  a narrow viewport and an ![*emphasized* `code` alt](missing-image.png) image.

| Column one | Column two |
|:-----------|:-----------|
| A table cell with extended prose for line breaking. | Another cell. |

: A table caption with sufficiently descriptive prose.

::: {#target .theorem-environment}
**Theorem.** A theorem body contains a tall inline formula
$\frac{\sum_{i=1}^{n} i}{1+x}$ and enough surrounding prose to wrap.
:::

::: {#lem:finite-transversal-girth-hardness .lemma}
Computing the girth of a bipartite-presented transversal matroid is NP-hard even under the promise that the matroid has a circuit, and hence has finite girth.
:::

::: {#katex-centering-fixture}
This justified paragraph contains the asymmetric inline fraction
$\frac{x}{1+y+z}$ and enough surrounding prose to exercise inherited text
alignment while preserving KaTeX's own centering.

This paragraph introduces a display equation
$$
\frac{1}{a+b+c+d}=q
$$
and continues afterward so the paragraph itself remains an eligible prose run.
:::

The expressions $a = b + c + d + e + f$ and $x \nobreak = y$ and
$p \allowbreak q$ exercise KaTeX base groups.

<span class="marginnote">A sidenote with sufficiently long prose to wrap at
its independently changing width.</span>

<div class="references csl-bib-body" role="list">
<div id="reference-layout-fixture" class="csl-entry" role="listitem">
<div class="csl-left-margin">[18] </div><div class="csl-right-inline"><span>A. Author, A deliberately descriptive reference title with enough words to wrap over several justified lines, <em>Journal of Browser Typography</em>. 42 (2026) 101–120 <a href="https://doi.org/10.1000/pandocmd.123456789">10.1000/pandocmd.123456789</a>.</span></div>
</div>
</div>

::: {.algo #alg:source-line-fixture title="Parameter-free truncation packing."}
$\textsc{ParameterFree}(M, w, k)$:
  collapse the parallel classes of $M$
  if $E_0:=\{e:w_e=0\}$ has $r(E\setminus E_0)\le r-k$, return $E\setminus\operatorname{cl}(E\setminus E_0)$, uncollapsed
  form the closure arm, and one packing arm for each depth $h\in [r-k-1]$.
  for budget $B=1,2,4,\dots$
    run every arm from scratch for at most $B$ steps
    if some arm halted, return its answer, uncollapsed

  the closure arm:
    enumerate the closures of independent sets of size at most $r-k$, recording the complements that drop the rank by at least $k$
    halt with the lightest recorded $k$-cocycle

  the packing arm at depth $h$:
    maintain the witness, the lightest $k$-cocycle found, of weight $\mu$, initially $\infty$
    for cap $s=k,k+1,\dots,r-h-1$
      run $\textsc{TruncationPacking}(M,w,k,s,h)$, solving each residual of rank at least $k$ by $\textsc{ParameterFree}$
      if $(s+1)\,\sigma(T_h(M))>\mu$, halt with the witness
:::
