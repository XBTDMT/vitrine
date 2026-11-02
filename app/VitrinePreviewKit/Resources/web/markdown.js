// The Markdown page's behaviour: maths, Mermaid diagrams, the outline and its resizer, scroll reports, and the
// live-reload and reveal hooks the renderer calls. Loaded from vitrine://app/ so the page's Content-Security-Policy
// can refuse every inline script, including any that a Markdown file smuggles in. roadmap: S-4
(function () {
  var page = document.getElementById('page');
  var article = document.getElementById('body');
  var post = function (name, body) { try { window.webkit.messageHandlers.vitrine.postMessage({ name: name, body: body }); } catch (e) {} };

  // The page's words (H-6): Swift's localized strings arrive in the #vt-strings data block (PageStrings.swift); each
  // lookup falls back to the English here. `{name}` is filled from args; a counted phrase picks its plural form.
  var strings = {};
  try { strings = JSON.parse((document.getElementById('vt-strings') || {}).textContent || '{}') || {}; } catch (e) {}
  var num = function (n) { return Number(n).toLocaleString(strings._locale || undefined); };
  var fill = function (s, args) { return args ? s.replace(/\{(\w+)\}/g, function (m, k) { return k in args ? String(args[k]) : m; }) : s; };
  var t = function (key, fallback, args) { var v = strings[key]; return fill(typeof v === 'string' ? v : fallback, args); };
  var tn = function (key, n, one, other, args) {
    var v = strings[key], s = null;
    if (v && typeof v === 'object') { try { s = v[new Intl.PluralRules(strings._lang || 'en').select(n)] || v.other; } catch (e) { s = v.other; } }
    if (typeof s !== 'string') s = n === 1 ? one : other;
    var all = { n: num(n) }; for (var k in args || {}) all[k] = args[k];
    return fill(s, all);
  };

  function renderMath(root) {
    if (!window.katex) return;
    root.querySelectorAll('.math').forEach(function (el) {
      if (el.dataset.rendered) return;
      var tex = el.textContent;
      try { katex.render(tex, el, { displayMode: el.classList.contains('math-display'), throwOnError: false }); el.dataset.rendered = '1'; }
      catch (e) { el.classList.add('math-error'); el.textContent = e.message; }
    });
  }

  // Mermaid (G-2 route C): fenced ```mermaid blocks become diagrams. The 5 MB script is fetched only when the page
  // has a diagram; colours come from the page's theme variables; securityLevel strict escapes labels and drops
  // click handlers. Timings go to the host as `mermaidTiming` (the measurement G-2 asks for before the cache).
  var mermaidLoad = null, diagramSeq = 0;
  function loadMermaid() {
    if (window.mermaid) return Promise.resolve();
    if (!mermaidLoad) mermaidLoad = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = 'vitrine://vendor/mermaid/mermaid.min.js'; s.onload = resolve; s.onerror = reject;
      document.head.appendChild(s);
    });
    return mermaidLoad;
  }
  function mermaidTheme() {
    var cs = getComputedStyle(document.documentElement), v = function (n) { return cs.getPropertyValue(n).trim(); };
    // Diagram colours (--dg-*): the theme's own, or its light or dark ones when the Diagrams setting fixes them.
    var d = function (n) { return v('--dg-' + n) || v('--' + n); };
    return { background: d('bg'), primaryColor: d('code'), primaryBorderColor: d('acc'),
      primaryTextColor: d('fg'), secondaryColor: d('code'), tertiaryColor: d('bg'),
      lineColor: d('fg2'), textColor: d('fg'), noteBkgColor: d('code'), noteTextColor: d('fg'),
      noteBorderColor: d('rule'), fontFamily: v('--font'), fontSize: '13px' };
  }
  function showSource(block, message) {
    block.classList.remove('pending'); block.classList.add('mermaid-error'); block.textContent = '';
    var title = document.createElement('div'); title.className = 'mermaid-error-title'; title.textContent = message;
    var pre = document.createElement('pre'); pre.textContent = block.dataset.source;
    block.append(title, pre);
  }
  function renderDiagrams(root) {
    var codes = root.querySelectorAll('pre > code.language-mermaid');
    if (!codes.length) return;
    var t0 = performance.now();
    codes.forEach(function (code) {
      var block = document.createElement('div'); block.className = 'mermaid-block pending';
      block.dataset.source = code.textContent;
      if (code.parentElement.dataset.mermaidKey) block.dataset.key = code.parentElement.dataset.mermaidKey;
      var wait = document.createElement('div'); wait.className = 'mermaid-wait'; wait.textContent = t('md.drawing', 'Drawing diagram…');
      block.replaceChildren(wait);
      code.parentElement.replaceWith(block);
    });
    var blocks = Array.prototype.slice.call(root.querySelectorAll('.mermaid-block.pending'));
    loadMermaid().then(function () {
      var loaded = performance.now(), first = null;
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'base', themeVariables: mermaidTheme() });
      var jobs = blocks.map(function (block) {
        // Ids stay unique when cached and fresh drawings share a page: mermaid scopes its styles by this id.
        var id = 'vt-mermaid-' + (block.dataset.key ? block.dataset.key.slice(0, 16) + '-' : '') + (++diagramSeq);
        return mermaid.render(id, block.dataset.source).then(function (r) {
          block.innerHTML = r.svg; block.classList.remove('pending');
          // The key is the one Swift issued for this source; Swift saves the drawing only when both match (S-16 F52).
          if (block.dataset.key) post('mermaidSVG', { key: block.dataset.key, source: block.dataset.source, svg: r.svg });
          if (first === null) first = performance.now();
        }).catch(function (e) {
          var stray = document.getElementById('d' + id); if (stray) stray.remove();
          showSource(block, t('md.diagramFailed', 'This diagram could not be drawn: {reason}', { reason: String((e && e.message) || e).split('\n')[0] }));
        });
      });
      return Promise.all(jobs).then(function () {
        post('mermaidTiming', { load: Math.round(loaded - t0), first: first === null ? -1 : Math.round(first - t0),
          total: Math.round(performance.now() - t0), count: blocks.length });
      });
    }).catch(function () {
      blocks.forEach(function (b) { showSource(b, t('md.diagramsUnavailable', 'Diagrams are unavailable: the diagram library did not load.')); });
      post('mermaidTiming', { load: -1, first: -1, total: Math.round(performance.now() - t0), count: blocks.length });
    });
  }

  // Code blocks become cards with their language at the top left (the design's .cb); mermaid fences are diagrams.
  // Each card has a Copy button (I-2, markdown r3-a), shown on hover: the page cannot reach the clipboard, so the
  // code goes to Swift, which puts it there; the button says Copied for a moment.
  var copyIcon = '<svg class="pi" width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5.3" y="5.3" width="8" height="8.5" rx="1.6"/><path d="M3 10.6V3.8A1.6 1.6 0 0 1 4.6 2.2h6.1"/></svg>';
  function copyButton(pre) {
    var button = document.createElement('button'); button.type = 'button'; button.className = 'copy';
    button.innerHTML = copyIcon;
    var label = document.createElement('span'); label.textContent = t('md.copy', 'Copy'); button.appendChild(label);
    var timer = null;
    button.addEventListener('click', function (event) {
      event.preventDefault(); event.stopPropagation();
      post('copyCode', pre.textContent);
      button.classList.add('on'); label.textContent = t('md.copied', 'Copied');
      clearTimeout(timer);
      timer = setTimeout(function () { button.classList.remove('on'); label.textContent = t('md.copy', 'Copy'); }, 1400);
    });
    return button;
  }
  function decorateCode(root) {
    root.querySelectorAll('pre > code').forEach(function (code) {
      var pre = code.parentElement;
      if (code.classList.contains('language-mermaid') || pre.parentElement.classList.contains('cb')) return;
      var lang = (code.className.match(/language-([\w+#.-]+)/) || [])[1];
      var card = document.createElement('div'); card.className = 'cb' + (lang ? ' has-lang' : '');
      pre.replaceWith(card); card.appendChild(pre);
      if (lang) { var tag = document.createElement('span'); tag.className = 'lang'; tag.textContent = lang; card.prepend(tag); }
      card.appendChild(copyButton(pre));
    });
  }

  // Remote images are never loaded (G-9: the page cannot reach the network); each becomes a chip naming its host.
  var remoteIcon = '<svg class="pi" width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2" y="3" width="12" height="10" rx="1.8"/><circle cx="5.6" cy="6.4" r="1.1"/><path d="M2.4 11.8 6 8.4l2.6 2.5 1.9-1.8 3.1 2.8"/></svg>';
  function ghostRemoteImages(root) {
    var chips = [], hosts = {};
    root.querySelectorAll('img').forEach(function (img) {
      var src = img.getAttribute('src') || '';
      if (!/^(https?:)?\/\//i.test(src)) return;
      var host = ''; try { host = new URL(src, 'https://x/').host; } catch (e) {}
      var chip = document.createElement('span'); chip.className = 'rghost'; chip.dataset.src = src;
      chip.dataset.alt = img.getAttribute('alt') || ''; chip.dataset.host = host; chips.push(chip); hosts[host] = true;
      chip.title = t('md.remoteNotLoaded', '{host} — remote, not loaded', { host: host });
      chip.innerHTML = remoteIcon;
      var b = document.createElement('b'); b.textContent = img.getAttribute('alt') || t('md.image', 'image');
      var em = document.createElement('em'); em.textContent = host;
      chip.append(b, em);
      img.replaceWith(chip);
    });
    if (chips.length) remoteBar(root, chips.length, Object.keys(hosts));
  }

  // G-10 B: the quiet bar above the page; "Load once" asks the host, which fetches only the images the file names.
  function remoteBar(root, count, hosts) {
    var bar = document.createElement('div'); bar.className = 'banner info remote-bar'; bar.setAttribute('role', 'status');
    bar.innerHTML = remoteIcon;
    var text = document.createElement('span');
    var b = document.createElement('b'); b.textContent = tn('md.imagesNotLoaded', count, '{n} image is not loaded', '{n} images are not loaded');
    var hostList = hosts.join(', ');
    try { hostList = new Intl.ListFormat(strings._lang || 'en', { style: 'narrow', type: 'conjunction' }).format(hosts); } catch (e) {}
    text.append(b, document.createTextNode(' · ' + hostList));
    var sp = document.createElement('span'); sp.className = 'sp';
    var btn = document.createElement('button'); btn.className = 'btn sm'; btn.textContent = t('md.loadOnce', 'Load once');
    btn.title = t('md.loadOnceHelp', 'Fetch these images once, for this file only');
    btn.addEventListener('click', function () { btn.disabled = true; btn.textContent = t('md.loading', 'Loading…'); post('loadRemote', true); });
    bar.append(text, sp, btn);
    root.prepend(bar);
  }

  // The column: active heading in the accent tint; its edge resizes it and remembers the width.
  var side = document.querySelector('.sa-side');
  if (side) {
    page.classList.add('has-toc');
    var edge = side.querySelector('.sa-edge');
    var dragging = false;
    edge.addEventListener('mousedown', function (e) { dragging = true; edge.classList.add('dragging'); e.preventDefault(); });
    window.addEventListener('mousemove', function (e) { if (!dragging) return; var w = Math.max(160, Math.min(360, e.clientX)); document.documentElement.style.setProperty('--toc-width', w + 'px'); });
    // The width sent is a whole number the page clamped itself; a document's stylesheet can make the CSS variable
    // say anything, so an unreadable one sends nothing (Swift checks again, S-16 F53).
    window.addEventListener('mouseup', function () {
      if (!dragging) return; dragging = false; edge.classList.remove('dragging');
      var w = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--toc-width'), 10);
      if (isFinite(w)) post('tocWidth', Math.max(160, Math.min(360, w)));
    });
    var items = Array.prototype.slice.call(side.querySelectorAll('.toc li'));
    function markActive() {
      var y = window.scrollY + 8, active = items[0] || null;
      items.forEach(function (li) { var a = li.querySelector('a'); var h = document.getElementById(decodeURIComponent(a.getAttribute('href').slice(1))); if (h && h.offsetTop <= y) active = li; });
      items.forEach(function (li) { li.classList.toggle('on', li === active); });
    }
    window.addEventListener('scroll', markActive, { passive: true }); markActive();
  }

  // "Aa" (markdown 8): the Collection as tiles in each theme's own colours, and the text size. Choices go to the
  // host, which saves them and redraws the page; ⌘+ ⌘− ⌘0 change the size from anywhere on the page.
  var themeData = null;
  try { themeData = JSON.parse((document.getElementById('vt-themes') || {}).textContent || 'null'); } catch (e) {}
  var aaButton = document.getElementById('vt-aa'), aaPop = null;
  function closeAa() { if (aaPop) { aaPop.remove(); aaPop = null; aaButton.classList.remove('on'); aaButton.setAttribute('aria-expanded', 'false'); } }
  function openAa() {
    if (!themeData || aaPop) return;
    aaPop = document.createElement('div'); aaPop.className = 'aa-pop'; aaPop.setAttribute('role', 'dialog');
    aaPop.setAttribute('aria-label', t('md.themeAndSize', 'Theme and text size'));
    var head = document.createElement('div'); head.className = 'mh'; head.textContent = t('md.theme', 'Theme');
    var grid = document.createElement('div'); grid.className = 'aa-grid';
    themeData.themes.forEach(function (t) {
      var tile = document.createElement('button'); tile.className = 'tt' + (t.id === themeData.current ? ' on' : '');
      tile.title = t.name; tile.setAttribute('aria-pressed', t.id === themeData.current ? 'true' : 'false');
      var sw = document.createElement('div'); sw.className = 'tt-p'; sw.style.background = t.bg; sw.style.color = t.fg;
      var b = document.createElement('b'); b.textContent = 'Aa'; b.style.fontFamily = t.hfont; b.style.fontWeight = t.hw;
      var l1 = document.createElement('i'); l1.style.background = t.fg2;
      var l2 = document.createElement('i'); l2.className = 's'; l2.style.background = t.acc;
      sw.append(b, l1, l2);
      var name = document.createElement('span'); name.textContent = t.name;
      tile.append(sw, name);
      tile.addEventListener('click', function () { post('setTheme', t.id); closeAa(); });
      grid.append(tile);
    });
    var sep = document.createElement('div'); sep.className = 'msep';
    var size = document.createElement('div'); size.className = 'aa-size';
    var label = document.createElement('span'); label.textContent = t('md.textSize', 'Text size');
    var spacer = document.createElement('span'); spacer.className = 'sp';
    var minus = document.createElement('button'); minus.className = 'ib'; minus.textContent = '−'; minus.title = t('md.smallerKey', 'Smaller (⌘−)');
    minus.setAttribute('aria-label', t('md.smaller', 'Smaller'));
    var val = document.createElement('span'); val.className = 'val';
    val.textContent = Number(themeData.scale).toLocaleString(strings._locale || undefined, { style: 'percent', maximumFractionDigits: 0 });
    var plus = document.createElement('button'); plus.className = 'ib'; plus.textContent = '+'; plus.title = t('md.largerKey', 'Larger (⌘+)');
    plus.setAttribute('aria-label', t('md.larger', 'Larger'));
    var keys = document.createElement('span'); keys.className = 'sc'; keys.textContent = '⌘+ ⌘−';
    minus.disabled = themeData.scale <= themeData.scales[0]; plus.disabled = themeData.scale >= themeData.scales[themeData.scales.length - 1];
    minus.addEventListener('click', function () { post('textScale', -1); });
    plus.addEventListener('click', function () { post('textScale', 1); });
    size.append(label, spacer, minus, val, plus, keys);
    aaPop.append(head, grid, sep, size);
    document.body.append(aaPop);
    var r = aaButton.getBoundingClientRect();
    aaPop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 352)) + 'px';
    aaPop.style.top = (r.bottom + 6) + 'px';
    aaButton.classList.add('on'); aaButton.setAttribute('aria-expanded', 'true');
    var on = aaPop.querySelector('.tt.on'); if (on) on.focus();
  }
  if (aaButton) aaButton.addEventListener('click', function (e) { e.stopPropagation(); aaPop ? closeAa() : openAa(); });
  document.addEventListener('mousedown', function (e) { if (aaPop && !aaPop.contains(e.target) && e.target !== aaButton) closeAa(); });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') closeAa();
    if (!e.metaKey) return;
    if (e.key === '=' || e.key === '+') { post('textScale', 1); e.preventDefault(); }
    else if (e.key === '-') { post('textScale', -1); e.preventDefault(); }
    else if (e.key === '0') { post('textScale', 0); e.preventDefault(); }
  });

  var scrollTimer = null;
  window.addEventListener('scroll', function () { clearTimeout(scrollTimer); scrollTimer = setTimeout(function () { post('scroll', window.scrollY); }, 120); }, { passive: true });

  // Code blocks are coloured by the code view's Shiki (fences.js, a module that may load after this script).
  function decorate(root) {
    ghostRemoteImages(root); decorateCode(root); renderMath(root); renderDiagrams(root);
    if (window.vitrineFences) window.vitrineFences.colour(root);
  }

  // Find (the capsule's field): every match marked in --v-find, the current one in --v-find-cur and scrolled to.
  // Only text nodes in the article are searched; code, maths and diagram labels count as text a reader sees.
  var finds = [], findAt = -1, findQuery = '';
  function clearFind() {
    finds.forEach(function (m) { var t = document.createTextNode(m.textContent); m.replaceWith(t); });
    article.normalize(); finds = []; findAt = -1; findQuery = '';
  }
  function runFind(query) {
    clearFind(); findQuery = query;
    if (!query) return;
    var needle = query.toLocaleLowerCase(), walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) { return n.parentElement.closest('script,style,svg .katex-mathml') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT; }
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
    drawRuler();
  }

  // The shared ruler (C-8, B-7): the page's scrollbar, 12 pt at the right, with the find matches marked where they
  // sit in the whole document (the current one stronger) and a thumb for what is in view; drag it or click to move.
  var ruler = document.createElement('div'), rulerMarks = document.createElement('div'), rulerThumb = document.createElement('div');
  ruler.className = 'vt-ruler'; rulerThumb.className = 'thumb';
  ruler.append(rulerMarks, rulerThumb);
  document.body.appendChild(ruler);
  function placeThumb() {
    var h = document.documentElement.scrollHeight || 1, view = window.innerHeight;
    rulerThumb.style.top = (window.scrollY / h * 100) + '%';
    rulerThumb.style.height = Math.min(100, view / h * 100) + '%';
    rulerThumb.hidden = view >= h;
  }
  function drawRuler() {
    var h = document.documentElement.scrollHeight || 1, html = '', last = -1;
    finds.forEach(function (m, i) {
      var top = m.getBoundingClientRect().top + window.scrollY, at = (top / h * 100).toFixed(2);
      if (i !== findAt && at === last) return;
      last = at;
      html += '<i class="' + (i === findAt ? 'fc' : 'f') + '" style="top:' + at + '%"></i>';
    });
    rulerMarks.innerHTML = html;
    placeThumb();
  }
  ruler.addEventListener('mousedown', function (e) {
    e.preventDefault();
    var tr = rulerThumb.getBoundingClientRect();
    var grab = e.clientY >= tr.top && e.clientY <= tr.bottom ? e.clientY - tr.top : tr.height / 2;
    var seek = function (ev) {
      var r = ruler.getBoundingClientRect();
      window.scrollTo(0, Math.max(0, Math.min(1, (ev.clientY - r.top - grab) / r.height)) * document.documentElement.scrollHeight);
    };
    seek(e);
    var up = function () { removeEventListener('mousemove', seek); removeEventListener('mouseup', up); };
    addEventListener('mousemove', seek); addEventListener('mouseup', up);
  });
  window.addEventListener('scroll', placeThumb, { passive: true });
  window.addEventListener('resize', drawRuler);
  setTimeout(drawRuler, 0);

  window.vitrine = {
    showRemote: function (map, asked) {
      var loaded = 0;
      document.querySelectorAll('.rghost[data-src]').forEach(function (chip) {
        var local = map[chip.dataset.src];
        if (!local) { chip.title = t('md.remoteFailed', '{host} — remote, could not be loaded', { host: chip.dataset.host || '' }); return; }
        var img = document.createElement('img'); img.src = local; img.alt = chip.dataset.alt; chip.replaceWith(img); loaded++;
      });
      var bar = document.querySelector('.remote-bar');
      if (bar) {
        var failed = document.querySelectorAll('.rghost[data-src]').length;
        if (!failed) { bar.remove(); }
        else { bar.querySelector('b').textContent = tn('md.imagesFailed', failed, '{n} image could not be loaded', '{n} images could not be loaded');
               var btn = bar.querySelector('button'); if (btn) btn.remove(); }
      }
      return loaded;
    },
    find: function (query, forward) {
      if (query !== findQuery) { runFind(query); findAt = -1; }
      stepFind(forward !== false);
      drawRuler();
      return { count: finds.length, index: findAt };
    },
    clearFind: function () { clearFind(); drawRuler(); return true; },
    rulerMarks: function () { drawRuler(); return Array.prototype.map.call(document.querySelectorAll('.vt-ruler i'), function (i) { return i.className; }); },
    toggleColumn: function () { page.classList.toggle('column-hidden'); },
    replaceBody: function (html) {
      var y = window.scrollY;
      findQuery = ''; finds = []; findAt = -1;
      article.innerHTML = html; decorate(article);
      window.scrollTo(0, y);
      drawRuler();
    },
    reveal: function (y) {
      if (typeof y === 'number') window.scrollTo(0, y);
      article.classList.remove('veiled');
    }
  };
  decorate(article);
})();
