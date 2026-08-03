# Browser line-breaking benchmark

The non-gating benchmark creates 150 prose paragraphs containing multi-group
KaTeX expressions, then records the controller's wall time, measurement count,
solver count, and completed-run count. Run it separately from the regression
suite:

```sh
npm run benchmark-browser
```

The command prints one `PANDOCMD_BENCHMARK` JSON record. Wall time is intended
for local before/after comparison; it varies with browser and hardware. The
deterministic regression assertions for caching, affected-run reflow, phase
ordering, and the item limit remain in `line-breaking.spec.js`.

Reference run (2026-08-03, local Apple Silicon Chromium): 970.8 ms, 1,064
text measurements, 150 solver calls, and 150 completed runs. Only the counts
are expected to be stable across machines.
