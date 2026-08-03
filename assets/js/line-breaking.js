/* global Hypher, Typeset */

(function() {
  'use strict';

  const ATOMIC_SELECTOR = [
    'code', 'img', 'svg', 'canvas', 'video', 'audio', 'iframe', 'object',
    'embed', 'input', 'select', 'textarea', 'button',
  ].join(',');
  const BLOCK_SELECTOR = [
    'p', 'li', 'dt', 'dd', 'blockquote', 'td', 'th', 'caption',
    '.csl-entry', '.csl-right-inline', '.theorem-environment', '.proof', '.sidenote',
    '.abstract',
  ].join(',');
  const EXCLUDED_SELECTOR = [
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'nav', '.toc', '#contents',
    '#contents-big', '.top-controls', '.algorithm', 'pre', '.math.display',
    '.equation', '.math-container', '.xref-preview', '[hidden]',
    '[aria-hidden="true"]',
  ].join(',');
  const GENERATED_SELECTOR = [
    '[data-pandocmd-kp-generated]', '[data-pandocmd-kp-token]',
  ].join(',');
  const NON_PROSE_SELECTOR = '.source-line-link';
  const COMPLEX_SCRIPT = new RegExp(
      '[\\u0590-\\u08ff\\u0900-\\u0dff\\u0e00-\\u109f\\u1780-\\u18af' +
      '\\u200c\\u200d\\u3040-\\u30ff\\u3400-\\u9fff\\uac00-\\ud7af]',
  );
  const BIDI_CONTROL = /[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/;
  const ITEM_LIMIT = 4096;
  const FRAME_BUDGET = 8;
  const rootNamespace = window.__pandocmd = window.__pandocmd || {};

  rootNamespace.createLineBreaking = function() {
    let generation = 0;
    let suspended = false;
    let destroyed = false;
    const runs = new Map();
    const widthCache = new Map();
    let pendingRoots = [];
    let resizeObserver = null;
    let scheduled = false;
    let processing = false;
    let currentBatch = null;
    let refreshWaiters = [];
    let resolveReady;
    const ready = new Promise(function(resolve) {
      resolveReady = resolve;
    });
    const stats = {
      measurements: 0,
      reusedRuns: 0,
      solves: 0,
      phases: [],
    };

    const controller = {
      ready: ready,
      adoptUnchanged: adoptUnchanged,
      refresh: refresh,
      suspend: suspend,
      resume: resume,
      scrubClone: scrubClone,
      destroy: destroy,
      debugStats: stats,
    };

    if (!supported()) {
      resolveReady();
      return controller;
    }

    resizeObserver = new ResizeObserver(handleResize);
    document.addEventListener('copy', handleCopy);
    window.addEventListener('beforeprint', handleBeforePrint);
    window.addEventListener('afterprint', handleAfterPrint);
    window.addEventListener('resize', handleWindowResize);

    const startGeneration = generation;
    document.fonts.ready.then(function() {
      if (!destroyed && generation === startGeneration) {
        refresh(document);
      }
    });

    return controller;

    function supported() {
      return Boolean(
          window.ResizeObserver && document.fonts && window.Range &&
        window.requestAnimationFrame && window.Typeset && Typeset.linebreak &&
        window.Hypher && Hypher.languages && Hypher.languages['en-us'],
      );
    }

    function refresh(root) {
      if (destroyed) {
        return Promise.resolve();
      }
      pendingRoots.push(root || document);
      schedule();
      return new Promise(function(resolve) {
        refreshWaiters.push(resolve);
      });
    }

    function adoptUnchanged(nextRoot) {
      if (destroyed || suspended || !nextRoot ||
          !nextRoot.querySelectorAll) {
        return 0;
      }
      const activeRuns = new Set(currentBatch ? currentBatch.runs : []);
      cancelPendingWork();
      const reusable = new Map();
      runs.forEach(function(run) {
        if (activeRuns.has(run) || !run.container.isConnected ||
            !/^(laid-out|fallback)$/.test(run.status)) {
          cleanRun(run, false);
          return;
        }
        const signature = run.reloadKey;
        const matches = reusable.get(signature) || [];
        matches.push(run.container);
        reusable.set(signature, matches);
      });
      const candidates = Array.prototype.slice.call(
          nextRoot.querySelectorAll(BLOCK_SELECTOR));
      if (nextRoot.matches && nextRoot.matches(BLOCK_SELECTOR)) {
        candidates.unshift(nextRoot);
      }
      let reused = 0;
      candidates.forEach(function(candidate) {
        const matches = reusable.get(reloadSignature(candidate));
        if (!matches || !matches.length || !candidate.parentNode) {
          return;
        }
        const current = matches.shift();
        syncSourceMetadata(current, candidate);
        candidate.parentNode.replaceChild(current, candidate);
        reused += 1;
      });
      stats.reusedRuns += reused;
      return reused;
    }

    function cancelPendingWork() {
      generation += 1;
      pendingRoots = [];
      currentBatch = null;
      processing = false;
      scheduled = false;
      resolveRefreshWaiters();
    }

    function schedule() {
      if (scheduled || processing || suspended || destroyed) {
        return;
      }
      scheduled = true;
      window.requestAnimationFrame(discoverPhase);
    }

    function discoverPhase() {
      if (destroyed || suspended) {
        scheduled = false;
        resolveRefreshWaiters();
        return;
      }
      const roots = pendingRoots.splice(0);
      const candidates = [];
      const seen = new Set();
      scheduled = false;
      stats.phases.push('markers');
      pruneDisconnectedRuns();

      roots.forEach(function(root) {
        discover(root).forEach(function(container) {
          if (!seen.has(container)) {
            seen.add(container);
            candidates.push(container);
          }
        });
      });

      const batch = {
        generation: generation,
        runs: candidates.map(prepareRun).filter(Boolean),
      };
      currentBatch = batch;
      if (!batch.runs.length) {
        currentBatch = null;
        resolveReady();
        if (pendingRoots.length) {
          schedule();
        } else {
          resolveRefreshWaiters();
        }
        return;
      }
      processing = true;
      window.requestAnimationFrame(function() {
        measurePhase(batch);
      });
    }

    function pruneDisconnectedRuns() {
      runs.forEach(function(run) {
        if (!run.container.isConnected) {
          cleanRun(run, false);
        }
      });
    }

    function discover(root) {
      const scope = root.nodeType === Node.DOCUMENT_NODE ?
        root.querySelector('.text-space section.body') : root;

      if (!scope || !scope.querySelectorAll) {
        return [];
      }
      const candidates = Array.prototype.slice.call(
          scope.querySelectorAll(BLOCK_SELECTOR));
      if (scope.matches && scope.matches(BLOCK_SELECTOR)) {
        candidates.unshift(scope);
      }
      const eligibleCandidates = candidates.filter(eligible);
      const candidateSet = new Set(eligibleCandidates);
      const containersWithCandidates = new Set();

      eligibleCandidates.forEach(function(container) {
        let ancestor = container.parentElement;
        while (ancestor) {
          if (candidateSet.has(ancestor)) {
            containersWithCandidates.add(ancestor);
            break;
          }
          ancestor = ancestor.parentElement;
        }
      });
      return eligibleCandidates.filter(function(container) {
        return !containersWithCandidates.has(container);
      });
    }

    function eligible(container) {
      if (!container.isConnected || container.closest(EXCLUDED_SELECTOR)) {
        return false;
      }
      if ((container.matches('li, dt, dd, blockquote, .abstract, ' +
          '.theorem-environment, .proof')) &&
          container.querySelector('p, li, dt, dd, table, blockquote')) {
        return false;
      }
      const style = getComputedStyle(container);
      if (style.display === 'none' || style.visibility === 'hidden' ||
          style.direction === 'rtl' ||
          /^(center|right|end)$/.test(style.textAlign)) {
        return false;
      }
      const text = sourceText(container);
      return Boolean(text.trim()) && !BIDI_CONTROL.test(text);
    }

    function prepareRun(container) {
      const previous = runs.get(container);
      const width = contentWidth(container);
      const signature = runSignature(container, width);
      if (previous && previous.signature === signature &&
          /^(laid-out|fallback)$/.test(previous.status)) {
        return null;
      }
      if (previous) {
        cleanRun(previous, false);
      }
      const run = {
        container: container,
        width: width,
        signature: signature,
        tokens: [],
        nodes: [],
        itemCount: 2,
        itemLimitExceeded: false,
        reloadKey: reloadSignature(container),
        status: 'prepared',
        generation: generation,
      };
      runs.set(container, run);
      resizeObserver.observe(container);

      if (!isFinite(width) || width <= 0 || unsafeText(container)) {
        fallback(run, 'unsafe-geometry');
        return null;
      }
      if (deferForImages(run)) {
        run.status = 'deferred';
        return null;
      }
      tokenizeChildren(container, run);
      if (run.itemLimitExceeded) {
        fallback(run, 'item-limit');
        return null;
      }
      if (!run.tokens.length) {
        fallback(run, 'empty');
        return null;
      }
      return run;
    }

    function runSignature(container, width) {
      const style = getComputedStyle(container);
      const typography = [
        style.fontFamily, style.fontSize, style.fontStyle, style.fontWeight,
        style.fontStretch, style.fontVariant, style.fontFeatureSettings,
        style.fontKerning, style.fontOpticalSizing, style.letterSpacing,
        style.wordSpacing, style.lineHeight, style.direction,
      ].join('|');
      return sourceText(container) + '\u0000' + width.toFixed(3) +
        '\u0000' + typography;
    }

    function contentWidth(container) {
      const style = getComputedStyle(container);
      const rect = container.getBoundingClientRect();
      return rect.width - parseFloat(style.paddingLeft || 0) -
        parseFloat(style.paddingRight || 0);
    }

    function unsafeText(container) {
      const text = sourceText(container);
      const unicodeBidi = getComputedStyle(container).unicodeBidi;
      return COMPLEX_SCRIPT.test(text) ||
        /^(bidi-override|embed|isolate-override)$/.test(unicodeBidi);
    }

    function deferForImages(run) {
      let waiting = false;
      Array.prototype.slice.call(run.container.querySelectorAll('img')).forEach(
          function(image) {
            if (!image.complete) {
              waiting = true;
              if (!image.hasAttribute('data-pandocmd-kp-waiting')) {
                image.setAttribute('data-pandocmd-kp-waiting', '');
                const done = function() {
                  image.removeAttribute('data-pandocmd-kp-waiting');
                  refresh(run.container);
                };
                image.addEventListener('load', done, {once: true});
                image.addEventListener('error', done, {once: true});
              }
            }
          });
      return waiting;
    }

    function tokenizeChildren(container, run) {
      const children = Array.prototype.slice.call(container.childNodes);
      for (let index = 0; index < children.length; index += 1) {
        tokenizeNode(children[index], run);
        if (run.itemLimitExceeded) {
          return;
        }
      }
    }

    function tokenizeNode(node, run) {
      if (node.nodeType === Node.TEXT_NODE) {
        tokenizeText(node, run);
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE ||
          node.matches(GENERATED_SELECTOR) ||
          node.matches(NON_PROSE_SELECTOR)) {
        return;
      }
      if (node.matches('br')) {
        appendToken(run, {kind: 'forced', element: node});
        return;
      }
      if (node.matches('wbr')) {
        appendToken(run, {kind: 'optional', element: node});
        return;
      }
      if (node.matches('.math.inline') && tokenizeMath(node, run)) {
        return;
      }
      const style = getComputedStyle(node);
      if (node.matches(ATOMIC_SELECTOR) || style.display === 'inline-block' ||
          style.display === 'inline-flex' || style.display === 'inline-grid' ||
          style.whiteSpace.indexOf('nowrap') !== -1) {
        appendToken(run, {kind: 'atomic', element: node});
        return;
      }
      const children = Array.prototype.slice.call(node.childNodes);
      for (let index = 0; index < children.length; index += 1) {
        tokenizeNode(children[index], run);
        if (run.itemLimitExceeded) {
          return;
        }
      }
    }

    function tokenizeMath(math, run) {
      const html = math.querySelector('.katex-html');
      if (!html) {
        appendToken(run, {kind: 'atomic', element: math});
        return true;
      }
      let previousBase = null;
      for (let index = 0; index < html.children.length; index += 1) {
        const base = html.children[index];
        if (!base.classList.contains('base')) {
          continue;
        }
        if (previousBase && !appendToken(run, {
          kind: 'math-break',
          element: previousBase,
          penalty: mathPenalty(previousBase),
        })) {
          return true;
        }
        if (!appendToken(run, {kind: 'atomic', element: base, math: true})) {
          return true;
        }
        previousBase = base;
      }
      if (!previousBase) {
        appendToken(run, {kind: 'atomic', element: math});
        return true;
      }
      return true;
    }

    function appendToken(run, token) {
      if (!reserveToken(run)) {
        return false;
      }
      run.tokens.push(token);
      return true;
    }

    function reserveToken(run) {
      if (run.itemCount >= ITEM_LIMIT) {
        run.itemLimitExceeded = true;
        return false;
      }
      run.itemCount += 1;
      return true;
    }

    function mathPenalty(base) {
      if (base.querySelector('.nobreak')) {
        return Typeset.linebreak.infinity;
      }
      if (base.querySelector('.mrel')) {
        return 25;
      }
      if (base.querySelector('.mbin')) {
        return 75;
      }
      return 50;
    }

    function tokenizeText(textNode, run) {
      const text = textNode.data;
      if (!text) {
        return;
      }
      const fragment = document.createDocumentFragment();
      const pattern = /[ \t\r\n\f]+|\u00a0+|[^ \t\r\n\f\u00a0]+/g;
      let match = pattern.exec(text);
      while (match) {
        const part = match[0];
        if (!reserveToken(run)) {
          return;
        }
        const span = document.createElement('span');
        span.setAttribute('data-pandocmd-kp-token',
          /^[ \t\r\n\f]+$/.test(part) ? 'space' : 'word');
        span.textContent = part;
        fragment.appendChild(span);
        const token = {
          kind: /^[ \t\r\n\f]+$/.test(part) ? 'space' : 'word',
          element: span,
          text: part,
          parts: null,
        };
        run.tokens.push(token);
        match = pattern.exec(text);
      }
      textNode.parentNode.replaceChild(fragment, textNode);
    }

    function measurePhase(batch) {
      if (cancelStaleBatch(batch)) {
        return;
      }
      stats.phases.push('reads');
      processChunk(batch.runs, measureRun, function() {
        window.requestAnimationFrame(function() {
          solvePhase(batch);
        });
      });
    }

    function measureRun(run) {
      if (run.generation !== generation || destroyed || suspended) {
        return;
      }
      if (!prepareWordParts(run)) {
        fallback(run, 'item-limit');
        return;
      }
      let oversized = false;
      run.tokens.forEach(function(token) {
        if (token.kind === 'word') {
          token.parts.forEach(function(part) {
            part.width = textWidth(part.element, part.text);
          });
        } else if (token.kind === 'space') {
          token.width = textWidth(token.element, ' ');
        } else if (token.kind === 'atomic') {
          token.width = token.element.getBoundingClientRect().width;
          stats.measurements += 1;
          if (!isFinite(token.width) || token.width > run.width) {
            oversized = true;
          }
        }
      });
      run.hyphenWidth = textWidth(run.container, '-');
      if (oversized) {
        fallback(run, 'oversized-atomic');
      }
    }

    function prepareWordParts(run) {
      const plans = [];
      let itemCount = run.itemCount;
      for (let index = 0; index < run.tokens.length; index += 1) {
        const token = run.tokens[index];
        if (token.kind !== 'word') {
          continue;
        }
        const plan = wordPartPlan(token);
        const extraItems = 2 * (plan.pieces.length - 1);
        if (itemCount + extraItems > ITEM_LIMIT) {
          run.itemLimitExceeded = true;
          return false;
        }
        itemCount += extraItems;
        plans.push({token: token, plan: plan});
      }
      plans.forEach(function(entry) {
        entry.token.parts = materializeWordParts(entry.token, entry.plan);
      });
      run.itemCount = itemCount;
      return true;
    }

    function wordPartPlan(token) {
      const authored = token.text.indexOf('\u00ad') !== -1;
      const language = nearestLanguage(token.element);
      let pieces = [token.text];
      if (authored) {
        pieces = token.text.split('\u00ad');
      } else if (shouldHyphenate(token.text, language)) {
        pieces = Hypher.languages['en-us'].hyphenate(token.text);
      }
      return {authored: authored, pieces: pieces};
    }

    function materializeWordParts(token, plan) {
      if (plan.pieces.length === 1) {
        return [{element: token.element, text: token.text, authored: false}];
      }
      token.element.textContent = '';
      return plan.pieces.map(function(piece, index) {
        const span = document.createElement('span');
        span.setAttribute('data-pandocmd-kp-token', 'word');
        span.textContent = piece;
        token.element.appendChild(span);
        if (plan.authored && index < plan.pieces.length - 1) {
          const shy = document.createElement('span');
          shy.setAttribute('data-pandocmd-kp-token', 'soft-hyphen');
          shy.textContent = '\u00ad';
          token.element.appendChild(shy);
        }
        return {element: span, text: piece, authored: plan.authored};
      });
    }

    function nearestLanguage(element) {
      const ancestor = element.parentElement && element.parentElement.closest('[lang]');
      return (ancestor ? ancestor.getAttribute('lang') :
        document.documentElement.lang || '').toLowerCase();
    }

    function shouldHyphenate(word, language) {
      return /^en(?:-|$)/.test(language) && word.length >= 6 &&
        /^[A-Za-z]+(?:['’][A-Za-z]+)?$/.test(word) &&
        !/[a-z][A-Z]/.test(word) && !/^[A-Z]+$/.test(word) &&
        !looksLikeAddress(word);
    }

    function looksLikeAddress(word) {
      return /(?:https?:|www\.|@|[_.]\w|\w\/\w)/i.test(word) ||
        /\d|_/.test(word);
    }

    function textWidth(element, text) {
      const style = getComputedStyle(element);
      const signature = [
        style.fontFamily, style.fontSize, style.fontStyle, style.fontWeight,
        style.fontStretch, style.fontVariant, style.fontFeatureSettings,
        style.fontKerning, style.fontOpticalSizing, style.letterSpacing,
        style.textTransform,
      ].join('|');
      const key = signature + '\u0000' + text;
      const cached = widthCache.get(key);
      let width;
      if (cached !== undefined) {
        return cached;
      }
      const canvas = textWidth.canvas || (textWidth.canvas =
        document.createElement('canvas'));
      const context = canvas.getContext('2d');
      context.font = style.font;
      context.fontKerning = style.fontKerning;
      width = context.measureText(text).width;
      if (style.letterSpacing !== 'normal') {
        width += parseFloat(style.letterSpacing) * text.length;
      }
      widthCache.set(key, width);
      stats.measurements += 1;
      return width;
    }

    function solvePhase(batch) {
      if (cancelStaleBatch(batch)) {
        return;
      }
      stats.phases.push('solve');
      processChunk(batch.runs, solveRun, function() {
        window.requestAnimationFrame(function() {
          writePhase(batch);
        });
      });
    }

    function solveRun(run) {
      if (run.status !== 'prepared' || run.generation !== generation ||
          destroyed || suspended) {
        return;
      }
      buildItems(run);
      if (run.nodes.length > ITEM_LIMIT) {
        fallback(run, 'item-limit');
        return;
      }
      stats.solves += 1;
      run.breaks = Typeset.linebreak(run.nodes, [run.width], {
        tolerance: 2,
        maxTolerance: 4,
      });
      if (!run.breaks || run.breaks.length < 2 ||
          run.breaks[run.breaks.length - 1].position !== run.nodes.length - 1) {
        fallback(run, 'no-solution');
      }
    }

    function buildItems(run) {
      run.nodes = [];
      run.tokens.forEach(function(token) {
        let node;
        if (token.kind === 'word') {
          token.parts.forEach(function(part, index) {
            node = Typeset.linebreak.box(part.width, part);
            node.dom = part;
            run.nodes.push(node);
            if (index < token.parts.length - 1) {
              node = Typeset.linebreak.penalty(
                  run.hyphenWidth, part.authored ? 50 : 100, 1);
              node.dom = {
                kind: 'hyphen',
                anchor: part.element,
                authored: part.authored,
              };
              run.nodes.push(node);
            }
          });
        } else if (token.kind === 'space') {
          node = Typeset.linebreak.glue(
              token.width, token.width / 2, token.width / 3);
          node.dom = token;
          run.nodes.push(node);
        } else if (token.kind === 'atomic') {
          node = Typeset.linebreak.box(token.width, token);
          node.dom = token;
          run.nodes.push(node);
        } else if (token.kind === 'optional' || token.kind === 'math-break') {
          node = Typeset.linebreak.penalty(
              0, token.penalty === undefined ? 0 : token.penalty, 0);
          node.dom = {kind: token.kind, anchor: token.element};
          run.nodes.push(node);
        } else if (token.kind === 'forced') {
          node = Typeset.linebreak.penalty(0, -Typeset.linebreak.infinity, 1);
          node.dom = {kind: 'forced', anchor: token.element};
          run.nodes.push(node);
        }
      });
      const finalGlue = Typeset.linebreak.glue(
          0, Typeset.linebreak.infinity, 0);
      finalGlue.dom = {kind: 'final-glue'};
      run.nodes.push(finalGlue);
      const finalPenalty = Typeset.linebreak.penalty(
          0, -Typeset.linebreak.infinity, 1);
      finalPenalty.dom = {kind: 'final'};
      run.nodes.push(finalPenalty);
    }

    function writePhase(batch) {
      if (cancelStaleBatch(batch)) {
        return;
      }
      stats.phases.push('writes');
      processChunk(batch.runs, renderRun, function() {
        window.requestAnimationFrame(function() {
          calibrationReadPhase(batch);
        });
      });
    }

    function calibrationReadPhase(batch) {
      if (cancelStaleBatch(batch)) {
        return;
      }
      stats.phases.push('calibration-reads');
      processChunk(batch.runs, measureLineCorrections, function() {
        window.requestAnimationFrame(function() {
          calibrationWritePhase(batch);
        });
      });
    }

    function measureLineCorrections(run) {
      const containerStyle = getComputedStyle(run.container);
      const containerRect = run.container.getBoundingClientRect();
      const targetRight = containerRect.right -
        parseFloat(containerStyle.borderRightWidth || 0) -
        parseFloat(containerStyle.paddingRight || 0);
      run.corrections = [];
      if (run.status !== 'laid-out' || run.generation !== generation) {
        return;
      }
      run.breaks.slice(1).forEach(function(breakpoint, index) {
        const finalLine = index === run.breaks.length - 2;
        const start = run.breaks[index].position;
        const end = breakpoint.position;
        const nodes = run.nodes.slice(start + 1, end + 1);
        const spaces = nodes.filter(function(node) {
          return node.type === 'glue' && node.dom &&
            node.dom.kind === 'space' &&
            getComputedStyle(node.dom.element).display !== 'none';
        });
        let right = -Infinity;
        if (finalLine || !spaces.length) {
          return;
        }
        nodes.forEach(function(node) {
          const dom = node.dom || {};
          const element = dom.element || dom.anchor;
          if (!element || !element.isConnected ||
              getComputedStyle(element).display === 'none') {
            return;
          }
          Array.prototype.forEach.call(element.getClientRects(), function(rect) {
            right = Math.max(right, rect.right);
          });
        });
        const residual = targetRight - right;
        if (!isFinite(residual) || Math.abs(residual) > run.width / 10) {
          return;
        }
        const delta = residual / spaces.length;
        spaces.forEach(function(node) {
          run.corrections.push({
            element: node.dom.element,
            width: parseFloat(node.dom.element.style.width) || node.dom.width,
            delta: delta,
          });
        });
      });
    }

    function calibrationWritePhase(batch) {
      if (cancelStaleBatch(batch)) {
        return;
      }
      stats.phases.push('calibration-writes');
      processChunk(batch.runs, applyLineCorrections, function() {
        finishBatch(batch);
      });
    }

    function applyLineCorrections(run) {
      if (run.generation !== generation || destroyed || suspended) {
        return;
      }
      (run.corrections || []).forEach(function(correction) {
        correction.element.style.width = Math.max(
            0, correction.width + correction.delta,
        ).toFixed(3) + 'px';
      });
      run.corrections = [];
    }

    function finishBatch(batch) {
      if (batch !== currentBatch) {
        return;
      }
      currentBatch = null;
      processing = false;
      resolveReady();
      if (pendingRoots.length) {
        schedule();
      } else {
        resolveRefreshWaiters();
      }
    }

    function resolveRefreshWaiters() {
      const waiters = refreshWaiters;
      refreshWaiters = [];
      waiters.forEach(function(resolve) {
        resolve();
      });
    }

    function cancelStaleBatch(batch) {
      const stale = destroyed || suspended || batch !== currentBatch ||
        batch.generation !== generation;
      if (!stale) {
        return false;
      }
      if (batch !== currentBatch) {
        return true;
      }
      currentBatch = null;
      processing = false;
      if (pendingRoots.length && !destroyed && !suspended) {
        schedule();
      } else {
        resolveRefreshWaiters();
      }
      return true;
    }

    function renderRun(run) {
      if (run.status !== 'prepared' || run.generation !== generation ||
          destroyed || suspended) {
        return;
      }
      run.container.classList.add('pandocmd-kp-active');
      run.breaks.slice(1).forEach(function(breakpoint, index) {
        const finalBreak = index === run.breaks.length - 2;
        const previous = run.breaks[index].position;
        const position = breakpoint.position;
        if (!finalBreak) {
          adjustSpaces(run, previous, position, breakpoint.ratio);
          insertBreak(run.nodes[position]);
        }
      });
      run.status = 'laid-out';
      run.container.setAttribute('data-pandocmd-kp-status', 'laid-out');
    }

    function adjustSpaces(run, start, end, ratio) {
      run.nodes.slice(start + 1, end).forEach(function(node) {
        if (node.type !== 'glue' || !node.dom ||
            node.dom.kind !== 'space') {
          return;
        }
        const token = node.dom;
        const width = token.width + (ratio >= 0 ?
          ratio * token.width / 2 : ratio * token.width / 3);
        token.element.style.width = Math.max(0, width).toFixed(3) + 'px';
      });
    }

    function insertBreak(node) {
      const dom = node.dom;
      let hyphen;
      if (!dom || dom.kind === 'forced' || dom.kind === 'final') {
        return;
      }
      const br = document.createElement('br');
      br.className = 'pandocmd-kp-break';
      br.setAttribute('data-pandocmd-kp-generated', 'break');
      br.setAttribute('aria-hidden', 'true');
      if (node.type === 'glue' && dom.kind === 'space') {
        dom.element.style.display = 'none';
        dom.element.parentNode.insertBefore(br, dom.element.nextSibling);
      } else {
        if (dom.kind === 'hyphen') {
          hyphen = document.createElement('span');
          hyphen.className = 'pandocmd-kp-hyphen';
          hyphen.setAttribute('data-pandocmd-kp-generated', 'hyphen');
          hyphen.setAttribute('aria-hidden', 'true');
          hyphen.textContent = '-';
          dom.anchor.parentNode.insertBefore(hyphen, dom.anchor.nextSibling);
          dom.anchor = hyphen;
        }
        dom.anchor.parentNode.insertBefore(br, dom.anchor.nextSibling);
      }
    }

    function fallback(run, reason) {
      cleanRun(run, true);
      run.tokens = [];
      run.nodes = [];
      run.breaks = [];
      run.corrections = [];
      run.status = 'fallback';
      run.container.classList.add('pandocmd-kp-fallback');
      run.container.setAttribute('data-pandocmd-kp-status', 'fallback');
      run.container.setAttribute('data-pandocmd-kp-fallback', reason);
    }

    function cleanRun(run, keepRecord) {
      const container = run.container;
      if (container && container.isConnected) {
        Array.prototype.slice.call(container.querySelectorAll(
            '[data-pandocmd-kp-generated]')).forEach(removeNode);
        unwrapTokens(container);
        container.classList.remove('pandocmd-kp-active');
        container.classList.remove('pandocmd-kp-fallback');
        container.removeAttribute('data-pandocmd-kp-status');
        container.removeAttribute('data-pandocmd-kp-fallback');
        container.normalize();
      }
      if (!keepRecord) {
        if (resizeObserver && container) {
          resizeObserver.unobserve(container);
        }
        runs.delete(container);
      }
    }

    function unwrapTokens(root) {
      const tokens = Array.prototype.slice.call(root.querySelectorAll(
          '[data-pandocmd-kp-token]')).reverse();
      tokens.forEach(function(token) {
        const parent = token.parentNode;
        if (!parent) {
          return;
        }
        while (token.firstChild) {
          parent.insertBefore(token.firstChild, token);
        }
        parent.removeChild(token);
      });
    }

    function removeNode(node) {
      if (node.parentNode) {
        node.parentNode.removeChild(node);
      }
    }

    function processChunk(items, operation, done) {
      let index = 0;
      function chunk() {
        const started = performance.now();
        while (index < items.length &&
            performance.now() - started < FRAME_BUDGET) {
          operation(items[index]);
          index += 1;
        }
        if (index < items.length) {
          window.requestAnimationFrame(chunk);
        } else {
          done();
        }
      }
      chunk();
    }

    function sourceText(root) {
      const clone = root.cloneNode(true);
      scrubClone(clone);
      Array.prototype.slice.call(clone.querySelectorAll(
          NON_PROSE_SELECTOR)).forEach(removeNode);
      return clone.textContent || '';
    }

    function reloadSignature(root) {
      const clone = root.cloneNode(true);
      scrubClone(clone);
      inclusiveElements(clone, '[data-pandocmd-katex-source]').forEach(
          function(math) {
            math.textContent = math.getAttribute('data-pandocmd-katex-source');
            math.removeAttribute('data-pandocmd-katex-source');
          });
      inclusiveElements(clone, '[data-source-line]').forEach(function(element) {
        element.setAttribute('data-source-line', '');
      });
      inclusiveElements(clone, NON_PROSE_SELECTOR).forEach(function(marker) {
        Array.prototype.slice.call(marker.attributes).forEach(
            function(attribute) {
              if (attribute.name !== 'class') {
                marker.removeAttribute(attribute.name);
              }
            });
        marker.textContent = '';
      });
      inclusiveElements(clone, '.section-fold-hidden').forEach(
          function(element) {
            element.classList.remove('section-fold-hidden');
            element.removeAttribute('aria-hidden');
            removeEmptyClass(element);
          });
      return clone.outerHTML;
    }

    function inclusiveElements(root, selector) {
      const elements = root.matches && root.matches(selector) ? [root] : [];
      return elements.concat(Array.prototype.slice.call(
          root.querySelectorAll(selector)));
    }

    function syncSourceMetadata(current, next) {
      const currentAnnotated = inclusiveElements(current, '[data-source-line]');
      const nextAnnotated = inclusiveElements(next, '[data-source-line]');
      currentAnnotated.forEach(function(element, index) {
        if (nextAnnotated[index]) {
          element.setAttribute('data-source-line',
              nextAnnotated[index].getAttribute('data-source-line'));
        }
      });
      const currentMarkers = inclusiveElements(current, NON_PROSE_SELECTOR);
      const nextMarkers = inclusiveElements(next, NON_PROSE_SELECTOR);
      currentMarkers.forEach(function(marker, index) {
        if (!nextMarkers[index] || !marker.parentNode) {
          return;
        }
        marker.parentNode.replaceChild(
            nextMarkers[index].cloneNode(true), marker);
      });
    }

    function scrubClone(node) {
      if (!node || !node.querySelectorAll) {
        return node;
      }
      Array.prototype.slice.call(node.querySelectorAll(
          '[data-pandocmd-kp-generated]')).forEach(removeNode);
      unwrapTokens(node);
      [node].concat(Array.prototype.slice.call(node.querySelectorAll(
          '.pandocmd-kp-active, .pandocmd-kp-fallback'))).forEach(function(element) {
        element.classList.remove('pandocmd-kp-active');
        element.classList.remove('pandocmd-kp-fallback');
        element.removeAttribute('data-pandocmd-kp-status');
        element.removeAttribute('data-pandocmd-kp-fallback');
        removeEmptyClass(element);
      });
      return node;
    }

    function removeEmptyClass(element) {
      if (!element.classList.length) {
        element.removeAttribute('class');
      }
    }

    function handleResize(entries) {
      entries.forEach(function(entry) {
        const run = runs.get(entry.target);
        const width = entry.contentRect.width;
        if (run && Math.abs(width - run.width) > 0.25) {
          pendingRoots.push(entry.target);
        }
      });
      if (pendingRoots.length) {
        schedule();
      }
    }

    function handleWindowResize() {
      runs.forEach(function(run) {
        pendingRoots.push(run.container);
      });
      schedule();
    }

    function handleCopy(event) {
      const selection = window.getSelection();
      if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
        return;
      }
      const range = selection.getRangeAt(0);
      const body = document.querySelector('.text-space section.body');
      if (!body || !body.contains(range.commonAncestorContainer)) {
        return;
      }
      const fragment = range.cloneContents();
      const wrapper = document.createElement('div');
      wrapper.appendChild(fragment);
      scrubClone(wrapper);
      event.clipboardData.setData('text/plain', wrapper.textContent || '');
      event.clipboardData.setData('text/html', wrapper.innerHTML);
      event.preventDefault();
    }

    function handleBeforePrint() {
      suspend();
    }

    function handleAfterPrint() {
      resume();
    }

    function suspend() {
      if (destroyed || suspended) {
        return;
      }
      suspended = true;
      generation += 1;
      pendingRoots = [];
      runs.forEach(function(run) {
        cleanRun(run, false);
      });
      runs.clear();
    }

    function resume() {
      if (destroyed || !suspended) {
        return;
      }
      suspended = false;
      refresh(document);
    }

    function destroy() {
      if (destroyed) {
        return;
      }
      generation += 1;
      destroyed = true;
      pendingRoots = [];
      resolveRefreshWaiters();
      if (resizeObserver) {
        resizeObserver.disconnect();
      }
      runs.forEach(function(run) {
        cleanRun(run, false);
      });
      runs.clear();
      document.removeEventListener('copy', handleCopy);
      window.removeEventListener('beforeprint', handleBeforePrint);
      window.removeEventListener('afterprint', handleAfterPrint);
      window.removeEventListener('resize', handleWindowResize);
      if (rootNamespace.lineBreaking === controller) {
        delete rootNamespace.lineBreaking;
      }
    }
  };
}());
