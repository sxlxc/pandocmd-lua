(function() {
  'use strict';

  window.__pandocmd = window.__pandocmd || {};
  let softReloadAbort = null;
  let softReloadGeneration = 0;

  function initKatex() {
    renderKatexMath();

    return function() {};

    function renderKatexMath() {
      if (!window.katex) {
        return;
      }

      const mathNodes = Array.prototype.slice.call(
          document.querySelectorAll('.math.inline, .math.display'),
      );
      mathNodes.forEach(function(mathNode) {
        const tex = mathNode.textContent;
        const displayMode = mathNode.classList.contains('display');

        if (!tex || mathNode.hasAttribute('data-pandocmd-katex-source')) {
          return;
        }

        try {
          window.katex.render(tex, mathNode, {
            displayMode: displayMode,
            throwOnError: false,
          });
        } catch (error) {
          return;
        }

        mathNode.setAttribute('data-pandocmd-katex-source', tex);
      });
    }
  }

  function initLineBreaking() {
    const previous = window.__pandocmd.lineBreaking;
    let teardown;

    if (previous && typeof previous.destroy === 'function') {
      previous.destroy();
    }
    if (typeof window.__pandocmd.createLineBreaking !== 'function') {
      teardown = function() {};
      teardown.pandocmdLineBreaking = true;
      return teardown;
    }

    const controller = window.__pandocmd.createLineBreaking();
    window.__pandocmd.lineBreaking = controller;
    controller.refresh(document.querySelector('.text-space section.body') || document);

    teardown = function() {
      controller.destroy();
    };
    teardown.pandocmdLineBreaking = true;
    return teardown;
  }

  function initFolding() {
    const body = document.querySelector('.text-space section.body');

    if (!body) {
      return function() {};
    }

    const headings = Array.prototype.slice.call(
        body.querySelectorAll('h1, h2, h3, h4, h5, h6'),
    );
    const storageKey = 'pandocmd:folded-sections:' + window.location.pathname;
    const folded = readFoldedSections();
    const foldableSections = [];
    const foldableNodes = [];
    const tocLinks = Array.prototype.slice.call(
        document.querySelectorAll('#contents a[href^="#"], #contents-big a[href^="#"]'),
    );

    headings.forEach(function(heading, index) {
      const nodes = sectionNodes(heading);
      const id = ensureHeadingId(heading, index);
      const button = document.createElement('button');
      const icon = document.createElement('span');
      const section = {
        id: id,
        heading: heading,
        button: button,
        nodes: nodes,
        title: compactText(heading.textContent),
      };

      heading.classList.add('section-heading-foldable');
      button.type = 'button';
      button.className = 'section-fold-button no-print';

      icon.className = 'section-fold-icon';
      icon.setAttribute('aria-hidden', 'true');
      icon.textContent = '>';
      button.appendChild(icon);

      button.addEventListener('click', function(event) {
        event.preventDefault();
        event.stopPropagation();
        folded[id] = !folded[id];
        syncFoldState(true);
      });

      heading.insertBefore(button, heading.firstChild);
      foldableSections.push(section);
      nodes.forEach(function(node) {
        if (foldableNodes.indexOf(node) === -1) {
          foldableNodes.push(node);
        }
      });
    });

    tocLinks.forEach(function(link) {
      link.addEventListener('click', function() {
        const target = headingForLink(link);

        if (target) {
          revealHeading(target);
        }
      });
    });

    syncFoldState(false);

    function readFoldedSections() {
      const state = Object.create(null);

      try {
        JSON.parse(window.localStorage.getItem(storageKey) || '[]').forEach(function(id) {
          state[id] = true;
        });
      } catch (error) {
        return Object.create(null);
      }

      return state;
    }

    function writeFoldedSections() {
      const ids = foldableSections
          .map(function(section) {
            return section.id;
          })
          .filter(function(id) {
            return folded[id];
          });

      try {
        if (ids.length) {
          window.localStorage.setItem(storageKey, JSON.stringify(ids));
        } else {
          window.localStorage.removeItem(storageKey);
        }
      } catch (error) {
        return;
      }
    }

    function ensureHeadingId(heading, index) {
      if (heading.id) {
        return heading.id;
      }

      let base = compactText(heading.textContent)
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, '-');
      let id;
      let suffix = 2;

      while (base.charAt(0) === '-') {
        base = base.slice(1);
      }

      while (base.charAt(base.length - 1) === '-') {
        base = base.slice(0, -1);
      }

      const candidate = 'pandocmd-section-' + (base || 'heading') + '-' +
        (index + 1);
      id = candidate;

      while (document.getElementById(id)) {
        id = candidate + '-' + suffix;
        suffix += 1;
      }

      heading.id = id;
      return id;
    }

    function compactText(text) {
      return (text || '').replace(/\s+/g, ' ').trim();
    }

    function sectionNodes(heading) {
      const level = headingLevel(heading);
      const nodes = [];
      let node = heading.nextElementSibling;

      while (node) {
        if (isHeading(node) && headingLevel(node) <= level) {
          break;
        }

        nodes.push(node);
        node = node.nextElementSibling;
      }

      return nodes;
    }

    function isHeading(node) {
      return (
        node.tagName.length === 2 &&
              node.tagName.charAt(0) === 'H' &&
              node.tagName.charAt(1) >= '1' &&
              node.tagName.charAt(1) <= '6'
      );
    }

    function headingLevel(heading) {
      return Number(heading.tagName.slice(1));
    }

    function syncFoldState(persist) {
      const hiddenNodes = [];

      foldableSections.forEach(function(section) {
        const isFolded = Boolean(folded[section.id]);

        section.heading.classList.toggle('section-heading-folded', isFolded);
        section.button.setAttribute('aria-expanded', String(!isFolded));
        section.button.setAttribute(
            'aria-label',
            (isFolded ? 'Unfold' : 'Fold') + labelSuffix(section.title),
        );
        section.button.setAttribute(
            'title', isFolded ? 'Unfold section' : 'Fold section',
        );

        if (isFolded) {
          section.nodes.forEach(function(node) {
            if (hiddenNodes.indexOf(node) === -1) {
              hiddenNodes.push(node);
            }
          });
        }
      });

      foldableNodes.forEach(function(node) {
        const isHidden = hiddenNodes.indexOf(node) !== -1;

        node.classList.toggle('section-fold-hidden', isHidden);

        if (isHidden) {
          node.setAttribute('aria-hidden', 'true');
        } else {
          node.removeAttribute('aria-hidden');
        }
      });

      syncToc();

      if (persist) {
        writeFoldedSections();
      }
    }

    function labelSuffix(title) {
      return title ? ' section ' + title : ' section';
    }

    function syncToc() {
      tocLinks.forEach(function(link) {
        const target = headingForLink(link);
        const isFolded = Boolean(target && folded[target.id]);
        const isInsideFoldedSection = Boolean(
            target &&
                  !isFolded &&
                  target.classList.contains('section-fold-hidden'),
        );

        link.classList.toggle('section-toc-folded', isFolded);
        link.classList.toggle('section-toc-in-folded-section', isInsideFoldedSection);
      });
    }

    function headingForLink(link) {
      let id = link.hash ? link.hash.slice(1) : '';

      if (!id) {
        return null;
      }

      try {
        id = decodeURIComponent(id);
      } catch (error) {
        return null;
      }

      const target = document.getElementById(id);

      return target && isHeading(target) ? target : null;
    }

    function revealHeading(heading) {
      let changed = false;

      foldableSections.forEach(function(section) {
        if (folded[section.id] && section.nodes.indexOf(heading) !== -1) {
          folded[section.id] = false;
          changed = true;
        }
      });

      if (changed) {
        syncFoldState(true);
      }
    }

    return function() {};
  }

  function initXref() {
    const body = document.querySelector('.text-space section.body');
    const targetSelector = [
      '.theorem-environment[id]',
      '.equation[id]',
      '.csl-entry[id]',
      'figure[id]',
      'table[id]',
      'div[id]:not(.source-line):not(.references):not(.csl-bib-body)',
    ].join(', ');
    let preview = null;
    let activeLink = null;
    let hideTimer = null;
    let linkListeners = [];

    if (!body) {
      return function() {};
    }

    Array.prototype.slice.call(body.querySelectorAll('a[href^="#"]')).forEach(function(link) {
      const showLink = function() {
        show(link);
      };

      link.addEventListener('pointerenter', showLink);
      link.addEventListener('pointerleave', scheduleHide);
      link.addEventListener('focusin', showLink);
      link.addEventListener('focusout', scheduleHide);
      linkListeners.push({link: link, show: showLink});
    });

    function ensurePreview() {
      if (preview) {
        return preview;
      }

      preview = document.createElement('div');
      preview.id = 'xref-preview';
      preview.className = 'xref-preview no-print';
      preview.setAttribute('role', 'tooltip');
      preview.hidden = true;
      preview.addEventListener('pointerenter', cancelHide);
      preview.addEventListener('pointerleave', scheduleHide);
      preview.addEventListener('focusin', cancelHide);
      preview.addEventListener('focusout', scheduleHide);
      (body.closest('.text-space') || document.body).appendChild(preview);

      return preview;
    }

    function show(link) {
      const target = previewTarget(link);
      if (!target) {
        return;
      }

      cancelHide();
      const box = ensurePreview();
      const clone = target.cloneNode(true);
      scrubClone(clone);

      if (activeLink && activeLink !== link) {
        activeLink.removeAttribute('aria-describedby');
      }

      activeLink = link;
      link.setAttribute('aria-describedby', box.id);
      box.innerHTML = '';
      box.appendChild(clone);
      box.hidden = false;
      box.style.visibility = 'hidden';
      positionPreview(link);
      box.style.visibility = '';

      window.addEventListener('scroll', syncPosition, true);
      window.addEventListener('resize', syncPosition);
      document.addEventListener('keydown', handleKeydown);
    }

    function hide() {
      cancelHide();

      if (activeLink) {
        activeLink.removeAttribute('aria-describedby');
      }

      activeLink = null;

      if (preview) {
        preview.hidden = true;
        preview.innerHTML = '';
      }

      window.removeEventListener('scroll', syncPosition, true);
      window.removeEventListener('resize', syncPosition);
      document.removeEventListener('keydown', handleKeydown);
    }

    function scheduleHide() {
      cancelHide();
      hideTimer = window.setTimeout(function() {
        if (isPointerOrFocusInside()) {
          return;
        }

        hide();
      }, 80);
    }

    function cancelHide() {
      if (hideTimer) {
        window.clearTimeout(hideTimer);
        hideTimer = null;
      }
    }

    function previewTarget(link) {
      if (
        link.classList.contains('source-line-link') ||
              link.closest(
                  '.toc, #contents, #contents-big, .top-controls, ' +
                  '.xref-preview',
              )
      ) {
        return null;
      }

      const id = hashId(link);
      if (!id) {
        return null;
      }

      const target = document.getElementById(id);
      if (!target || !body.contains(target) || !target.matches(targetSelector)) {
        return null;
      }

      return target;
    }

    function hashId(link) {
      const hash = link.hash || '';

      if (hash === '' || hash === '#') {
        return '';
      }

      try {
        return decodeURIComponent(hash.slice(1));
      } catch (error) {
        return '';
      }
    }

    function scrubClone(node) {
      if (
        window.__pandocmd.lineBreaking &&
              typeof window.__pandocmd.lineBreaking.scrubClone === 'function'
      ) {
        window.__pandocmd.lineBreaking.scrubClone(node);
      }

      Array.prototype.slice.call(
          node.querySelectorAll('.source-line-link'),
      ).forEach(function(child) {
        child.parentNode.removeChild(child);
      });

      Array.prototype.slice.call(
          node.querySelectorAll('.section-fold-button'),
      ).forEach(function(child) {
        child.parentNode.removeChild(child);
      });

      [node].concat(Array.prototype.slice.call(
          node.querySelectorAll('.section-fold-hidden'),
      )).forEach(function(child) {
        if (child.classList.contains('section-fold-hidden')) {
          child.classList.remove('section-fold-hidden');
          child.removeAttribute('aria-hidden');
        }
      });

      [node].concat(Array.prototype.slice.call(node.querySelectorAll(
          '.section-heading-foldable, .section-heading-folded',
      ))).forEach(function(child) {
        child.classList.remove('section-heading-foldable');
        child.classList.remove('section-heading-folded');
      });

      Array.prototype.slice.call(
          node.querySelectorAll('[id], [for]'),
      ).forEach(function(child) {
        child.removeAttribute('id');
        child.removeAttribute('for');
      });

      node.removeAttribute('id');
      node.removeAttribute('for');
    }

    function positionPreview(link) {
      const gap = 10;
      const margin = 12;
      let left;
      let top;

      if (!preview || preview.hidden) {
        return;
      }

      const rect = link.getBoundingClientRect();
      left = rect.left + (rect.width / 2) - (preview.offsetWidth / 2);
      left = Math.max(margin, Math.min(left, window.innerWidth - preview.offsetWidth - margin));
      top = rect.bottom + gap;

      if (top + preview.offsetHeight > window.innerHeight - margin) {
        top = rect.top - preview.offsetHeight - gap;
      }

      top = Math.max(margin, Math.min(top, window.innerHeight - preview.offsetHeight - margin));

      preview.style.left = Math.round(left) + 'px';
      preview.style.top = Math.round(top) + 'px';
    }

    function syncPosition() {
      if (!activeLink || !previewTarget(activeLink)) {
        hide();
        return;
      }

      positionPreview(activeLink);
    }

    function handleKeydown(event) {
      if (event.key === 'Escape') {
        hide();
      }
    }

    function isPointerOrFocusInside() {
      const focused = document.activeElement;

      return Boolean(
          activeLink && activeLink.matches(':hover, :focus') ||
              preview && (
                preview.matches(':hover') ||
                  preview.contains(focused)
              ),
      );
    }

    return function teardown() {
      hide();

      linkListeners.forEach(function(entry) {
        entry.link.removeEventListener('pointerenter', entry.show);
        entry.link.removeEventListener('pointerleave', scheduleHide);
        entry.link.removeEventListener('focusin', entry.show);
        entry.link.removeEventListener('focusout', scheduleHide);
      });
      linkListeners = [];

      if (preview && preview.parentNode) {
        preview.parentNode.removeChild(preview);
      }
    };
  }

  function enhance(options) {
    const teardowns = window.__pandocmd.teardowns || [];
    const retainedLineBreaking = [];
    let preserveLineBreaking = Boolean(
        options && options.preserveLineBreaking,
    );
    let refresh = Promise.resolve();

    while (teardowns.length) {
      const teardown = teardowns.pop();

      if (preserveLineBreaking && teardown.pandocmdLineBreaking) {
        retainedLineBreaking.push(teardown);
        continue;
      }

      try {
        teardown();
      } catch (error) {
        /* ignore teardown failures */
      }
    }

    teardowns.push(initKatex());
    if (preserveLineBreaking && retainedLineBreaking.length) {
      teardowns.push(retainedLineBreaking[0]);
    } else {
      teardowns.push(initLineBreaking());
      preserveLineBreaking = false;
    }
    teardowns.push(initFolding());
    teardowns.push(initXref());
    window.__pandocmd.teardowns = teardowns;

    if (
      preserveLineBreaking &&
          window.__pandocmd.lineBreaking &&
          typeof window.__pandocmd.lineBreaking.refresh === 'function'
    ) {
      refresh = window.__pandocmd.lineBreaking.refresh(
          document.querySelector('.text-space section.body') || document,
      );
    }
    return refresh;
  }

  // Live reload swaps only the article/toc content in place instead of a
  // full navigation, so cached runtime assets stay loaded. Stylesheets are
  // reconciled before the content commit, and stable viewport/focus anchors
  // keep the visible document in place while enhancers process changed markup.
  function fingerprintMatches(parsed, name) {
    const current = document.querySelector('meta[name="' + name + '"]');
    const next = parsed.querySelector('meta[name="' + name + '"]');

    return Boolean(current && next && current.content === next.content);
  }

  function stylesheetLinks(root) {
    return Array.prototype.slice.call(
        root.querySelectorAll(
            'head link[rel~="stylesheet"]:not([data-pandocmd-staged])',
        ),
    );
  }

  function stylesheetKey(stylesheet) {
    let href;

    try {
      href = new URL(
          stylesheet.getAttribute('href') || '', window.location.href,
      ).href;
    } catch (error) {
      href = stylesheet.getAttribute('href') || '';
    }

    return [
      href,
      stylesheet.getAttribute('media') || '',
      stylesheet.getAttribute('title') || '',
      stylesheet.getAttribute('integrity') || '',
      stylesheet.getAttribute('crossorigin') || '',
      stylesheet.getAttribute('referrerpolicy') || '',
    ].join('\u0000');
  }

  function removeNode(node) {
    if (node && node.parentNode) {
      node.parentNode.removeChild(node);
    }
  }

  function reconcileStylesheets(parsed, reloadGeneration) {
    const current = stylesheetLinks(document);
    const next = stylesheetLinks(parsed);
    const currentKeys = current.map(stylesheetKey);
    const nextKeys = next.map(stylesheetKey);
    const unchanged = currentKeys.length === nextKeys.length &&
      currentKeys.every(function(key, index) {
        return key === nextKeys[index];
      });

    if (unchanged) {
      return Promise.resolve(true);
    }

    const available = Object.create(null);
    const planned = [];
    const staged = [];
    const loads = [];

    current.forEach(function(stylesheet, index) {
      const key = currentKeys[index];
      available[key] = available[key] || [];
      available[key].push(stylesheet);
    });

    next.forEach(function(stylesheet, index) {
      const matches = available[nextKeys[index]];
      const retained = matches && matches.shift();

      if (retained) {
        planned.push({
          link: retained,
          media: retained.getAttribute('media'),
          staged: false,
        });
        return;
      }

      const replacement = document.importNode(stylesheet, true);
      const media = replacement.getAttribute('media');
      const loaded = new Promise(function(resolve, reject) {
        replacement.addEventListener('load', resolve, {once: true});
        replacement.addEventListener('error', function() {
          reject(new Error('live reload stylesheet failed: ' +
            replacement.href));
        }, {once: true});
      });

      replacement.setAttribute('data-pandocmd-staged', '');
      replacement.setAttribute('media', 'not all');
      document.head.appendChild(replacement);
      staged.push(replacement);
      loads.push(loaded);
      planned.push({link: replacement, media: media, staged: true});
    });

    return Promise.all(loads).then(function() {
      if (reloadGeneration !== softReloadGeneration) {
        staged.forEach(removeNode);
        return false;
      }

      const marker = document.createComment('pandocmd-stylesheets');
      const first = current[0] || null;
      document.head.insertBefore(marker, first);

      planned.forEach(function(entry) {
        if (entry.staged) {
          entry.link.removeAttribute('data-pandocmd-staged');
          if (entry.media === null) {
            entry.link.removeAttribute('media');
          } else {
            entry.link.setAttribute('media', entry.media);
          }
        }
        document.head.insertBefore(entry.link, marker);
      });

      current.forEach(function(stylesheet) {
        if (!planned.some(function(entry) {
          return entry.link === stylesheet;
        })) {
          removeNode(stylesheet);
        }
      });
      removeNode(marker);
      return true;
    }).catch(function(error) {
      staged.forEach(removeNode);
      throw error;
    });
  }

  function closestViewportAnchor(layout) {
    const textSpace = layout.querySelector('.text-space') || layout;
    const rect = textSpace.getBoundingClientRect();
    const x = Math.max(1, Math.min(
        window.innerWidth - 1,
        rect.left + Math.min(rect.width / 2, 400),
    ));
    const ys = [
      Math.max(1, Math.min(window.innerHeight - 1, window.innerHeight / 3)),
      Math.max(1, Math.min(window.innerHeight - 1, window.innerHeight / 2)),
      80,
    ];
    const selector = [
      '[data-pandocmd-kp-status]', 'p', 'li', 'dt', 'dd', 'blockquote',
      'td', 'th', 'caption', '.theorem-environment', '.proof', '.sidenote',
      'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'figure', 'table',
      '[data-source-line]',
    ].join(', ');
    let anchor = null;

    ys.some(function(y) {
      const hit = document.elementFromPoint(x, y);
      anchor = hit && hit.closest(selector);
      if (anchor && layout.contains(anchor)) {
        return true;
      }
      anchor = null;
      return false;
    });
    return anchor;
  }

  function identityFor(node) {
    if (!node) {
      return null;
    }
    if (node.id) {
      return {id: node.id};
    }

    const annotated = node.closest('[data-source-line]');
    if (annotated) {
      return {sourceLine: annotated.getAttribute('data-source-line')};
    }
    return null;
  }

  function resolveIdentity(node, identity) {
    let match;

    if (node && node.isConnected) {
      return node;
    }
    if (!identity) {
      return null;
    }
    if (identity.id) {
      return document.getElementById(identity.id);
    }
    if (identity.sourceLine && /^\d+$/.test(identity.sourceLine)) {
      match = document.querySelector(
          '[data-source-line="' + identity.sourceLine + '"]',
      );
      return match;
    }
    return null;
  }

  function captureViewState(layout) {
    const active = document.activeElement;
    const anchor = closestViewportAnchor(layout);
    const state = {
      active: layout.contains(active) ? active : null,
      activeIdentity: layout.contains(active) ? identityFor(active) : null,
      anchor: anchor,
      anchorIdentity: identityFor(anchor),
      anchorTop: anchor ? anchor.getBoundingClientRect().top : null,
      scrollLeft: window.scrollX,
      scrollTop: window.scrollY,
      cancelled: false,
    };

    state.cancel = function() {
      state.cancelled = true;
    };
    window.addEventListener('wheel', state.cancel, {passive: true});
    window.addEventListener('touchmove', state.cancel, {passive: true});
    return state;
  }

  function restoreFocus(state) {
    const active = resolveIdentity(state.active, state.activeIdentity);

    if (!active || typeof active.focus !== 'function') {
      return;
    }
    try {
      active.focus({preventScroll: true});
    } catch (error) {
      active.focus();
    }
  }

  function restoreViewport(state) {
    let top;

    if (state.cancelled) {
      return;
    }

    const anchor = resolveIdentity(state.anchor, state.anchorIdentity);
    if (anchor && state.anchorTop !== null) {
      top = window.scrollY +
        anchor.getBoundingClientRect().top - state.anchorTop;
      window.scrollTo({
        left: state.scrollLeft,
        top: top,
        behavior: 'instant',
      });
      return;
    }

    window.scrollTo({
      left: state.scrollLeft,
      top: state.scrollTop,
      behavior: 'instant',
    });
  }

  function releaseViewState(state) {
    window.removeEventListener('wheel', state.cancel);
    window.removeEventListener('touchmove', state.cancel);
  }

  function softReload() {
    const reloadGeneration = softReloadGeneration + 1;
    const fetchOptions = {cache: 'no-store'};
    let viewState = null;

    softReloadGeneration = reloadGeneration;
    if (softReloadAbort) {
      softReloadAbort.abort();
    }
    if (typeof window.AbortController === 'function') {
      softReloadAbort = new AbortController();
      fetchOptions.signal = softReloadAbort.signal;
    }

    return fetch(window.location.href, fetchOptions)
        .then(function(response) {
          if (!response.ok) {
            throw new Error('live reload fetch failed: ' + response.status);
          }
          return response.text();
        })
        .then(function(html) {
          const parsed = new DOMParser().parseFromString(html, 'text/html');
          const next = parsed.querySelector('.page-layout');
          const current = document.querySelector('.page-layout');

          if (reloadGeneration !== softReloadGeneration) {
            return false;
          }
          if (!next || !current) {
            throw new Error('live reload could not find .page-layout');
          }
          if (
            !fingerprintMatches(parsed, 'pandocmd-page-fingerprint') ||
            !fingerprintMatches(
                parsed, 'pandocmd-line-breaking-fingerprint',
            )
          ) {
            window.location.reload();
            return false;
          }

          viewState = captureViewState(current);
          return reconcileStylesheets(parsed, reloadGeneration).then(
              function(reconciled) {
                const controller = window.__pandocmd.lineBreaking;
                const nextBody = next.querySelector(
                    '.text-space section.body',
                );
                const preserveLineBreaking = Boolean(
                    controller &&
                    nextBody &&
                    typeof controller.adoptUnchanged === 'function',
                );
                if (
                  !reconciled ||
                  reloadGeneration !== softReloadGeneration
                ) {
                  releaseViewState(viewState);
                  viewState = null;
                  return false;
                }

                // Reapplying the anchor after the atomic stylesheet switch
                // prevents new metrics from visibly moving the old content.
                restoreViewport(viewState);
                document.title = parsed.title;
                if (preserveLineBreaking) {
                  controller.adoptUnchanged(nextBody);
                }
                // Keep support for browsers without variadic replaceChildren.
                // eslint-disable-next-line prefer-spread
                current.replaceChildren.apply(
                    current,
                    Array.prototype.slice.call(next.childNodes),
                );
                const refresh = enhance({
                  preserveLineBreaking: preserveLineBreaking,
                });
                restoreFocus(viewState);
                restoreViewport(viewState);

                return Promise.resolve(refresh).then(function() {
                  if (reloadGeneration === softReloadGeneration) {
                    restoreViewport(viewState);
                  }
                  releaseViewState(viewState);
                  viewState = null;
                  return true;
                });
              },
          );
        })
        .catch(function(error) {
          if (viewState) {
            releaseViewState(viewState);
            viewState = null;
          }
          if (error && error.name === 'AbortError') {
            return false;
          }
          window.location.reload();
          return false;
        });
  }

  function reloadPathMatches(path) {
    let requested;

    if (!path) {
      return false;
    }
    try {
      requested = new URL(path, window.location.href);
    } catch (error) {
      return false;
    }
    return requested.pathname === window.location.pathname;
  }

  function connectLiveReload() {
    const endpointMeta = document.querySelector(
        'meta[name="pandocmd-live-reload-url"]',
    );
    const endpoint = endpointMeta && endpointMeta.content;
    const retryDelay = 1000;

    if (!endpoint || !('WebSocket' in window)) {
      return;
    }

    function socketUrl() {
      if (/^wss?:\/\//.test(endpoint)) {
        return endpoint;
      }
      return (window.location.protocol === 'https:' ? 'wss://' : 'ws://') +
        window.location.host + endpoint;
    }

    function connect() {
      let socket;

      try {
        socket = new WebSocket(socketUrl());
      } catch (error) {
        retry();
        return;
      }

      socket.addEventListener('open', function() {
        socket.send(JSON.stringify({
          command: 'hello',
          protocols: ['http://livereload.com/protocols/official-7'],
          path: window.location.pathname,
        }));
      });

      socket.addEventListener('message', function(event) {
        let message;

        try {
          message = JSON.parse(event.data);
        } catch (error) {
          return;
        }

        if (message.command !== 'reload' ||
            !reloadPathMatches(message.path)) {
          return;
        }
        if (typeof window.__pandocmd.softReload === 'function') {
          window.__pandocmd.softReload();
        } else {
          window.location.reload();
        }
      });

      socket.addEventListener('close', retry);
    }

    function retry() {
      window.setTimeout(connect, retryDelay);
    }

    connect();
  }

  window.__pandocmd.enhance = enhance;
  window.__pandocmd.softReload = softReload;
  window.__pandocmd.reloadPathMatches = reloadPathMatches;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', enhance);
  } else {
    enhance();
  }
  connectLiveReload();
}());
