// The diff page (S-7, G-16; diff design r3-b Summary sibling): the lead with its state dot, the Checks group, the
// "what changed" list that follows the detail, and every file's hunks — sticky headers, folds, unified or split rows,
// intra-line marks — coloured by the code view's Shiki in the unified palette. Swift sends each file's rows when it
// scrolls near (window.vitrineDiff.setRows). Bundled as the code bundle's third entry, vitrine://app/code/diff.js.
// roadmap: S-7
import { createHighlighterCore } from 'shiki/core';
import { createOnigurumaEngine } from 'shiki/engine/oniguruma';
import { bundledLanguages } from 'shiki/langs';
import { INITIAL, EncodedTokenMetadata } from '@shikijs/vscode-textmate';
import { loadTheme } from './appearance.js';
import { t, tn, num, percent } from './strings.js';

const post = (type, extra) => window.webkit?.messageHandlers?.vitrine?.postMessage({ type, ...extra });
const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const fmt = num;
const withoutMatch = (n) => tn('diff.linesWithoutMatch', n, '{n} line without a match', '{n} lines without a match');

const model = JSON.parse(document.getElementById('vt-model').textContent);
const rows = new Map(JSON.parse(document.getElementById('vt-rows').textContent).map((r) => [r.index, r]));
let mode = 'unified';
let highlighter = null, themeName = null;
const colours = new Map(); // file index → { old: Map(row → tokens), new: Map(row → tokens) }
const find = { query: '', matches: [], index: -1, fold: false };

// MARK: Shiki

async function ensureHighlighter() {
  if (highlighter) return highlighter;
  const theme = await loadTheme('vitrine', []);
  themeName = theme.name;
  highlighter = await createHighlighterCore({ themes: [theme], langs: [], engine: createOnigurumaEngine(import('shiki/wasm')) });
  return highlighter;
}

// Tokens for each side of a file, carrying the grammar state line to line within a hunk (old side: context and
// deleted lines; new side: context and added lines); a fold starts a fresh state.
async function colourFile(index) {
  const file = model.files[index], data = rows.get(index);
  if (!file || !file.lang || !data || colours.has(index) || !bundledLanguages[file.lang]) return;
  try {
    const h = await ensureHighlighter();
    if (!h.getLoadedLanguages().includes(file.lang)) await h.loadLanguage(bundledLanguages[file.lang]);
    const grammar = h.getLanguage(file.lang);
    const { colorMap } = h.setTheme(themeName);
    const result = { old: new Map(), new: new Map() };
    let oldState = INITIAL, newState = INITIAL;
    const tokens = (text, state) => {
      const r = grammar.tokenizeLine2(text.length > 4000 ? text.slice(0, 4000) : text, state, 200);
      const out = [];
      for (let j = 0; j < r.tokens.length; j += 2) {
        const start = r.tokens[j], end = j + 2 < r.tokens.length ? r.tokens[j + 2] : text.length, md = r.tokens[j + 1];
        out.push([start, end, colorMap[EncodedTokenMetadata.getForeground(md)], EncodedTokenMetadata.getFontStyle(md)]);
      }
      return { out, state: r.ruleStack };
    };
    data.unified.forEach((row, i) => {
      if (row.t === 'fold') { oldState = INITIAL; newState = INITIAL; return; }
      if (row.k !== 'a') { const t = tokens(row.s, oldState); oldState = t.state; result.old.set(i, t.out); }
      if (row.k !== 'd') { const t = tokens(row.s, newState); newState = t.state; result.new.set(i, t.out); }
    });
    colours.set(index, result);
    drawFile(index);
  } catch (e) { post('error', { message: 'colours for ' + file.name + ': ' + (e && e.message || e) }); }
}

// MARK: Drawing a line

// The line's HTML: Shiki's colours, intra-line marks and find marks over the same text.
function code(text, toks, highlights, hiClass, findMarks) {
  const cuts = new Set([0, text.length]);
  (toks || []).forEach(([s, e]) => { cuts.add(Math.min(s, text.length)); cuts.add(Math.min(e, text.length)); });
  (highlights || []).forEach(([s, e]) => { cuts.add(s); cuts.add(e); });
  (findMarks || []).forEach(([s, e]) => { cuts.add(s); cuts.add(e); });
  const points = [...cuts].filter((p) => p >= 0 && p <= text.length).sort((a, b) => a - b);
  let html = '';
  for (let i = 0; i + 1 < points.length; i++) {
    const a = points[i], b = points[i + 1];
    if (b <= a) continue;
    let piece = esc(text.slice(a, b));
    const tok = (toks || []).find(([s, e]) => s <= a && b <= e);
    if (tok && tok[2]) piece = '<span style="color:' + tok[2] + (tok[3] & 1 ? ';font-style:italic' : '') + (tok[3] & 2 ? ';font-weight:600' : '') + '">' + piece + '</span>';
    if ((highlights || []).some(([s, e]) => s <= a && b <= e)) piece = '<mark class="' + hiClass + '">' + piece + '</mark>';
    const f = (findMarks || []).find(([s, e]) => s <= a && b <= e);
    if (f) piece = '<mark class="find' + (f[2] ? ' cur' : '') + '" data-m="' + f[3] + '">' + piece + '</mark>';
    html += piece;
  }
  return html;
}

function findMarksFor(file, rowIndex) {
  if (!find.query) return null;
  const out = find.matches.map((m, i) => [m, i]).filter(([m]) => m.file === file && m.row === rowIndex);
  return out.length ? out.map(([m, i]) => [m.start, m.end, i === find.index, i]) : null;
}

// MARK: The file's table

function drawFile(index) {
  const host = document.querySelector('.d-file[data-i="' + index + '"] .d-body');
  const file = model.files[index], data = rows.get(index);
  if (!host) return;
  if (file.omitted) {
    host.replaceChildren(el('div', 'd-omit', t('diff.notKept', 'Lines not kept: this patch is past the detail limit. Counted above.')));
    return;
  }
  if (file.binary && (!data || !data.unified.length)) {
    host.replaceChildren(el('div', 'd-omit', t('diff.binaryFile', 'Binary file · {detail}', { detail: file.binary })));
    return;
  }
  if (!data) { host.style.minHeight = Math.max(60, (file.additions + file.deletions + 4) * 19) + 'px'; return; }
  host.style.minHeight = '';
  const c = colours.get(index);
  const keep = find.fold && find.query ? keptRows(index) : null;
  let html = '<table class="d-rows' + (mode === 'split' ? ' split' : '') + '">';
  if (mode === 'unified') {
    html += '<colgroup><col style="width:3.4em"><col style="width:3.4em"><col style="width:1.4em"><col></colgroup>';
    let hidden = 0;
    data.unified.forEach((row, i) => {
      if (keep && !keep.has(i)) { hidden++; return; }
      if (hidden) { html += '<tr class="d-nomatch"><td colspan="4">' + esc(withoutMatch(hidden)) + '</td></tr>'; hidden = 0; }
      if (row.t === 'fold') { html += '<tr class="fold"><td colspan="4">' + esc(row.label) + '</td></tr>'; return; }
      const toks = c ? (row.k === 'd' ? c.old.get(i) : c.new.get(i)) : null;
      const sign = row.k === 'a' ? '+' : row.k === 'd' ? '−' : '';
      html += '<tr class="' + row.k + '"><td class="n o">' + (row.o ?? '') + '</td><td class="n">' + (row.n ?? '') + '</td><td class="sg">' + sign + '</td><td>'
        + code(row.s, toks, row.h, row.k === 'd' ? 'hi-d' : 'hi-a', findMarksFor(index, i)) + '</td></tr>';
    });
    if (hidden) html += '<tr class="d-nomatch"><td colspan="4">' + esc(withoutMatch(hidden)) + '</td></tr>';
  } else {
    html += '<colgroup><col style="width:3.4em"><col style="width:50%"><col style="width:3.4em"><col style="width:50%"></colgroup>';
    data.split.forEach((row) => {
      if (row.t === 'fold') { html += '<tr class="fold"><td colspan="4">' + esc(row.label) + '</td></tr>'; return; }
      const side = (cell, cls) => cell
        ? '<td class="n">' + (cell.n ?? '') + '</td><td class="' + (cell.k === 'a' ? 'ha' : cell.k === 'd' ? 'hd' : '') + '">' + code(cell.s, null, cell.h, cls, null) + '</td>'
        : '<td class="n gap"></td><td class="gap"></td>';
      html += '<tr>' + side(row.l, 'hi-d') + side(row.r, 'hi-a') + '</tr>';
    });
  }
  host.innerHTML = html + '</table>';
  scheduleRuler();
}

// Rows within two of a find match, for Fold to matches.
function keptRows(index) {
  const keep = new Set();
  for (const m of find.matches) if (m.file === index) for (let k = m.row - 2; k <= m.row + 2; k++) keep.add(k);
  return keep;
}

// MARK: The head: lead, checks, list

function stat(a, d) {
  const s = el('span', 'd-stat');
  s.innerHTML = '<span class="d-add">+' + fmt(a) + '</span> <span class="d-del">−' + fmt(d) + '</span>';
  return s;
}

function drawHead(root) {
  const head = el('div', 'd-head');
  const lead = el('div', 'd-lead');
  lead.append(el('span', 'd-dot ' + model.lead.state), el('span', 'd-sentence', model.lead.sentence));
  if (model.lead.additions || model.lead.deletions) lead.append(stat(model.lead.additions, model.lead.deletions));
  head.append(lead);
  if (model.lead.subject) head.append(el('div', 'd-meta', model.lead.subject));
  if (model.lead.meta) head.append(el('div', 'd-meta', model.lead.meta));
  if (model.lead.message) {
    const msg = el('div', 'd-msg', model.lead.message);
    head.append(msg);
    requestAnimationFrame(() => {
      if (msg.scrollHeight <= msg.clientHeight + 1) return;
      const more = el('button', 'd-more', t('diff.more', 'More'));
      more.addEventListener('click', () => { const open = msg.classList.toggle('open'); more.textContent = open ? t('diff.less', 'Less') : t('diff.more', 'More'); });
      msg.after(more);
    });
  }
  if (model.notice) {
    const n = el('div', 'd-notice');
    n.append(el('b', null, model.notice.title), document.createTextNode(model.notice.detail));
    head.append(n);
  }
  if (model.checks.length) {
    const g = el('div', 'd-group');
    g.append(el('h6', null, t('diff.checks', 'Checks')));
    for (const c of model.checks) {
      const row = el('div', 'd-check');
      const show = el('a', null, t('diff.show', 'Show'));
      show.href = '#';
      show.addEventListener('click', (e) => { e.preventDefault(); revealFile(c.file); });
      row.append(el('span', 'd-bdg ' + c.level, c.kind === 'secret' ? t('diff.secret', 'Secret') : t('diff.script', 'Script')),
        el('span', 't', c.title), el('span', 's', c.detail), show);
      g.append(row);
    }
    head.append(g);
  }
  if (model.compare) { drawCompareList(head); root.append(head); return; }
  const g = el('div', 'd-group');
  if (model.checks.length) g.append(el('h6', null, t('diff.files', 'Files')));
  const list = el('ul', 'd-list');
  const limit = 5;
  model.files.forEach((f, i) => {
    const row = el('li', 'd-row');
    row.dataset.i = i;
    if (i >= limit) row.hidden = true;
    const name = el('span');
    name.append(el('span', 'dir', f.directory), el('span', 'nm', f.name));
    row.append(el('span', 'd-tile ' + f.letter, f.letter), name);
    if (f.from) {
      row.append(el('span', 'from', '← ' + f.from.split('/').pop()
        + (f.similarity != null ? ' · ' + t('diff.similar', '{pct} similar', { pct: percent(f.similarity / 100) }) : '')));
    }
    row.append(f.binary ? el('span', 'st', f.binary) : stat(f.additions, f.deletions));
    row.addEventListener('click', () => revealFile(i));
    list.append(row);
  });
  g.append(list);
  if (model.files.length > limit) {
    const more = el('button', 'd-more d-andmore', tn('diff.andMore', model.files.length - limit, 'and {n} more', 'and {n} more'));
    more.addEventListener('click', () => { list.querySelectorAll('li[hidden]').forEach((r) => { r.hidden = false; }); more.remove(); });
    g.append(more);
  }
  if (model.coverage) g.append(el('div', 'd-andmore', t('diff.rest', '{coverage}. The rest are counted, not drawn.', { coverage: model.coverage })));
  head.append(g);
  root.append(head);
}

// A two-file compare's list holds what changed (changes, line endings), not files; a click shows that place.
function drawCompareList(head) {
  const c = model.compare;
  if (c.items.length) {
    const g = el('div', 'd-group');
    g.append(el('h6', null, t('diff.whatChanged', 'What changed')));
    const list = el('ul', 'd-list');
    c.items.forEach((item, i) => {
      const row = el('li', 'd-row');
      if (i >= 5) row.hidden = true;
      const words = el('span');
      words.append(el('span', 'nm', item.title));
      if (item.detail) words.append(el('span', 'dir', ' · ' + item.detail));
      row.append(el('span', 'd-tile M', num(i + 1)), words);
      if (item.additions || item.deletions) row.append(stat(item.additions, item.deletions));
      if (item.line != null) row.addEventListener('click', () => (model.rich ? revealRich(item.line) : revealLine(0, item.line)));
      list.append(row);
    });
    g.append(list);
    if (c.items.length > 5) {
      const more = el('button', 'd-more d-andmore', tn('diff.andMore', c.items.length - 5, 'and {n} more', 'and {n} more'));
      more.addEventListener('click', () => { list.querySelectorAll('li[hidden]').forEach((r) => { r.hidden = false; }); more.remove(); });
      g.append(more);
    }
    head.append(g);
  }
  if (c.reveal && model.files.length) {
    const b = el('button', 'd-more', c.reveal);
    b.addEventListener('click', () => { detail.hidden = false; b.remove(); model.files.forEach((_, i) => { drawFile(i); colourFile(i); }); });
    head.append(b);
  }
}

// Scrolls the detail to the row with new-side number `n` in file `index`.
function revealLine(index, n) {
  const data = rows.get(index);
  if (!data) return;
  const i = data.unified.findIndex((r) => r.t === 'line' && r.n === n);
  const tr = detail.querySelectorAll('.d-file[data-i="' + index + '"] table.d-rows tr')[i];
  if (tr) tr.scrollIntoView({ block: 'center' });
}

// MARK: Compares by meaning (structure, prose, notebook, image)

let richMode = model.rich ? model.rich.modes[0].toLowerCase() : null;
let richBox = null;

function drawRich() {
  const r = model.rich;
  richBox.replaceChildren();
  const showRows = richMode === 'text' || (r.type === 'prose' && richMode === 'source');
  richBox.hidden = showRows;
  detail.querySelectorAll('.d-file').forEach((s) => { s.hidden = !showRows; });
  if (showRows) return;
  if (r.type === 'structural') drawStructure(r.structural);
  if (r.type === 'prose') drawProse(r.prose);
  if (r.type === 'notebook') drawNotebook(r.notebook);
  if (r.type === 'image') drawImage(r);
}

function drawStructure(s) {
  const box = el('div', 'r-tree');
  for (const n of s.nodes) {
    const row = el('div', 'r-node ' + n.mark);
    row.style.paddingLeft = (12 + n.depth * 16) + 'px';
    const sign = { changed: '~', added: '+', removed: '−', reorderedOnly: '', same: '' }[n.mark] || '';
    row.append(el('span', 'r-sign', sign), el('span', 'r-key', n.key), el('span', 'r-colon', ': '));
    if (n.kind !== 'value') row.append(el('span', 'r-sum', (n.summary || (n.kind === 'object' ? '{…}' : '[…]')) + ' '));
    if (n.mark === 'changed' && n.old != null && n.new != null && n.kind === 'value') {
      row.append(el('span', 'r-old', n.old), el('span', 'r-arrow', ' '), el('span', 'r-new', n.new));
    } else if (n.kind === 'value' || n.mark === 'added' || n.mark === 'removed') {
      const v = n.mark === 'removed' ? n.old : (n.new ?? n.old);
      if (v != null) row.append(el('span', n.mark === 'removed' ? 'r-old' : n.mark === 'added' ? 'r-new' : 'r-val', v));
    }
    box.append(row);
  }
  if (!s.isComplete && s.incompleteReason) box.append(el('div', 'd-omit', s.incompleteReason));
  richBox.append(box);
}

function drawProse(p) {
  const doc = el('article', 'r-prose');
  let list = null;
  p.blocks.forEach((b, i) => {
    let node;
    if (b.kind === 'heading') node = el('h' + Math.min(6, Math.max(1, b.level || 1)));
    else if (b.kind === 'listItem') {
      if (!list) { list = el('ul'); doc.append(list); }
      node = el('li');
    } else if (b.kind === 'code') node = el('pre');
    else if (b.kind === 'quote') node = el('blockquote');
    else node = el('p');
    if (b.kind !== 'listItem') list = null;
    node.id = 'rb' + i;
    node.className = 'r-' + b.status;
    for (const s of b.segments) {
      if (s.mark === 'same') node.append(document.createTextNode(s.text));
      else node.append(el(s.mark === 'inserted' ? 'ins' : 'del', null, s.text));
    }
    for (const l of b.linkChanges || []) {
      node.append(el('span', 'r-link', ' ' + t('diff.link', 'link “{text}”: {old} → {new}', { text: l.text, old: l.old, new: l.new })));
    }
    if (b.kind === 'listItem') list.append(node); else doc.append(node);
  });
  if (!p.isComplete && p.incompleteReason) doc.append(el('div', 'd-omit', p.incompleteReason));
  richBox.append(doc);
}

function drawNotebook(n) {
  const outputsOnly = richMode === 'outputs';
  for (const c of n.cells) {
    if (c.status === 'same') continue;
    const sec = el('section', 'd-file r-cell');
    sec.id = 'rc' + c.index;
    const h = el('div', 'dfh');
    const status = {
      sourceChanged: t('diff.sourceChanged', 'Source changed'), outputChanged: t('diff.outputChanged', 'Output changed'),
      both: t('diff.bothChanged', 'Source and output changed'), added: t('diff.added', 'Added'), removed: t('diff.removed', 'Removed'),
    }[c.status] || c.status;
    const kind = { code: t('diff.codeCell', 'Code cell'), markdown: t('diff.markdownCell', 'Markdown cell'), raw: t('diff.rawCell', 'Raw cell') }[c.kind]
      || t('diff.cell', 'Cell');
    h.append(el('span', 'd-tile M', String(c.index)), el('span', null, kind + ' · ' + status));
    if (c.oldExecutionCount != null || c.newExecutionCount != null) {
      h.append(el('span', 'st', '[' + (c.oldExecutionCount ?? ' ') + '] → [' + (c.newExecutionCount ?? ' ') + ']'));
    }
    sec.append(h);
    if (!outputsOnly && c.rows.length) {
      let html = '<table class="d-rows"><colgroup><col style="width:3.4em"><col style="width:3.4em"><col style="width:1.4em"><col></colgroup>';
      for (const row of c.rows) {
        const k = row.kind === 'added' ? 'a' : row.kind === 'deleted' ? 'd' : 'c';
        const hl = (row.highlights || []).map((x) => [x.start, x.start + x.length]);
        html += '<tr class="' + k + '"><td class="n o">' + (row.oldNumber ?? '') + '</td><td class="n">' + (row.newNumber ?? '') + '</td><td class="sg">'
          + (k === 'a' ? '+' : k === 'd' ? '−' : '') + '</td><td>' + code(row.text, null, hl, k === 'd' ? 'hi-d' : 'hi-a', null) + '</td></tr>';
      }
      const box = el('div', 'd-body');
      box.innerHTML = html + '</table>';
      sec.append(box);
    }
    for (const o of c.outputs) {
      if (o.status === 'same') continue;
      const box = el('div', 'r-output');
      const outputStatus = { changed: t('diff.changed', 'Changed'), added: t('diff.added', 'Added'), removed: t('diff.removed', 'Removed') }[o.status] || o.status;
      box.append(el('div', 'r-olabel', t('diff.output', 'Output · {type} · {status}', { type: o.type, status: outputStatus })));
      const pair = el('div', 'r-pair');
      const side = (text, img, mime, cls) => {
        const d = el('div', 'r-side ' + cls);
        if (img) { const im = el('img'); im.src = 'data:' + (mime || 'image/png') + ';base64,' + img; d.append(im); }
        else if (text != null) d.append(el('pre', null, text));
        else d.append(el('span', 'r-none', cls === 'r-was' ? t('diff.noneBefore', 'none before') : t('diff.noneAfter', 'none after')));
        return d;
      };
      pair.append(side(o.old, o.oldImage, o.mime, 'r-was'), side(o.new, o.newImage, o.mime, 'r-now'));
      box.append(pair);
      sec.append(box);
    }
    richBox.append(sec);
  }
}

function drawImage(r) {
  const i = r.image;
  const stage = el('div', 'r-stage r-' + richMode.replace(/\s+/g, '-'));
  const img = (src, label) => { const f = el('figure'); const im = el('img'); im.src = src; im.alt = label; f.append(im, el('figcaption', null, label)); return f; };
  const boxes = (into) => {
    if (!i.new.width || !i.new.height) return;
    for (const g of i.regions) {
      const b = el('div', 'r-box');
      b.dataset.region = g.index;
      Object.assign(b.style, { left: (g.x / i.new.width * 100) + '%', top: (g.y / i.new.height * 100) + '%',
        width: (g.width / i.new.width * 100) + '%', height: (g.height / i.new.height * 100) + '%' });
      b.append(el('span', null, String(g.index)));
      into.append(b);
    }
  };
  if (richMode === '2-up') {
    const a = img(r.oldSrc, t('diff.before', 'Before · {width} × {height}', { width: num(i.old.width), height: num(i.old.height) }));
    const b = img(r.newSrc, t('diff.after', 'After · {width} × {height}', { width: num(i.new.width), height: num(i.new.height) }));
    // Both pictures sit in the same kind of frame, so their captions line up; the regions are drawn on the new one.
    for (const f of [a, b]) { const wrap = el('div', 'r-boxes'); wrap.append(f.querySelector('img')); f.prepend(wrap); }
    boxes(b.querySelector('.r-boxes'));
    stage.append(a, b);
  } else if (richMode === 'swipe' || richMode === 'onion skin') {
    const frame = el('div', 'r-frame');
    const under = el('img', 'r-under'); under.src = r.oldSrc;
    const over = el('img', 'r-over'); over.src = r.newSrc;
    frame.append(under, over);
    const slider = el('input');
    slider.type = 'range'; slider.min = 0; slider.max = 100; slider.value = 50;
    const apply = () => {
      if (richMode === 'swipe') over.style.clipPath = 'inset(0 0 0 ' + slider.value + '%)';
      else over.style.opacity = String(slider.value / 100);
    };
    slider.addEventListener('input', apply);
    apply();
    stage.append(frame, slider);
  } else {
    const frame = el('div', 'r-frame');
    if (r.diffSrc) { const d = el('img'); d.src = r.diffSrc; frame.append(d); }
    else { const u = el('img', 'r-under'); u.src = r.oldSrc; const o = el('img', 'r-over r-blend'); o.src = r.newSrc; frame.append(u, o); }
    boxes(frame);
    stage.append(frame);
  }
  richBox.append(stage);
}

function revealRich(index) {
  const r = model.rich;
  const target = r.type === 'prose' ? document.getElementById('rb' + index)
    : r.type === 'notebook' ? document.getElementById('rc' + index)
    : r.type === 'image' ? richBox.querySelector('.r-box[data-region="' + index + '"]') : null;
  if (!target) return;
  target.scrollIntoView({ block: 'center' });
  target.classList.add('r-flash');
  setTimeout(() => target.classList.remove('r-flash'), 900);
}

// MARK: The detail

let detail;
function drawDetail(root) {
  detail = el('div', 'd-detail');
  model.files.forEach((f, i) => {
    const sec = el('section', 'd-file');
    sec.dataset.i = i;
    const h = el('div', 'dfh');
    const name = el('span');
    name.append(el('span', 'dir', f.directory), document.createTextNode(f.name));
    h.append(el('span', 'd-tile ' + f.letter, f.letter), name);
    if (f.from) h.append(el('span', 'dir', '← ' + f.from + (f.similarity != null ? ' · ' + percent(f.similarity / 100) : '')));
    if (f.modeChange) h.append(el('span', 'dir', f.modeChange));
    h.append(f.binary ? el('span', 'st', f.binary) : stat(f.additions, f.deletions));
    sec.append(h, el('div', 'd-body'));
    detail.append(sec);
  });
  root.append(detail);
  if (model.compare && model.compare.hidden) detail.hidden = true;
  if (model.rich) { richBox = el('div', 'r-box-root'); detail.prepend(richBox); drawRich(); }
  model.files.forEach((_, i) => drawFile(i));
  // Rows arrive as files come near; colours follow.
  const near = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      const i = Number(e.target.dataset.i);
      if (!rows.has(i)) post('rows', { index: i }); else colourFile(i);
    }
  }, { root: detail, rootMargin: '800px 0px' });
  detail.querySelectorAll('.d-file').forEach((s) => near.observe(s));
  let last = -1, timer = 0;
  detail.addEventListener('scroll', () => {
    const cur = currentFile();
    if (cur !== last) {
      last = cur;
      document.querySelectorAll('.d-row.on').forEach((r) => r.classList.remove('on'));
      const row = document.querySelector('.d-row[data-i="' + cur + '"]');
      if (row) row.classList.add('on');
      post('current', { index: cur });
    }
    clearTimeout(timer);
    timer = setTimeout(() => post('scroll', { y: detail.scrollTop }), 150);
  }, { passive: true });
}

// The shared ruler (C-8) over the detail: its scrollbar, with added and removed rows and find matches marked
// where they sit in what has been drawn (files not yet near are counted in the striped part at the end).
let rulerBox = null, rulerTimer = 0;
function drawRuler() {
  if (!rulerBox) return;
  const h = detail.scrollHeight || 1;
  const parts = [];
  const mark = (node, cls) => {
    let y = 0;
    for (let n = node; n && n !== detail; n = n.offsetParent) y += n.offsetTop;
    parts.push('<i class="' + cls + '" style="top:' + (y / h * 100).toFixed(3) + '%"></i>');
  };
  let last = null;
  detail.querySelectorAll('table.d-rows tr.a, table.d-rows tr.d').forEach((tr) => {
    const cls = tr.classList.contains('a') ? 'add' : 'del';
    if (last === tr.previousElementSibling && last && last.classList.contains(tr.className)) { last = tr; return; }
    last = tr;
    mark(tr, cls);
  });
  detail.querySelectorAll('mark.find').forEach((m) => mark(m, m.classList.contains('cur') ? 'fc' : 'f'));
  const unloaded = model.files.length - rows.size;
  rulerBox.querySelector('.marks').innerHTML = parts.join('');
  rulerBox.querySelector('.unshown').style.height = unloaded > 0 && model.files.length ? (unloaded / model.files.length * 100) + '%' : '0';
  placeThumb();
}
function placeThumb() {
  if (!rulerBox) return;
  const h = detail.scrollHeight || 1, thumb = rulerBox.querySelector('.thumb');
  thumb.style.top = (detail.scrollTop / h * 100) + '%';
  thumb.style.height = Math.min(100, detail.clientHeight / h * 100) + '%';
  thumb.hidden = detail.clientHeight >= h;
}
function scheduleRuler() { clearTimeout(rulerTimer); rulerTimer = setTimeout(drawRuler, 40); }
function makeRuler(root) {
  rulerBox = el('div', 'vt-ruler');
  rulerBox.append(el('div', 'marks'), el('div', 'unshown'), el('div', 'thumb'));
  root.append(rulerBox);
  const seek = (e, grab) => {
    const r = rulerBox.getBoundingClientRect();
    detail.scrollTop = Math.max(0, Math.min(1, (e.clientY - r.top - grab) / r.height)) * detail.scrollHeight;
  };
  rulerBox.addEventListener('mousedown', (e) => {
    e.preventDefault();
    const tr = rulerBox.querySelector('.thumb').getBoundingClientRect();
    const grab = e.clientY >= tr.top && e.clientY <= tr.bottom ? e.clientY - tr.top : tr.height / 2;
    seek(e, grab);
    const move = (m) => seek(m, grab), up = () => { removeEventListener('mousemove', move); removeEventListener('mouseup', up); };
    addEventListener('mousemove', move); addEventListener('mouseup', up);
  });
  const position = () => { rulerBox.style.top = detail.offsetTop + 'px'; scheduleRuler(); };
  window.addEventListener('resize', position);
  detail.addEventListener('scroll', placeThumb, { passive: true });
  position();
}

function currentFile() {
  const top = detail.getBoundingClientRect().top + 8;
  let cur = 0;
  detail.querySelectorAll('.d-file').forEach((s, i) => { if (s.getBoundingClientRect().top <= top) cur = i; });
  return cur;
}

function revealFile(i) {
  const sec = detail.querySelector('.d-file[data-i="' + i + '"]');
  if (sec) detail.scrollTop += sec.getBoundingClientRect().top - detail.getBoundingClientRect().top;
}

// MARK: Find

function runFind(query) {
  find.query = query;
  find.matches = [];
  if (!query) return;
  const q = query.toLowerCase();
  for (const [i, data] of [...rows.entries()].sort((a, b) => a[0] - b[0])) {
    data.unified.forEach((row, r) => {
      if (row.t !== 'line') return;
      const text = row.s.toLowerCase();
      for (let at = text.indexOf(q); at >= 0 && find.matches.length < 10000; at = text.indexOf(q, at + q.length)) {
        find.matches.push({ file: i, row: r, start: at, end: at + q.length });
      }
    });
  }
}

function redrawAll() { model.files.forEach((_, i) => drawFile(i)); }

window.vitrineDiff = {
  setRows(data) {
    rows.set(data.index, data);
    if (find.query) runFind(find.query);
    drawFile(data.index);
    colourFile(data.index);
  },
  setMode(m) {
    if (model.rich) { richMode = m; drawRich(); if (m === 'text' || m === 'source') redrawAll(); return; }
    mode = m; redrawAll();
  },
  richMode() { return richMode; },
  find(query, forward) {
    if (query !== find.query) { runFind(query); find.index = -1; if (mode !== 'unified') mode = 'unified'; }
    if (!find.matches.length) { redrawAll(); return { count: 0, index: -1, files: 0 }; }
    find.index = forward ? (find.index + 1) % find.matches.length : (find.index - 1 + find.matches.length) % find.matches.length;
    redrawAll();
    const cur = detail.querySelector('mark.find.cur');
    if (cur) cur.scrollIntoView({ block: 'center' });
    return { count: find.matches.length, index: find.index, files: new Set(find.matches.map((m) => m.file)).size };
  },
  clearFind() { find.query = ''; find.matches = []; find.index = -1; find.fold = false; redrawAll(); },
  foldToMatches(on) { find.fold = on; redrawAll(); return detail.querySelectorAll('.d-nomatch').length; },
  reveal(y) { if (typeof y === 'number') detail.scrollTop = y; },
  revealFile,
  revealLine,
  mode() { return mode; },
  colouredFiles() { return [...colours.keys()]; },
  rulerMarks() { drawRuler(); return Array.from(document.querySelectorAll('.vt-ruler i')).map((i) => i.className); },
};

const root = document.getElementById('vt-diff');
drawHead(root);
drawDetail(root);
makeRuler(root);
for (const i of rows.keys()) colourFile(i);
setTimeout(() => post('ready', {}), 0);
