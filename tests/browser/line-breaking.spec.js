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

test('uses the compact page shell', async ({page}) => {
  await expect(page.locator(
      '.page-layout > main.text-space > article > section.body',
  )).toHaveCount(1);
  await expect(page.locator('.page-layout main main')).toHaveCount(0);
  await expect(page.locator('#contents-big > .mini-header')).toHaveCount(1);

  await expect(page.locator(
      'section.body > .source-line[data-source-line] > p',
  ).first()).toHaveCount(1);
});

test('persists page controls through the cached runtime', async ({page}) => {
  const contents = page.locator('#toggle-left-margin');
  const sidenotes = page.locator('#toggle-sidenotes');

  await contents.click();
  await sidenotes.click();
  await expect(page.locator('body')).toHaveClass(/hide-left-margin/);
  await expect(page.locator('body')).not.toHaveClass(/click-open-notes/);
  await expect(contents).toHaveAttribute('aria-pressed', 'false');
  await expect(sidenotes).toHaveAttribute('aria-pressed', 'true');
  expect(await page.evaluate(() => JSON.parse(window.localStorage.getItem(
      'pandocmd:control-state:' + window.location.pathname,
  )))).toEqual(['hide-left-margin']);

  await page.reload();
  await ready(page);
  await expect(page.locator('body')).toHaveClass(/hide-left-margin/);
  await expect(page.locator('body')).not.toHaveClass(/click-open-notes/);
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

test('normalizes collapsible whitespace to visible space tokens', async ({page}) => {
  const result = await page.evaluate(async () => {
    const paragraph = document.createElement('p');
    paragraph.style.width = '360px';
    paragraph.innerHTML = 'Whitespace around <em>inline markup</em>\n\t' +
      '<span>must collapse to one visible space</span>, while enough ordinary ' +
      'prose keeps this paragraph eligible for line breaking and inspection.';
    document.querySelector('section.body').appendChild(paragraph);
    await window.__pandocmd.lineBreaking.refresh(paragraph);
    return {
      status: paragraph.getAttribute('data-pandocmd-kp-status'),
      spaces: Array.from(paragraph.querySelectorAll(
          '[data-pandocmd-kp-token="space"]',
      )).map((token) => token.textContent),
    };
  });

  expect(result.status).toBe('laid-out');
  expect(result.spaces.length).toBeGreaterThan(0);
  expect(result.spaces.every((space) => space === ' ')).toBe(true);
});

test('keeps writer line breaks visible in theorem prose', async ({page}) => {
  const result = await page.locator(
      '[id="lem:finite-transversal-girth-hardness"]',
  ).evaluate(async (theorem) => {
    theorem.style.width = '500px';
    await window.__pandocmd.lineBreaking.refresh(theorem);
    const paragraph = theorem.querySelector(':scope > p');
    const hence = Array.from(paragraph.children).find(
        (child) => child.textContent === 'hence',
    );
    const space = hence && hence.nextElementSibling;
    const has = space && space.nextElementSibling;
    return {
      status: paragraph.getAttribute('data-pandocmd-kp-status'),
      display: space && getComputedStyle(space).display,
      spaceText: space && space.textContent,
      spaceWidth: space && space.getBoundingClientRect().width,
      sameLine: Boolean(has) && Math.abs(
          hence.getBoundingClientRect().top - has.getBoundingClientRect().top,
      ) < 1,
    };
  });

  expect(result.status).toBe('laid-out');
  expect(result.display).toBe('inline-block');
  expect(result.spaceText).toBe(' ');
  expect(result.spaceWidth).toBeGreaterThan(1);
  expect(result.sameLine).toBe(true);
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
  const firstParagraph = theorem.locator(':scope > p').first();
  const sourceLink = theorem.locator(':scope > .source-line-link');
  await expect(theorem).not.toHaveAttribute('data-pandocmd-kp-status', /.+/);
  await expect(firstParagraph).toHaveAttribute(
      'data-pandocmd-kp-status', 'laid-out');
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

test('lays out opening theorem and proof paragraphs with inline headers', async ({page}) => {
  const result = await page.evaluate(async () => {
    const section = document.createElement('section');
    const specifications = [
      {
        className: 'Theorem',
        index: '2',
        line: '41',
        opening: [
          'The theorem begins with its first paragraph and enough prose to ' +
            'exercise several justified lines at this narrow measure.',
        ],
      },
      {
        className: 'Proof',
        line: '52',
        opening: [
          'Choose a maximum matching of the original presentation. It matches ',
          {math: 'r'},
          ' elements of ',
          {math: 'X'},
          ' to ',
          {math: 'r'},
          ' distinct vertices of ',
          {math: 'R'},
          '. Match the ',
          {math: 'k-r'},
          ' universal elements of ',
          {math: 'Z'},
          ' to the remaining presentation vertices. Thus the new presentation ' +
            'has rank ',
          {math: 'k'},
          '.',
        ],
      },
    ];
    specifications.forEach((specification) => {
      const environment = document.createElement('div');
      environment.className = 'theorem-environment ' + specification.className;
      environment.dataset.sourceLine = specification.line;
      environment.style.width = '360px';
      const sourceLink = document.createElement('a');
      sourceLink.className = 'source-line-link';
      sourceLink.textContent = specification.line;
      const first = document.createElement('p');
      const header = document.createElement('span');
      header.className = 'theorem-header';
      const type = document.createElement('span');
      type.className = 'type';
      type.textContent = specification.className;
      header.append(type);
      if (specification.index) {
        const index = document.createElement('span');
        index.className = 'index';
        index.textContent = specification.index;
        header.append(index);
      }
      first.append(header);
      specification.opening.forEach((part) => {
        if (typeof part === 'string') {
          first.append(part);
          return;
        }
        const math = document.createElement('span');
        math.className = 'math inline';
        window.katex.render(part.math, math, {throwOnError: false});
        first.append(math);
      });
      const second = document.createElement('p');
      second.textContent = Array(3).fill(
          'A second paragraph confirms independent discovery inside the same ' +
          'theorem environment.',
      ).join(' ');
      environment.append(sourceLink, first, second);
      section.appendChild(environment);
    });
    document.querySelector('section.body').appendChild(section);
    await window.__pandocmd.lineBreaking.refresh(section);

    return Array.from(section.children).map((environment) => {
      const paragraphs = Array.from(environment.querySelectorAll(':scope > p'));
      const first = paragraphs[0];
      const header = first.querySelector('.theorem-header');
      const firstBodyWord = Array.from(first.querySelectorAll(
          '[data-pandocmd-kp-token="word"]',
      )).find((word) => !word.closest('.theorem-header'));
      const sourceLink = environment.querySelector(':scope > .source-line-link');
      return {
        className: environment.classList[1],
        outerStatus: environment.getAttribute('data-pandocmd-kp-status'),
        firstParagraphStatus: first.getAttribute('data-pandocmd-kp-status'),
        firstParagraphBroken: first.querySelector(
            '[data-pandocmd-kp-generated="break"]') !== null,
        inlineMathCount: first.querySelectorAll('.math.inline').length,
        secondParagraphDiscovered: /^(laid-out|fallback)$/.test(
            paragraphs[1].getAttribute('data-pandocmd-kp-status')),
        headerInFirstParagraph: header.parentElement === first,
        headerAndBodyShareLine: Math.abs(
            header.getBoundingClientRect().top -
            firstBodyWord.getBoundingClientRect().top,
        ) < 1,
        sourceLine: environment.dataset.sourceLine,
        sourceLabel: sourceLink.textContent,
        sourceLabelTokens: sourceLink.querySelectorAll(
            '[data-pandocmd-kp-token]',
        ).length,
      };
    });
  });

  expect(result).toEqual([
    {
      className: 'Theorem',
      outerStatus: null,
      firstParagraphStatus: 'laid-out',
      firstParagraphBroken: true,
      inlineMathCount: 0,
      secondParagraphDiscovered: true,
      headerInFirstParagraph: true,
      headerAndBodyShareLine: true,
      sourceLine: '41',
      sourceLabel: '41',
      sourceLabelTokens: 0,
    },
    {
      className: 'Proof',
      outerStatus: null,
      firstParagraphStatus: 'laid-out',
      firstParagraphBroken: true,
      inlineMathCount: 7,
      secondParagraphDiscovered: true,
      headerInFirstParagraph: true,
      headerAndBodyShareLine: true,
      sourceLine: '52',
      sourceLabel: '52',
      sourceLabelTokens: 0,
    },
  ]);
});

test('aligns algorithm source-line markers with their paragraphs', async ({page}) => {
  const geometry = await page.locator('#alg\\:source-line-fixture').evaluate(
      (algorithm) => Array.from(algorithm.querySelectorAll(
          '.algo-box .source-line-link',
      )).map((marker) => {
        const owner = marker.parentElement;
        const line = owner.querySelector(':scope > p > .algo-line');
        const markerRect = marker.getBoundingClientRect();
        const lineRect = line.getBoundingClientRect();
        return {
          markerRight: markerRect.right,
          markerTop: markerRect.top,
          lineTop: lineRect.top,
        };
      }),
  );

  expect(geometry).toHaveLength(3);
  expect(Math.max(...geometry.map((item) => item.markerRight)) -
    Math.min(...geometry.map((item) => item.markerRight))).toBeLessThanOrEqual(0.5);
  for (const item of geometry) {
    expect(Math.abs(item.markerTop - item.lineTop)).toBeLessThanOrEqual(0.5);
  }
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
    const stylesheets = Array.from(document.querySelectorAll(
        'head link[rel~="stylesheet"]',
    ));
    const measurements = controller.debugStats.measurements;
    const solves = controller.debugStats.solves;
    const reused = controller.debugStats.reusedRuns;
    link.focus();
    await window.__pandocmd.softReload();
    return {
      sameController: controller === window.__pandocmd.lineBreaking,
      sameParagraph: paragraph === document.querySelector('section.body p'),
      sameLink: link === document.querySelector('section.body p a'),
      retainedFocus: document.activeElement === link,
      retainedStylesheets: stylesheets.every(
          (stylesheet, index) => stylesheet === document.querySelectorAll(
              'head link[rel~="stylesheet"]',
          )[index],
      ),
      measurements: controller.debugStats.measurements - measurements,
      solves: controller.debugStats.solves - solves,
      reused: controller.debugStats.reusedRuns - reused,
    };
  });
  expect(reloaded.sameController).toBe(true);
  expect(reloaded.sameParagraph).toBe(true);
  expect(reloaded.sameLink).toBe(true);
  expect(reloaded.retainedFocus).toBe(true);
  expect(reloaded.retainedStylesheets).toBe(true);
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

test('loads versioned page/CSS assets and filters reload paths', async ({page}) => {
  const runtime = await page.evaluate(() => {
    const pageFingerprint = document.querySelector(
        'meta[name="pandocmd-page-fingerprint"]',
    );
    const stylesheetFingerprint = document.querySelector(
        'meta[name="pandocmd-stylesheet-fingerprint"]',
    );
    const pageScript = document.querySelector('script[src*="/js/page.js?v="]');
    const cssLinks = Array.from(document.querySelectorAll(
        'head link[rel~="stylesheet"][href*="/css/"]',
    ));

    return {
      pageFingerprint: pageFingerprint && pageFingerprint.content,
      stylesheetFingerprint: stylesheetFingerprint &&
        stylesheetFingerprint.content,
      pageScript: pageScript && pageScript.src,
      cssCount: cssLinks.length,
      versionedCss: cssLinks.length > 0 && cssLinks.every(
          (stylesheet) => new URL(stylesheet.href).searchParams.has('v'),
      ),
      samePath: window.__pandocmd.reloadPathMatches(window.location.pathname),
      otherPath: window.__pandocmd.reloadPathMatches('/preview/other.html'),
      liveReloadMeta: Boolean(document.querySelector(
          'meta[name="pandocmd-live-reload-url"]',
      )),
    };
  });

  expect(runtime.pageFingerprint).toMatch(/^[a-f0-9]{40}$/);
  expect(runtime.stylesheetFingerprint).toMatch(/^[a-f0-9]{40}$/);
  expect(runtime.pageScript).toMatch(/\/js\/page\.js\?v=[a-f0-9]{40}$/);
  expect(runtime.cssCount).toBe(2);
  expect(runtime.versionedCss).toBe(true);
  expect(runtime.samePath).toBe(true);
  expect(runtime.otherPath).toBe(false);
  expect(runtime.liveReloadMeta).toBe(false);
});

test('hot-swaps only changed CSS before committing new content', async ({page}) => {
  const result = await page.evaluate(async () => {
    const originalFetch = window.fetch;
    const response = await originalFetch(window.location.href, {cache: 'no-store'});
    const html = await response.text();
    const parsed = new DOMParser().parseFromString(html, 'text/html');
    const oldStylesheets = Array.from(document.querySelectorAll(
        'head link[rel~="stylesheet"]',
    ));
    const oldCss = oldStylesheets.filter(
        (stylesheet) => new URL(stylesheet.href).pathname.includes('/css/'),
    );
    const oldDefault = oldCss.find(
        (stylesheet) => new URL(stylesheet.href).pathname.endsWith(
            '/css/default.css',
        ),
    );
    const oldKatex = oldStylesheets.find(
        (stylesheet) => new URL(stylesheet.href).pathname.includes('/katex/'),
    );

    const nextDefault = Array.from(parsed.querySelectorAll(
        'head link[rel~="stylesheet"][href*="/css/"]',
    )).find(
        (stylesheet) => new URL(
            stylesheet.href, window.location.href,
        ).pathname.endsWith('/css/default.css'),
    );
    const nextDefaultUrl = new URL(
        nextDefault.getAttribute('href'), window.location.href,
    );
    nextDefaultUrl.searchParams.set('v', 'reload-test');
    nextDefault.setAttribute(
        'href', nextDefaultUrl.pathname + nextDefaultUrl.search,
    );
    parsed.querySelector(
        'meta[name="pandocmd-stylesheet-fingerprint"]',
    ).content = '0000000000000000000000000000000000000000';
    parsed.querySelector('section.body').setAttribute(
        'data-stylesheet-reload-test', '',
    );
    const changedHtml = '<!doctype html>\n' + parsed.documentElement.outerHTML;

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

    const currentStylesheets = Array.from(document.querySelectorAll(
        'head link[rel~="stylesheet"]',
    ));
    const currentCss = currentStylesheets.filter(
        (stylesheet) => new URL(stylesheet.href).pathname.includes('/css/'),
    );
    return {
      committed: document.querySelector('section.body').hasAttribute(
          'data-stylesheet-reload-test',
      ),
      count: currentStylesheets.length,
      oldDefaultRemoved: !oldDefault.isConnected,
      unchangedCssRetained: oldCss.every(
          (stylesheet) => stylesheet === oldDefault || stylesheet.isConnected,
      ),
      newCssLoaded: currentCss.every((stylesheet) => Boolean(stylesheet.sheet)),
      newDefaultVersion: new URL(currentCss.find(
          (stylesheet) => new URL(stylesheet.href).pathname.endsWith(
              '/css/default.css',
          ),
      ).href).searchParams.get('v'),
      retainedKatex: oldKatex === currentStylesheets.find(
          (stylesheet) => new URL(stylesheet.href).pathname.includes('/katex/'),
      ),
    };
  });

  expect(result.committed).toBe(true);
  expect(result.count).toBeGreaterThan(0);
  expect(result.oldDefaultRemoved).toBe(true);
  expect(result.unchangedCssRetained).toBe(true);
  expect(result.newCssLoaded).toBe(true);
  expect(result.newDefaultVersion).toBe('reload-test');
  expect(result.retainedKatex).toBe(true);
});

test('keeps a visible retained anchor fixed when content is inserted above', async ({page}) => {
  const result = await page.evaluate(async () => {
    const paragraphs = Array.from(document.querySelectorAll('section.body p'));
    const anchor = paragraphs[Math.floor(paragraphs.length / 2)];
    const originalFetch = window.fetch;
    const response = await originalFetch(window.location.href, {cache: 'no-store'});
    const html = await response.text();
    const parsed = new DOMParser().parseFromString(html, 'text/html');
    const inserted = parsed.createElement('div');

    inserted.className = 'source-line';
    inserted.setAttribute('data-source-line', '99999');
    inserted.innerHTML = '<p>' + Array(80).fill(
        'Inserted prose changes the document height above the viewport.',
    ).join(' ') + '</p>';
    parsed.querySelector('section.body').insertBefore(
        inserted, parsed.querySelector('section.body').firstChild,
    );
    const changedHtml = '<!doctype html>\n' + parsed.documentElement.outerHTML;

    anchor.scrollIntoView({block: 'center'});
    const top = anchor.getBoundingClientRect().top;
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
      sameAnchor: anchor.isConnected,
      topDelta: anchor.getBoundingClientRect().top - top,
    };
  });

  expect(result.sameAnchor).toBe(true);
  expect(Math.abs(result.topDelta)).toBeLessThanOrEqual(1);
});

test('soft reload solves only an edited paragraph', async ({page}) => {
  const result = await page.evaluate(async () => {
    const controller = window.__pandocmd.lineBreaking;
    const unchanged = document.querySelector('section.body p');
    const changed = Array.from(document.querySelectorAll('section.body p')).find(
        (paragraph) => paragraph.textContent.includes('This paragraph has a forced'),
    );
    const theorem = document.querySelector('.theorem-environment');
    const theoremParagraph = theorem.querySelector(':scope > p');
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
      sameTheoremParagraph: theoremParagraph === document.querySelector(
          '.theorem-environment > p'),
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
  expect(result.sameTheoremParagraph).toBe(true);
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

test('never starts a line with closing punctuation', async ({page}) => {
  const result = await page.evaluate(async () => {
    const cases = [
      {kind: 'math-period', math: 'x \\allowbreak .', punctuation: '.'},
      {kind: 'math-comma', math: 'x \\allowbreak ,', punctuation: ','},
      {kind: 'optional-semicolon', optional: true, punctuation: ';'},
      {kind: 'spaced-closing-parenthesis', spaced: true, punctuation: ')'},
    ];
    const section = document.createElement('section');
    section.id = 'punctuation-line-start-fixture';
    cases.forEach((entry) => {
      for (let width = 80; width <= 160; width += 2) {
        const paragraph = document.createElement('p');
        paragraph.style.width = width + 'px';
        paragraph.dataset.kind = entry.kind;
        paragraph.dataset.punctuation = entry.punctuation;
        paragraph.append('lead words ');
        if (entry.math) {
          const math = document.createElement('span');
          math.className = 'math inline';
          window.katex.render(entry.math, math, {throwOnError: false});
          paragraph.append(math);
        } else {
          const code = document.createElement('code');
          code.textContent = 'x';
          paragraph.append(code);
          if (entry.optional) {
            paragraph.append(document.createElement('wbr'));
          } else if (entry.spaced) {
            paragraph.append(' ');
          }
          paragraph.append(entry.punctuation);
        }
        paragraph.append(' tail words for layout');
        section.appendChild(paragraph);
      }
    });
    document.querySelector('section.body').appendChild(section);
    await window.__pandocmd.lineBreaking.refresh(section);

    const paragraphs = Array.from(section.children);
    const leadingPunctuation = [];
    paragraphs.forEach((paragraph) => {
      const punctuation = paragraph.dataset.punctuation;
      const candidates = Array.from(paragraph.querySelectorAll(
          '.katex-html > .base, [data-pandocmd-kp-token="word"]',
      )).filter((element) => element.textContent === punctuation);
      candidates.forEach((element) => {
        const previous = element.previousElementSibling;
        if (previous && previous.matches(
            '[data-pandocmd-kp-generated="break"]')) {
          leadingPunctuation.push({
            kind: paragraph.dataset.kind,
            width: paragraph.style.width,
            punctuation: punctuation,
          });
        }
      });
    });
    return {
      generatedBreaks: section.querySelectorAll(
          '[data-pandocmd-kp-generated="break"]',
      ).length,
      laidOutKinds: Array.from(new Set(paragraphs.filter(
          (paragraph) => paragraph.dataset.pandocmdKpStatus === 'laid-out',
      ).map((paragraph) => paragraph.dataset.kind))).sort(),
      leadingPunctuation: leadingPunctuation,
    };
  });

  expect(result.generatedBreaks).toBeGreaterThan(0);
  expect(result.laidOutKinds).toEqual([
    'math-comma',
    'math-period',
    'optional-semicolon',
    'spaced-closing-parenthesis',
  ]);
  expect(result.leadingPunctuation).toEqual([]);
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
