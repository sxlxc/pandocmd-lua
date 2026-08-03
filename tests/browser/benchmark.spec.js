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

test('records a math-heavy layout benchmark', async ({page}) => {
  await page.goto('/preview/' + hash + '.html');
  await page.waitForFunction(() => Boolean(
      window.__pandocmd && window.__pandocmd.lineBreaking,
  ));
  await page.evaluate(() => window.__pandocmd.lineBreaking.ready);

  const result = await page.evaluate(async () => {
    const controller = window.__pandocmd.lineBreaking;
    const body = document.querySelector('.text-space section.body');
    const section = document.createElement('section');
    const math = window.katex.renderToString(
        'a_1 + b_2 + c_3 + d_4 = x_1 + y_2 + z_3',
        {output: 'htmlAndMathml', throwOnError: false},
    );
    for (let index = 0; index < 150; index += 1) {
      const paragraph = document.createElement('p');
      paragraph.innerHTML = 'A representative mathematical paragraph ' +
        '<span class="math inline" data-pandocmd-katex-source="benchmark">' +
        math + '</span> with enough surrounding prose to exercise ' +
        'measurement, hyphenation, solving, and final layout writes.';
      section.appendChild(paragraph);
    }
    controller.suspend();
    body.replaceChildren(section);
    const before = {
      measurements: controller.debugStats.measurements,
      solves: controller.debugStats.solves,
    };
    const started = performance.now();
    controller.resume();
    await controller.refresh(section);
    return {
      elapsedMs: Math.round((performance.now() - started) * 10) / 10,
      measurements: controller.debugStats.measurements - before.measurements,
      solves: controller.debugStats.solves - before.solves,
      laidOut: section.querySelectorAll(
          '[data-pandocmd-kp-status="laid-out"]',
      ).length,
    };
  });

  console.log('PANDOCMD_BENCHMARK ' + JSON.stringify(result));
  expect(result.laidOut).toBe(150);
});
