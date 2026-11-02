// The notebook page's behaviour (NotebookRenderer, S-21): maths in Markdown cells and LaTeX outputs, code blocks
// in Markdown cells made into cards for fences.js to colour, remote images turned into quiet chips, the Code only
// mode, find, scroll reports, and the live-reload and reveal hooks. Loaded from vitrine://app/ so the page's
// Content-Security-Policy can refuse every inline script, including any a notebook carries. roadmap: S-21
(function () {
  var main = document.getElementById('nb');
  var post = function (name, body) { try { window.webkit.messageHandlers.vitrine.postMessage({ name: name, body: body }); } catch (e) {} };
  window.addEventListener('error', function (e) { post('error', String((e && e.message) || e)); });
  // The page's words (H-6): Swift's localized strings in the #vt-strings data block, English when absent.
  var strings = {};
  try { strings = JSON.parse((document.getElementById('vt-strings') || {}).textContent || '{}') || {}; } catch (e) {}
  var t = function (key, fallback, args) {
    var v = strings[key], s = typeof v === 'string' ? v : fallback;
    return args ? s.replace(/\{(\w+)\}/g, function (m, k) { return k in args ? String(args[k]) : m; }) : s;
  };

  function renderMath(root) {
    if (!window.katex) return;
    root.querySelectorAll('.math').forEach(function (el) {
      if (el.dataset.rendered) return;
      try { katex.render(el.textContent, el, { displayMode: el.classList.contains('math-display'), throwOnError: false }); el.dataset.rendered = '1'; }
      catch (e) { el.classList.add('math-error'); }
    });
  }

  // Fenced code in Markdown cells: the same card as a code cell's source, so fences.js colours it too.
  function decorateCode(root) {
    root.querySelectorAll('.nbmd pre > code').forEach(function (code) {
      var pre = code.parentElement;
      if (pre.parentElement.classList.contains('cb')) return;
      var card = document.createElement('div'); card.className = 'cb';
      pre.replaceWith(card); card.appendChild(pre);
    });
  }

  // Images a cell names by web address are never loaded (the page cannot reach the network); each becomes a chip.
  // A relative image beside the notebook loads through vitrine://doc/, as in a Markdown file.
  function ghostRemoteImages(root) {
    root.querySelectorAll('img').forEach(function (img) {
      var src = img.getAttribute('src') || '';
      if (!/^(https?:)?\/\//i.test(src)) return;
      var host = ''; try { host = new URL(src, 'https://x/').host; } catch (e) {}
      var chip = document.createElement('span'); chip.className = 'rghost';
      chip.title = t('nb.notLoaded', '{host} — not loaded', { host: host || src });
      var b = document.createElement('b'); b.textContent = img.getAttribute('alt') || t('md.image', 'image');
      chip.append(b);
      if (host && host !== 'x') { var em = document.createElement('em'); em.textContent = host; chip.append(em); }
      img.replaceWith(chip);
    });
  }

  function decorate(root) {
    ghostRemoteImages(root); decorateCode(root); renderMath(root);
    if (window.vitrineFences) window.vitrineFences.colour(root).then(function (n) { if (n) post('fences', n); });
  }

  // Find (the capsule's field): every visible match marked in --v-find, the current one in --v-find-cur.
  var finds = [], findAt = -1, findQuery = '';
  function clearFind() {
    finds.forEach(function (m) { m.replaceWith(document.createTextNode(m.textContent)); });
    main.normalize(); finds = []; findAt = -1; findQuery = '';
  }
  function visible(el) { return el && el.getClientRects().length > 0; }
  function runFind(query) {
    clearFind(); findQuery = query;
    if (!query) return;
    var needle = query.toLocaleLowerCase();
    var walker = document.createTreeWalker(main, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        var p = n.parentElement;
        return !p || p.closest('script,style,.katex-mathml') || !visible(p) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });
    var nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(function (node) {
      var text = node.nodeValue, lower = text.toLocaleLowerCase(), i = lower.indexOf(needle);
      if (i < 0) return;
      var frag = document.createDocumentFragment(), last = 0;
      while (i >= 0) {
        frag.append(text.slice(last, i));
        var mark = document.createElement('mark'); mark.className = 'vt-find'; mark.textContent = text.slice(i, i + query.length);
        frag.append(mark); finds.push(mark);
        last = i + query.length; i = lower.indexOf(needle, last);
      }
      frag.append(text.slice(last)); node.replaceWith(frag);
    });
  }
  function stepFind(forward) {
    if (!finds.length) return;
    if (findAt >= 0) finds[findAt].classList.remove('cur');
    findAt = forward ? (findAt + 1) % finds.length : (findAt - 1 + finds.length) % finds.length;
    finds[findAt].classList.add('cur');
    finds[findAt].scrollIntoView({ block: 'center' });
  }

  var scrollTimer = null;
  window.addEventListener('scroll', function () { clearTimeout(scrollTimer); scrollTimer = setTimeout(function () { post('scroll', window.scrollY); }, 120); }, { passive: true });

  window.vitrineNotebook = {
    find: function (query, forward) {
      if (query !== findQuery) { runFind(query); findAt = -1; }
      stepFind(forward !== false);
      return { count: finds.length, index: findAt };
    },
    clearFind: function () { clearFind(); return true; },
    // "notebook" or "code" (the viewer switch's Code only: prose and outputs folded away).
    setMode: function (mode) {
      if (findQuery) clearFind();
      document.body.classList.toggle('code-only', mode === 'code');
      return mode;
    },
    replaceBody: function (html) {
      var y = window.scrollY;
      findQuery = ''; finds = []; findAt = -1;
      main.innerHTML = html; decorate(main);
      window.scrollTo(0, y);
    },
    reveal: function (y) {
      if (typeof y === 'number') window.scrollTo(0, y);
      main.classList.remove('veiled');
    }
  };
  decorate(main);
  post('ready', true);
})();
