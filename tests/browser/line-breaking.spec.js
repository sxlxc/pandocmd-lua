const {execFileSync} = require('node:child_process');
const path = require('node:path');
const {test, expect} = require('@playwright/test');

const repository = path.resolve(__dirname, '../..');
const fixture = path.join(repository, 'tests/browser/fixture.md');
const hash = execFileSync(
    path.join(repository, 'bin/pandocmd-preview'),
    ['--hash-only', fixture],
    {encoding: 'utf8'},
).trim();
const fixtureUrl = '/preview/' + hash + '.html';

async function ready(page) {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(
      window.__pandocmd && window.__pandocmd.lineBreaking,
  ));
  await page.evaluate(() => window.__pandocmd.lineBreaking.ready);
  await page.waitForFunction(() => Array.from(document.images).every(
      (image) => image.complete,
  ));
  await page.evaluate(() => window.__pandocmd.lineBreaking.refresh(document));
}

test.beforeEach(async ({page}) => {
  await ready(page);
});

test('lays out eligible prose and preserves semantic elements', async ({page}) => {
  const paragraph = page.locator('section.body p').first();
  await expect(paragraph).toHaveAttribute('data-pandocmd-kp-status', 'laid-out');
  await expect(paragraph).toHaveCSS('text-align', 'justify');
  await expect(paragraph).toHaveCSS('text-align-last', 'left');
  const breakCount = await paragraph.locator(
      '[data-pandocmd-kp-generated="break"]',
  ).count();
  expect(breakCount).toBeGreaterThan(0);
  await expect(page.locator('h1 [data-pandocmd-kp-token]')).toHaveCount(0);
  await expect(paragraph.locator('a[href="#target"]')).toHaveCount(2);
  await expect(paragraph.locator('code')).toHaveCount(1);
  await expect(paragraph.locator('[data-raw-inline="kept"]')).toHaveCount(1);
  expect(await paragraph.textContent()).toContain('nested emphasis');
});

test('uses independent native fallback for unsafe and oversized runs', async ({page}) => {
  const cjk = page.locator('p', {hasText: '这段中文'});
  await expect(cjk).toHaveAttribute('data-pandocmd-kp-fallback', 'unsafe-geometry');
  await expect(page.locator('p', {hasText: 'deliberately long'})).toHaveAttribute(
      'data-pandocmd-kp-status',
      /laid-out|fallback/,
  );
});

test('measures bibliography prose within the CSL right-hand cell', async ({page}) => {
  const entry = page.locator('#reference-layout-fixture');
  const prose = entry.locator('.csl-right-inline');
  await expect(entry).not.toHaveAttribute('data-pandocmd-kp-status', /.+/);
  await expect(prose).toHaveAttribute('data-pandocmd-kp-status', 'laid-out');
  const geometry = await entry.evaluate((node) => {
    const entryRect = node.getBoundingClientRect();
    const proseNode = node.querySelector('.csl-right-inline');
    const proseRect = proseNode.getBoundingClientRect();
    const visibleChildren = Array.from(proseNode.querySelectorAll('*')).filter(
        (child) => !child.closest('[aria-hidden="true"]'),
    );
    return {
      entryRight: entryRect.right,
      proseRight: proseRect.right,
      furthestRight: Math.max(proseRect.right, ...visibleChildren.map(
          (child) => child.getBoundingClientRect().right,
      )),
    };
  });
  expect(geometry.proseRight).toBeLessThanOrEqual(geometry.entryRight + 0.5);
  expect(geometry.furthestRight).toBeLessThanOrEqual(geometry.entryRight + 0.5);

  await page.waitForTimeout(250);
  const before = await page.evaluate(() => ({
    pageWidth: document.documentElement.scrollWidth,
    solves: window.__pandocmd.lineBreaking.debugStats.solves,
  }));
  await page.waitForTimeout(500);
  const after = await page.evaluate(() => ({
    pageWidth: document.documentElement.scrollWidth,
    solves: window.__pandocmd.lineBreaking.debugStats.solves,
  }));
  expect(after).toEqual(before);
});

test('discovers flat candidates without pairwise containment scans', async ({page}) => {
  const result = await page.evaluate(async () => {
    const section = document.createElement('section');
    for (let index = 0; index < 150; index += 1) {
      const paragraph = document.createElement('p');
      paragraph.textContent = '这段中文使用原生换行。';
      section.appendChild(paragraph);
    }
    document.querySelector('section.body').appendChild(section);

    const originalContains = Element.prototype.contains;
    let containsCalls = 0;
    Element.prototype.contains = function(node) {
      containsCalls += 1;
      return originalContains.call(this, node);
    };
    try {
      await window.__pandocmd.lineBreaking.refresh(section);
    } finally {
      Element.prototype.contains = originalContains;
    }
    return {
      containsCalls,
      fallbacks: section.querySelectorAll(
          '[data-pandocmd-kp-fallback="unsafe-geometry"]',
      ).length,
    };
  });
  expect(result).toEqual({containsCalls: 0, fallbacks: 150});
});

test('disables cleanly when the default document scope is absent', async ({page}) => {
  const result = await page.evaluate(async () => {
    window.__pandocmd.lineBreaking.destroy();
    document.querySelector('.text-space').classList.remove('text-space');

    const controller = window.__pandocmd.createLineBreaking();
    window.__pandocmd.lineBreaking = controller;
    await controller.refresh(document);
    await controller.ready;

    const paragraph = document.querySelector('section.body p');
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(paragraph);
    selection.removeAllRanges();
    selection.addRange(range);
    const data = new DataTransfer();
    const copyEvent = new ClipboardEvent('copy', {
      bubbles: true,
      cancelable: true,
      clipboardData: data,
    });
    const copyAllowed = paragraph.dispatchEvent(copyEvent);
    return {
      artifacts: document.querySelectorAll(
          '[data-pandocmd-kp-generated], [data-pandocmd-kp-token]',
      ).length,
      copyAllowed,
      copiedText: data.getData('text/plain'),
    };
  });
  expect(result).toEqual({artifacts: 0, copyAllowed: true, copiedText: ''});
});

test('never tokenizes source-line links as prose', async ({page}) => {
  const theorem = page.locator('.theorem-environment').first();
  const sourceLink = theorem.locator(':scope > .source-line-link');
  await expect(theorem).toHaveAttribute('data-pandocmd-kp-status', 'laid-out');
  await expect(sourceLink).toHaveCount(1);
  await expect(page.locator(
      '.source-line-link [data-pandocmd-kp-token]',
  )).toHaveCount(0);
  const rightEdges = await sourceLink.evaluate((link) => {
    const range = document.createRange();
    range.selectNodeContents(link);
    return {
      box: link.getBoundingClientRect().right,
      text: range.getBoundingClientRect().right,
    };
  });
  expect(Math.abs(rightEdges.box - rightEdges.text)).toBeLessThanOrEqual(0.5);
});

test('calibrates every full prose line to the same right edge', async ({page}) => {
  const geometry = await page.evaluate(async () => {
    const paragraph = document.createElement('p');
    const sentence = 'This text has short words and many gaps so each full ' +
      'line can meet the same right edge with exact space size.';
    paragraph.id = 'exact-right-edge-fixture';
    paragraph.style.width = '360px';
    paragraph.textContent = Array(5).fill(sentence).join(' ');
    document.querySelector('section.body').appendChild(paragraph);
    await window.__pandocmd.lineBreaking.refresh(paragraph);
    const target = paragraph.getBoundingClientRect().right;
    const lines = {};
    Array.from(paragraph.querySelectorAll(
        '[data-pandocmd-kp-token="word"]',
    )).filter((word) => !word.querySelector(
        '[data-pandocmd-kp-token="word"]',
    )).forEach((word) => {
      const rect = word.getBoundingClientRect();
      const top = rect.top.toFixed(1);
      lines[top] = Math.max(lines[top] || -Infinity, rect.right);
    });
    const rightEdges = Object.entries(lines).sort(
        (left, right) => Number(left[0]) - Number(right[0]),
    ).map((entry) => entry[1]);
    return {
      fullLineErrors: rightEdges.slice(0, -1).map(
          (right) => Math.abs(target - right),
      ),
      finalLineGap: target - rightEdges[rightEdges.length - 1],
    };
  });
  expect(Math.max(...geometry.fullLineErrors)).toBeLessThanOrEqual(0.25);
  expect(geometry.finalLineGap).toBeGreaterThan(10);
});

test('is idempotent and skips unchanged measurement and solving', async ({page}) => {
  const before = await page.evaluate(() => {
    const controller = window.__pandocmd.lineBreaking;
    return {
      measurements: controller.debugStats.measurements,
      solves: controller.debugStats.solves,
      breaks: document.querySelectorAll('[data-pandocmd-kp-generated="break"]').length,
    };
  });
  await page.evaluate(() => window.__pandocmd.lineBreaking.refresh(document));
  const after = await page.evaluate(() => {
    const controller = window.__pandocmd.lineBreaking;
    return {
      measurements: controller.debugStats.measurements,
      solves: controller.debugStats.solves,
      breaks: document.querySelectorAll('[data-pandocmd-kp-generated="break"]').length,
    };
  });
  expect(after).toEqual(before);
});

test('scrubs xref clones and tears down cleanly', async ({page}) => {
  const result = await page.evaluate(() => {
    const controller = window.__pandocmd.lineBreaking;
    const original = document.querySelector('section.body p');
    const sourceClone = original.cloneNode(true);
    controller.scrubClone(sourceClone);
    const sourceText = sourceClone.textContent;
    const clone = original.cloneNode(true);
    controller.scrubClone(clone);
    const cloneArtifacts = clone.querySelectorAll(
        '[data-pandocmd-kp-generated], [data-pandocmd-kp-token]',
    ).length;
    controller.destroy();
    return {
      cloneArtifacts,
      remaining: document.querySelectorAll(
          '[data-pandocmd-kp-generated], [data-pandocmd-kp-token]',
      ).length,
      textMatches: original.textContent === sourceText,
    };
  });
  expect(result).toEqual({cloneArtifacts: 0, remaining: 0, textMatches: true});
});

test('survives repeated enhancement and a same-fingerprint soft reload', async ({page}) => {
  const enhanced = await page.evaluate(async () => {
    const link = document.querySelector('section.body p a');
    window.__pandocmd.enhance();
    const controller = window.__pandocmd.lineBreaking;
    await controller.ready;
    await controller.refresh(document);
    return {
      sameLink: link === document.querySelector('section.body p a'),
      breaks: document.querySelectorAll(
          '[data-pandocmd-kp-generated="break"]',
      ).length,
      adjacentBreaks: document.querySelectorAll(
          '[data-pandocmd-kp-generated="break"] + ' +
          '[data-pandocmd-kp-generated="break"]',
      ).length,
    };
  });
  expect(enhanced.sameLink).toBe(true);
  expect(enhanced.breaks).toBeGreaterThan(0);
  expect(enhanced.adjacentBreaks).toBe(0);

  const reloaded = await page.evaluate(async () => {
    const controller = window.__pandocmd.lineBreaking;
    const paragraph = document.querySelector('section.body p');
    const link = paragraph.querySelector('a');
    const measurements = controller.debugStats.measurements;
    const solves = controller.debugStats.solves;
    const reused = controller.debugStats.reusedRuns;
    await window.__pandocmd.softReload();
    return {
      sameController: controller === window.__pandocmd.lineBreaking,
      sameParagraph: paragraph === document.querySelector('section.body p'),
      sameLink: link === document.querySelector('section.body p a'),
      measurements: controller.debugStats.measurements - measurements,
      solves: controller.debugStats.solves - solves,
      reused: controller.debugStats.reusedRuns - reused,
    };
  });
  expect(reloaded.sameController).toBe(true);
  expect(reloaded.sameParagraph).toBe(true);
  expect(reloaded.sameLink).toBe(true);
  expect(reloaded.measurements).toBe(0);
  expect(reloaded.solves).toBe(0);
  expect(reloaded.reused).toBeGreaterThan(0);
  await expect(page.locator('section.body p').first()).toHaveAttribute(
      'data-pandocmd-kp-status',
      'laid-out',
  );
  await page.locator('section.body p a[href="#target"]').first().hover();
  await expect(page.locator('#xref-preview')).toBeVisible();
  const folding = await page.evaluate(() => ({
    headings: document.querySelectorAll(
        'section.body h1, section.body h2, section.body h3, ' +
        'section.body h4, section.body h5, section.body h6',
    ).length,
    buttons: document.querySelectorAll(
        'section.body .section-fold-button',
    ).length,
  }));
  expect(folding.headings).toBe(folding.buttons);
});

test('soft reload solves only an edited paragraph', async ({page}) => {
  const result = await page.evaluate(async () => {
    const controller = window.__pandocmd.lineBreaking;
    const unchanged = document.querySelector('section.body p');
    const changed = Array.from(document.querySelectorAll('section.body p')).find(
        (paragraph) => paragraph.textContent.includes('This paragraph has a forced'),
    );
    const theorem = document.querySelector('.theorem-environment');
    const originalFetch = window.fetch;
    const response = await originalFetch(window.location.href, {cache: 'no-store'});
    const html = await response.text();
    const parsed = new DOMParser().parseFromString(html, 'text/html');
    const replacement = Array.from(parsed.querySelectorAll('section.body p')).find(
        (paragraph) => paragraph.textContent.includes('This paragraph has a forced'),
    );
    replacement.appendChild(document.createTextNode(
        ' This localized edit adds enough words to retain paragraph layout.',
    ));
    parsed.querySelectorAll('[data-source-line]').forEach((element) => {
      const line = Number(element.getAttribute('data-source-line')) + 1000;
      element.setAttribute('data-source-line', String(line));
      const marker = element.querySelector(':scope > .source-line-link');
      if (marker) {
        marker.textContent = String(line);
      }
    });
    const changedHtml = '<!doctype html>\n' + parsed.documentElement.outerHTML;
    const solves = controller.debugStats.solves;
    const measurements = controller.debugStats.measurements;
    window.fetch = function() {
      return Promise.resolve(new Response(changedHtml, {
        headers: {'Content-Type': 'text/html'},
        status: 200,
      }));
    };
    try {
      await window.__pandocmd.softReload();
    } finally {
      window.fetch = originalFetch;
    }
    return {
      sameController: controller === window.__pandocmd.lineBreaking,
      sameUnchanged: unchanged === document.querySelector('section.body p'),
      sameTheorem: theorem === document.querySelector('.theorem-environment'),
      theoremLine: document.querySelector(
          '.theorem-environment > .source-line-link',
      ).textContent,
      replacedChanged: changed !== Array.from(
          document.querySelectorAll('section.body p'),
      ).find((paragraph) => paragraph.textContent.includes(
          'This paragraph has a forced',
      )),
      solveDelta: controller.debugStats.solves - solves,
      measurementDelta: controller.debugStats.measurements - measurements,
    };
  });
  expect(result.sameController).toBe(true);
  expect(result.sameUnchanged).toBe(true);
  expect(result.sameTheorem).toBe(true);
  expect(Number(result.theoremLine)).toBeGreaterThan(1000);
  expect(result.replacedChanged).toBe(true);
  expect(result.solveDelta).toBe(1);
  expect(result.measurementDelta).toBeGreaterThan(0);
});

test('keeps read, solve, and write phases ordered', async ({page}) => {
  const phases = await page.evaluate(
      () => window.__pandocmd.lineBreaking.debugStats.phases,
  );
  const reads = phases.indexOf('reads');
  const solve = phases.indexOf('solve');
  const writes = phases.indexOf('writes');
  expect(reads).toBeGreaterThanOrEqual(0);
  expect(solve).toBeGreaterThan(reads);
  expect(writes).toBeGreaterThan(solve);
});

test('reflows only a run whose inline size changes', async ({page}) => {
  const paragraph = page.locator('section.body p').first();
  const before = await page.evaluate(
      () => window.__pandocmd.lineBreaking.debugStats.solves,
  );
  await paragraph.evaluate((node) => {
    node.style.width = '360px';
  });
  await page.waitForFunction(
      (solves) => window.__pandocmd.lineBreaking.debugStats.solves > solves,
      before,
  );
  await page.waitForTimeout(100);
  const after = await page.evaluate(
      () => window.__pandocmd.lineBreaking.debugStats.solves,
  );
  expect(after - before).toBe(1);
  await expect(paragraph).toHaveAttribute(
      'data-pandocmd-kp-status',
      /laid-out|fallback/,
  );
});

test('falls back at the 4096 item guard without disturbing neighbors', async ({page}) => {
  const result = await page.evaluate(async () => {
    const controller = window.__pandocmd.lineBreaking;
    const before = {
      measurements: controller.debugStats.measurements,
      solves: controller.debugStats.solves,
    };
    const paragraph = document.createElement('p');
    paragraph.id = 'item-limit-fixture';
    paragraph.textContent = Array(2200).fill('word').join(' ');
    const sourceText = paragraph.textContent;
    document.querySelector('section.body').appendChild(paragraph);
    await controller.refresh(paragraph);
    return {
      measurementDelta: controller.debugStats.measurements - before.measurements,
      solveDelta: controller.debugStats.solves - before.solves,
      sourcePreserved: paragraph.textContent === sourceText,
      tokens: paragraph.querySelectorAll('[data-pandocmd-kp-token]').length,
    };
  });
  expect(result).toEqual({
    measurementDelta: 0,
    solveDelta: 0,
    sourcePreserved: true,
    tokens: 0,
  });
  const guarded = page.locator('#item-limit-fixture');
  await expect(guarded).toHaveAttribute('data-pandocmd-kp-fallback', 'item-limit');
  await expect(page.locator('section.body p').first()).toHaveAttribute(
      'data-pandocmd-kp-status',
      'laid-out',
  );
});

test('counts hyphenation items before measuring', async ({page}) => {
  const result = await page.evaluate(async () => {
    const controller = window.__pandocmd.lineBreaking;
    const before = {
      measurements: controller.debugStats.measurements,
      solves: controller.debugStats.solves,
    };
    const paragraph = document.createElement('p');
    paragraph.id = 'hyphen-item-limit-fixture';
    paragraph.textContent = Array(400).fill(
        'ex\u00adtra\u00ador\u00addi\u00adnar\u00ady',
    ).join(' ');
    const sourceText = paragraph.textContent;
    document.querySelector('section.body').appendChild(paragraph);
    await controller.refresh(paragraph);
    return {
      measurementDelta: controller.debugStats.measurements - before.measurements,
      solveDelta: controller.debugStats.solves - before.solves,
      sourcePreserved: paragraph.textContent === sourceText,
      tokens: paragraph.querySelectorAll('[data-pandocmd-kp-token]').length,
    };
  });
  expect(result).toEqual({
    measurementDelta: 0,
    solveDelta: 0,
    sourcePreserved: true,
    tokens: 0,
  });
  await expect(page.locator('#hyphen-item-limit-fixture')).toHaveAttribute(
      'data-pandocmd-kp-fallback',
      'item-limit',
  );
});

test('copy data and suspended layout contain no generated artifacts', async ({page}) => {
  const copied = await page.evaluate(() => {
    const paragraph = document.querySelector('section.body p');
    const expected = paragraph.cloneNode(true);
    window.__pandocmd.lineBreaking.scrubClone(expected);
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(paragraph);
    selection.removeAllRanges();
    selection.addRange(range);
    const data = new DataTransfer();
    paragraph.dispatchEvent(new ClipboardEvent('copy', {
      bubbles: true,
      cancelable: true,
      clipboardData: data,
    }));
    return {
      actual: data.getData('text/plain'),
      expected: expected.textContent,
      html: data.getData('text/html'),
    };
  });
  expect(copied.actual).toBe(copied.expected);
  expect(copied.html).not.toContain('data-pandocmd-kp');

  await page.evaluate(() => window.__pandocmd.lineBreaking.suspend());
  await expect(page.locator('[data-pandocmd-kp-generated]')).toHaveCount(0);
  await page.evaluate(() => window.__pandocmd.lineBreaking.resume());
  await expect(page.locator('section.body p').first()).toHaveAttribute(
      'data-pandocmd-kp-status',
      'laid-out',
  );
});

test('uses KaTeX base groups as visible math boxes', async ({page}) => {
  const structures = await page.evaluate(() => {
    return Array.from(document.querySelectorAll('.math.inline')).map((math) => ({
      source: math.getAttribute('data-pandocmd-katex-source'),
      bases: math.querySelectorAll('.katex-html > .base').length,
      baseClasses: Array.from(math.querySelectorAll('.katex-html > .base')).map(
          (base) => Array.from(base.querySelectorAll('.nobreak, .mrel, .mbin')).map(
              (node) => node.className,
          ),
      ),
      mathmlHidden: math.querySelector('.katex-mathml') !== null &&
        math.querySelector('.katex-html').getAttribute('aria-hidden') === 'true',
    }));
  });
  const relation = structures.find((item) => item.source.includes('a = b + c'));
  const noBreak = structures.find((item) => item.source.includes('nobreak'));
  const allowBreak = structures.find((item) => item.source.includes('allowbreak'));
  expect(relation.bases).toBeGreaterThan(1);
  expect(noBreak.baseClasses[0]).toContain('mspace nobreak');
  expect(allowBreak.bases).toBeGreaterThan(1);
  expect(allowBreak.baseClasses.flat()).toHaveLength(0);
  expect(structures.every((item) => item.mathmlHidden)).toBe(true);
});

test('preserves KaTeX display and fraction centering', async ({page}) => {
  const geometry = await page.evaluate(() => {
    const fixture = document.querySelector('#katex-centering-fixture');
    const displayMath = fixture.querySelector('.math.display');
    const display = displayMath.querySelector('.katex-display');
    const displayKatex = display.querySelector(':scope > .katex');
    const bases = Array.from(display.querySelectorAll('.katex-html > .base'));
    const baseRects = bases.map((base) => base.getBoundingClientRect());
    const displayRect = display.getBoundingClientRect();

    const inlineMath = fixture.querySelector('.math.inline');
    const fraction = inlineMath.querySelector('.mfrac');
    const fractionRect = fraction.getBoundingClientRect();
    const rows = Array.from(fraction.querySelectorAll(
        ':scope > .vlist-t > .vlist-r:first-child > .vlist > span > .sizing',
    ));

    return {
      displayInJustifiedRun: display.closest(
          '.pandocmd-kp-active, .pandocmd-kp-fallback',
      ) !== null,
      displayLastAlignment: getComputedStyle(displayKatex).textAlignLast,
      displayCenterError: Math.abs(
          (Math.min(...baseRects.map((rect) => rect.left)) +
           Math.max(...baseRects.map((rect) => rect.right))) / 2 -
          (displayRect.left + displayRect.right) / 2,
      ),
      fractionInActiveRun: fraction.closest('.pandocmd-kp-active') !== null,
      fractionLastAlignment: getComputedStyle(fraction).textAlignLast,
      rowCenterErrors: rows.map((row) => {
        const rowRect = row.getBoundingClientRect();
        return Math.abs(
            (rowRect.left + rowRect.right) / 2 -
            (fractionRect.left + fractionRect.right) / 2,
        );
      }),
    };
  });

  expect(geometry.displayInJustifiedRun).toBe(true);
  expect(geometry.displayLastAlignment).toBe('auto');
  expect(geometry.displayCenterError).toBeLessThanOrEqual(0.5);
  expect(geometry.fractionInActiveRun).toBe(true);
  expect(geometry.fractionLastAlignment).toBe('auto');
  expect(geometry.rowCenterErrors).toHaveLength(2);
  expect(Math.max(...geometry.rowCenterErrors)).toBeLessThanOrEqual(0.5);
});
