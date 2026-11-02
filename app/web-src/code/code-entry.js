// Vitrine's code view (S-5, G-14): CodeMirror 6, read-only, coloured by Shiki's TextMate grammars in the unified
// syntax palette (G14), with sticky scope lines and folding by indentation (code design r3-a). Bundled by
// `tools/vendor_web.sh code` into VitrinePreviewKit/Resources/web/code/ and served as vitrine://app/code/code.js;
// every grammar is its own chunk, loaded only for the file's language. roadmap: S-5
import { EditorView, ViewPlugin, Decoration, lineNumbers, gutter, GutterMarker } from '@codemirror/view';
import { EditorState, RangeSetBuilder, Compartment } from '@codemirror/state';
import { foldService, foldGutter, codeFolding, foldEffect, unfoldEffect, foldedRanges } from '@codemirror/language';
import { SearchQuery, setSearchQuery, getSearchQuery, search, findNext, findPrevious } from '@codemirror/search';
import { createHighlighterCore } from 'shiki/core';
import { createOnigurumaEngine } from 'shiki/engine/oniguruma';
import { bundledLanguages } from 'shiki/langs';
import { INITIAL, EncodedTokenMetadata } from '@shikijs/vscode-textmate';
import { loadTheme, chromeColours, togglePopover } from './appearance.js';
import { analyzeLog, logExtensions, runLabel, levelOf } from './log.js';
import { t, tn, num } from './strings.js';

const post = (type, extra) => window.webkit?.messageHandlers?.vitrine?.postMessage({ type, ...extra });

// Shiki colours, line by line, carrying each line's rule stack to the next (the same calls @shikijs/monaco makes).
// A window of a large file starts from a fresh state at its first line, which is what state 14 shows.
function shikiColours(highlighter, lang, themeName) {
  const { colorMap } = highlighter.setTheme(themeName);
  const grammar = lang ? highlighter.getLanguage(lang) : null;
  const marks = new Map();
  const mark = (color, fontStyle) => {
    const key = color + '/' + fontStyle;
    let m = marks.get(key);
    if (!m) {
      let style = 'color:' + color;
      if (fontStyle & 1) style += ';font-style:italic';
      if (fontStyle & 2) style += ';font-weight:600';
      m = Decoration.mark({ attributes: { style } });
      marks.set(key, m);
    }
    return m;
  };
  return ViewPlugin.fromClass(class {
    constructor(view) { this.states = [INITIAL]; this.decorations = this.build(view); }
    update(u) {
      if (u.docChanged) this.states = [INITIAL];
      if (u.viewportChanged || u.docChanged) this.decorations = this.build(u.view);
    }
    // states[i] is the rule stack before line i + 1. Bounded per call so a jump far down cannot freeze the page:
    // past the budget the jump's lines draw uncoloured and colour on the next update.
    ensure(doc, line, deadline) {
      while (this.states.length < line) {
        if (performance.now() > deadline) return false;
        const n = this.states.length;
        this.states.push(grammar.tokenizeLine2(doc.line(n).text, this.states[n - 1], 500).ruleStack);
      }
      return true;
    }
    build(view) {
      const b = new RangeSetBuilder();
      if (!grammar) return b.finish();
      const doc = view.state.doc, deadline = performance.now() + 60;
      for (const { from, to } of view.visibleRanges) {
        let l = doc.lineAt(from).number;
        const last = doc.lineAt(to).number;
        if (!this.ensure(doc, l, deadline)) { setTimeout(() => view.dispatch({}), 0); break; }
        for (; l <= last; l++) {
          const line = doc.line(l);
          if (line.length > 20000) continue;
          const r = grammar.tokenizeLine2(line.text, this.states[l - 1], 500);
          if (this.states.length === l) this.states.push(r.ruleStack);
          const t = r.tokens;
          for (let j = 0; j < t.length; j += 2) {
            const s = t[j], e = j + 2 < t.length ? t[j + 2] : line.length;
            if (e <= s) continue;
            const md = t[j + 1];
            b.add(line.from + s, line.from + e, mark(colorMap[EncodedTokenMetadata.getForeground(md)], EncodedTokenMetadata.getFontStyle(md)));
          }
        }
      }
      return b.finish();
    }
  }, { decorations: (v) => v.decorations });
}

const indentOf = (text) => { const m = /^[\t ]*/.exec(text)[0]; let w = 0; for (const ch of m) w += ch === '\t' ? 4 : 1; return w; };
const blank = (text) => /^\s*$/.test(text);

// Folding by indentation: a line folds the lines after it that are indented deeper.
const indentFolding = foldService.of((state, from) => {
  const line = state.doc.lineAt(from);
  if (blank(line.text)) return null;
  const base = indentOf(line.text);
  let end = line.number, n = line.number + 1;
  for (; n <= state.doc.lines; n++) {
    const t = state.doc.line(n).text;
    if (blank(t)) continue;
    if (indentOf(t) <= base) break;
    end = n;
  }
  return end > line.number ? { from: line.to, to: state.doc.line(end).to } : null;
});

// Sticky scope lines (code design r3-a): the lines that open the scopes the top visible line sits in, up to three,
// pinned above the text on the page ground; a click scrolls to that line.
const sticky = ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view;
    this.dom = document.createElement('div');
    this.dom.className = 'vt-sticky';
    view.dom.appendChild(this.dom);
    this.onScroll = () => this.render();
    view.scrollDOM.addEventListener('scroll', this.onScroll, { passive: true });
    this.render();
  }
  update(u) { if (u.viewportChanged || u.geometryChanged) this.render(); }
  scopes() {
    const view = this.view, doc = view.state.doc;
    const top = view.lineBlockAtHeight(view.scrollDOM.scrollTop + 2);
    let n = doc.lineAt(top.from).number;
    while (n > 1 && blank(doc.line(n).text)) n--;
    let limit = indentOf(doc.line(n).text);
    const out = [];
    for (let k = n - 1; k >= 1 && limit > 0 && n - k < 4000; k--) {
      const t = doc.line(k).text;
      if (blank(t)) continue;
      const w = indentOf(t);
      if (w < limit && !/^\s*[}\])]/.test(t)) { out.unshift(k); limit = w; }
    }
    return out.slice(-3);
  }
  render() {
    const lines = this.view.scrollDOM.scrollTop > 0 ? this.scopes() : [];
    const key = lines.join(',');
    if (key === this.key) return;
    this.key = key;
    this.dom.replaceChildren(...lines.map((n) => {
      const row = document.createElement('div');
      row.className = 'vt-sticky-line';
      row.textContent = this.view.state.doc.line(n).text.replace(/\t/g, '    ');
      row.dataset.line = String(n);
      row.addEventListener('click', () => {
        const pos = this.view.state.doc.line(n).from;
        this.view.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: 'start' }) });
      });
      return row;
    }));
    this.dom.style.display = lines.length ? 'block' : 'none';
  }
  destroy() { this.view.scrollDOM.removeEventListener('scroll', this.onScroll); this.dom.remove(); }
});

// Indent guides (I-16): a hairline at each indent stop of a line's leading whitespace, drawn as the line's
// background, so they cost nothing to lay out; a blank line takes the deeper of its neighbours.
const guideMarks = new Map();
const guideMark = (depth) => {
  let m = guideMarks.get(depth);
  if (!m) { m = Decoration.line({ attributes: { class: 'vt-ig', style: '--vt-depth:' + depth } }); guideMarks.set(depth, m); }
  return m;
};
const indentGuides = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = this.build(view); }
  update(u) { if (u.viewportChanged || u.docChanged || u.geometryChanged) this.decorations = this.build(u.view); }
  build(view) {
    const b = new RangeSetBuilder(), doc = view.state.doc, tab = view.state.tabSize;
    const depthOf = (n) => {
      let k = n;
      while (k <= doc.lines && k - n < 200 && blank(doc.line(k).text)) k++;
      let j = n;
      while (j >= 1 && n - j < 200 && blank(doc.line(j).text)) j--;
      const below = k <= doc.lines ? indentOf(doc.line(k).text) : 0, above = j >= 1 ? indentOf(doc.line(j).text) : 0;
      return blank(doc.line(n).text) ? Math.min(below, above) : indentOf(doc.line(n).text);
    };
    for (const { from, to } of view.visibleRanges) {
      for (let n = doc.lineAt(from).number, last = doc.lineAt(to).number; n <= last; n++) {
        const depth = Math.floor(depthOf(n) / tab);
        if (depth > 0) b.add(doc.line(n).from, doc.line(n).from, guideMark(Math.min(depth, 24)));
      }
    }
    return b.finish();
  }
}, { decorations: (v) => v.decorations });

// Changed lines (I-16, the hero): lines added (green), changed (blue) or removed after (a grey wedge, not red: a
// deletion is not danger) since the last commit, from Swift's line diff against HEAD.
class ChangeMarker extends GutterMarker {
  constructor(kind) { super(); this.kind = kind; }
  eq(o) { return o.kind === this.kind; }
  toDOM() { const s = document.createElement('span'); s.className = 'vt-chg-' + this.kind; return s; }
}
const changeMarkers = { add: new ChangeMarker('add'), mod: new ChangeMarker('mod'), del: new ChangeMarker('del') };
let changes = [];
const changedLines = gutter({
  class: 'vt-chg',
  markers(view) {
    const b = new RangeSetBuilder(), doc = view.state.doc;
    const marks = [];
    for (const c of changes) {
      for (let n = c.from; n <= c.to; n++) {
        const local = n - win.first + 1;
        if (local >= 1 && local <= doc.lines) marks.push([doc.line(local).from, changeMarkers[c.kind]]);
      }
    }
    marks.sort((a, b2) => a[0] - b2[0]);
    for (const [pos, m] of marks) b.add(pos, pos, m);
    return b.finish();
  },
  initialSpacer: () => changeMarkers.add,
});

// The minimap (state 15): every line of what is loaded as a short bar at its indent and length, the visible part
// framed; a click or drag scrolls there.
const minimap = ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view;
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'vt-minimap';
    view.dom.appendChild(this.canvas);
    view.dom.classList.add('vt-has-minimap');
    this.onScroll = () => this.draw();
    view.scrollDOM.addEventListener('scroll', this.onScroll, { passive: true });
    const seek = (e) => {
      const r = this.canvas.getBoundingClientRect();
      const share = Math.max(0, Math.min(1, (e.clientY - r.top) / r.height));
      const s = view.scrollDOM;
      s.scrollTop = share * (s.scrollHeight) - s.clientHeight / 2;
    };
    this.canvas.addEventListener('mousedown', (e) => {
      seek(e);
      const move = (m) => seek(m), up = () => { removeEventListener('mousemove', move); removeEventListener('mouseup', up); };
      addEventListener('mousemove', move); addEventListener('mouseup', up);
    });
    this.draw();
  }
  update(u) { if (u.docChanged || u.geometryChanged || u.viewportChanged) this.draw(); }
  draw() {
    const view = this.view, c = this.canvas, doc = view.state.doc, s = view.scrollDOM;
    const ratio = window.devicePixelRatio || 1, w = 64, h = view.dom.clientHeight;
    if (!h) return;
    c.width = w * ratio; c.height = h * ratio; c.style.height = h + 'px';
    const g = c.getContext('2d');
    g.scale(ratio, ratio);
    const lineH = Math.min(2, h / Math.max(1, doc.lines));
    const style = getComputedStyle(document.documentElement);
    g.fillStyle = style.getPropertyValue('--v-t1').trim() || '#888';
    g.globalAlpha = 0.35;
    const step = Math.max(1, Math.ceil(doc.lines / h));
    for (let n = 1; n <= doc.lines; n += step) {
      const text = doc.line(n).text;
      if (blank(text)) continue;
      const indent = indentOf(text), len = Math.min(text.length, 160);
      g.fillRect(4 + indent * 0.35, (n - 1) * lineH, Math.max(1, (len - indent) * 0.35), Math.max(1, lineH * 0.7));
    }
    g.globalAlpha = 0.12;
    const total = s.scrollHeight || 1;
    g.fillRect(0, (s.scrollTop / total) * Math.min(h, doc.lines * lineH), w, (s.clientHeight / total) * Math.min(h, doc.lines * lineH));
  }
  destroy() {
    this.view.scrollDOM.removeEventListener('scroll', this.onScroll);
    this.view.dom.classList.remove('vt-has-minimap');
    this.canvas.remove();
  }
});

// The shared ruler (C-8, the design's 12 pt ruler with 3 pt marks): it is the code view's scrollbar — a thumb for
// what is in view, dragged or clicked to move — and it marks where find matches (the current one stronger), changed
// lines (add, change, removed after), log warnings and errors, and the selection sit in the whole file.
let rulerLevels = null; // log analysis levels, set by the log view
const ruler = ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view;
    this.dom = document.createElement('div');
    this.dom.className = 'vt-ruler';
    this.marks = document.createElement('div');
    this.thumb = document.createElement('div');
    this.thumb.className = 'thumb';
    this.dom.append(this.marks, this.thumb);
    view.dom.appendChild(this.dom);
    view.dom.classList.add('vt-has-ruler');
    this.onScroll = () => this.place();
    view.scrollDOM.addEventListener('scroll', this.onScroll, { passive: true });
    // A resize places the thumb again without waiting for CodeMirror's measure, which needs an animation frame.
    this.onResize = () => { clearTimeout(this.timer); this.timer = setTimeout(() => this.draw(), 30); };
    window.addEventListener('resize', this.onResize);
    const seek = (e, grab) => {
      const r = this.dom.getBoundingClientRect(), s = view.scrollDOM;
      const y = Math.max(0, Math.min(1, (e.clientY - r.top - grab) / r.height));
      s.scrollTop = y * (s.scrollHeight);
    };
    this.dom.addEventListener('mousedown', (e) => {
      e.preventDefault();
      const tr = this.thumb.getBoundingClientRect();
      // Grabbing the thumb keeps the point under the pointer; clicking elsewhere centres the view there.
      const grab = e.clientY >= tr.top && e.clientY <= tr.bottom ? e.clientY - tr.top : tr.height / 2;
      seek(e, grab);
      const move = (m) => seek(m, grab), up = () => { removeEventListener('mousemove', move); removeEventListener('mouseup', up); };
      addEventListener('mousemove', move); addEventListener('mouseup', up);
    });
    this.timer = 0;
    this.draw();
  }
  update(u) {
    if (u.docChanged || u.geometryChanged || u.selectionSet || u.transactions.some((tr) => tr.effects.length)) {
      clearTimeout(this.timer);
      this.timer = setTimeout(() => this.draw(), 30);
    } else if (u.viewportChanged) this.place();
  }
  // Every mark at its line's place in the whole file (a huge file's window maps into the file).
  draw() {
    const view = this.view, doc = view.state.doc;
    const total = win.on ? Math.max(win.total, absolute(doc.lines)) : doc.lines;
    const at = (n) => ((absolute(n) - 1) / Math.max(1, total)) * 100 + '%';
    const out = [];
    const add = (n, cls) => { out.push('<i class="' + cls + '" style="top:' + at(n) + '"></i>'); };
    for (const c of changes) {
      const local = c.from - win.first + 1;
      if (local >= 1 && local <= doc.lines) add(local, c.kind === 'add' ? 'add' : c.kind === 'mod' ? 'chg' : 'del');
    }
    if (rulerLevels) for (const l of rulerLevels) if (l.rank >= 3) add(l.line, l.rank >= 4 ? 'danger' : 'caution');
    const q = getSearchQuery(view.state);
    if (q && q.search && q.valid) {
      const cur = view.state.selection.main;
      const cursor = q.getCursor(view.state);
      let last = -1, n = 0;
      for (let m = cursor.next(); !m.done && n < 5000; m = cursor.next(), n++) {
        const line = doc.lineAt(m.value.from).number;
        if (m.value.from === cur.from && m.value.to === cur.to) add(line, 'fc');
        else if (line !== last) add(line, 'f');
        last = line;
      }
    }
    const sel = view.state.selection.main;
    if (!sel.empty) add(doc.lineAt(sel.from).number, 'sel');
    this.marks.innerHTML = out.join('');
    this.place();
  }
  place() {
    const s = this.view.scrollDOM, h = s.scrollHeight || 1;
    let top = s.scrollTop / h, size = s.clientHeight / h;
    if (win.on) {
      // In a window of a huge file the thumb says where the window's view sits in the whole file.
      const doc = this.view.state.doc, total = Math.max(win.total, absolute(doc.lines));
      const lineTop = doc.lineAt(this.view.lineBlockAtHeight(s.scrollTop).from).number;
      top = (absolute(lineTop) - 1) / total;
      size = Math.max(0.01, (s.clientHeight / Math.max(1, this.view.defaultLineHeight)) / total);
    }
    this.thumb.style.top = (top * 100) + '%';
    this.thumb.style.height = Math.max(2, Math.min(100, size * 100)) + '%';
    this.thumb.hidden = size >= 1;
  }
  destroy() {
    this.view.scrollDOM.removeEventListener('scroll', this.onScroll);
    window.removeEventListener('resize', this.onResize);
    this.view.dom.classList.remove('vt-has-ruler');
    this.dom.remove();
  }
});

// Scroll memory: the host keeps the last position for the next open of this file (throttled).
let scrollTimer = 0;
const scrollReport = ViewPlugin.fromClass(class {
  constructor(view) {
    this.onScroll = () => { clearTimeout(scrollTimer); scrollTimer = setTimeout(() => post('scroll', { y: view.scrollDOM.scrollTop }), 150); };
    view.scrollDOM.addEventListener('scroll', this.onScroll, { passive: true });
    this.view = view;
  }
  destroy() { this.view.scrollDOM.removeEventListener('scroll', this.onScroll); }
});

// A huge file (state 14) is shown a window at a time: `win.first` is the file's line number of the window's first
// line, `win.total` the file's line count (an estimate until Swift has counted them all), `win.exact` whether it is
// counted. Small files are one window from line 1.
const win = { on: false, first: 1, total: 0, exact: true, pending: false };
const absolute = (local) => win.first + local - 1;

// Line selection on the gutter's right (code 1): "Ln 40–47 · 8 lines", in the file's own line numbers.
const selectionReport = EditorView.updateListener.of((u) => {
  if (!u.selectionSet) return;
  const r = u.state.selection.main, doc = u.state.doc;
  const a = doc.lineAt(r.from).number, b = doc.lineAt(r.to).number;
  post('selection', { from: absolute(a), to: absolute(b), empty: r.empty });
});

// Near either end of the window, ask Swift for the window around the top line; the banner says which lines are
// coming ("Loading lines 18,199,905–18,204,000").
const windowEdges = ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view;
    this.onScroll = () => this.check();
    view.scrollDOM.addEventListener('scroll', this.onScroll, { passive: true });
  }
  check() {
    const view = this.view;
    if (!win.on || win.pending) return;
    const doc = view.state.doc, margin = Math.min(400, Math.floor(doc.lines / 4));
    const top = doc.lineAt(view.lineBlockAtHeight(view.scrollDOM.scrollTop).from).number;
    const bottom = doc.lineAt(view.lineBlockAtHeight(view.scrollDOM.scrollTop + view.scrollDOM.clientHeight).from).number;
    const more = !win.exact || absolute(doc.lines) < win.total;
    if ((top <= margin && win.first > 1) || (bottom >= doc.lines - margin && more)) {
      const block = view.lineBlockAt(doc.line(top).from);
      requestWindow(absolute(top), block.top - view.scrollDOM.scrollTop, false);
    }
  }
  destroy() { this.view.scrollDOM.removeEventListener('scroll', this.onScroll); }
});

let windowSize = 4096;
function requestWindow(line, dy, reveal) {
  win.pending = true;
  const first = Math.max(1, line - Math.floor(windowSize / 2));
  const banner = document.getElementById('vt-loading');
  if (banner) {
    banner.textContent = t('code.loadingLines', 'Loading lines {from}–{to}', { from: num(first), to: num(first + windowSize - 1) });
    banner.style.display = 'block';
  }
  post('window', { line, first, dy, reveal });
}

// The gutter on the page ground in both appearances: CodeMirror's own light and dark base themes would otherwise
// paint it, and an editor theme outranks them where a page style sheet does not.
const chrome = EditorView.theme({
  '.cm-gutters': { backgroundColor: 'var(--v-page)', color: 'var(--v-t3)', border: 'none' },
  '.cm-activeLineGutter.cm-lineNumbers .cm-gutterElement': { color: 'var(--v-t2)' },
  '.cm-activeLineGutter': { backgroundColor: 'transparent' },
  '.cm-foldPlaceholder': { backgroundColor: 'var(--v-fill)', border: 'none', color: 'var(--v-t2)' },
});

// A theme other than Vitrine's colours the page around the code too: ground, text, line numbers, selection.
const THEMED = ['--v-page', '--v-t1', '--v-t2', '--v-t3', '--v-sel', '--vt-guide'];
function applyChrome(theme) {
  const root = document.documentElement.style;
  if (!theme) { THEMED.forEach((p) => root.removeProperty(p)); return; }
  const c = chromeColours(theme);
  root.setProperty('--v-page', c.bg);
  root.setProperty('--v-t1', c.fg);
  root.setProperty('--v-t2', c.active);
  root.setProperty('--v-t3', c.gutter);
  root.setProperty('--v-sel', c.sel);
  root.setProperty('--vt-guide', c.guide);
}

const LINE_HEIGHTS = { tight: '1.4', normal: '1.6', roomy: '1.85' };
function applyFont(opts) {
  const root = document.documentElement.style;
  root.setProperty('--v-mono', '"' + opts.font.replace(/"/g, '') + '", ui-monospace, "SF Mono", Menlo, monospace');
  root.setProperty('--v-fs-mono', opts.fontSize + 'px');
  root.setProperty('--v-fs-mono-lh', LINE_HEIGHTS[opts.lineHeight] || '1.6');
  root.setProperty('--vt-tab', String(opts.tabSize));
}

// Symbols (state 1, the @ prefix): declarations found by the grammar's scopes — functions and methods (M), types
// (C), properties and constants (P) — with the line each is on. Bounded: the first 20,000 lines, 400 ms.
function scanSymbols(highlighter, lang, doc) {
  const grammar = lang && highlighter ? highlighter.getLanguage(lang) : null;
  const out = [];
  if (!grammar) return out;
  let state = INITIAL;
  const deadline = performance.now() + 400;
  for (let n = 1; n <= Math.min(doc.lines, 20000) && performance.now() < deadline; n++) {
    const text = doc.line(n).text;
    if (text.length > 2000) continue;
    const r = grammar.tokenizeLine(text, state, 50);
    state = r.ruleStack;
    for (const tk of r.tokens) {
      const sc = tk.scopes.join(' ');
      let kind = null;
      // Parameter labels and call sites carry function scopes in some grammars (Swift's `scale:`); they are not
      // declarations.
      if (/meta\.parameter|variable\.parameter|meta\.function-call|meta\.argument/.test(sc)) continue;
      if (/entity\.name\.function(?!\.call)/.test(sc)) kind = 'M';
      else if (/entity\.name\.(type|class|struct|enum|interface|namespace|module)/.test(sc) && !/meta\.type\.annotation|meta\.return-type|meta\.inheritance/.test(sc)) kind = 'C';
      else if (/(meta\.definition\.(property|variable)|entity\.name\.variable|variable\.other\.constant\.declaration)/.test(sc) && /variable|entity\.name/.test(tk.scopes[tk.scopes.length - 1])) kind = 'P';
      if (!kind) continue;
      const name = text.slice(tk.startIndex, tk.endIndex).trim();
      if (!name || !/^[\w$.:<>~-]+$/.test(name)) continue;
      if (out.length && out[out.length - 1].line === n && out[out.length - 1].name === name) continue;
      out.push({ kind, name: kind === 'M' ? name + '()' : name, line: n });
    }
  }
  return out;
}

// The symbol list above the capsule (state 1): "Symbols in syncQueue.ts", the matches with their kind and line.
function showSymbols(file, list, current, onPick) {
  let box = document.getElementById('vt-syms');
  if (!list) { if (box) box.remove(); return; }
  if (!box) { box = document.createElement('div'); box.id = 'vt-syms'; document.body.append(box); }
  box.replaceChildren();
  const h = document.createElement('h6');
  h.textContent = t('code.symbolsIn', 'Symbols in {file}', { file });
  box.append(h);
  if (!list.length) { const e = document.createElement('div'); e.className = 'vt-sym-none'; e.textContent = t('code.noSymbolsMatch', 'No symbols match'); box.append(e); }
  list.slice(0, 12).forEach((s, i) => {
    const row = document.createElement('div');
    row.className = 'vt-sym' + (i === current ? ' on' : '');
    const k = document.createElement('span'); k.className = 'vt-sk vt-sk-' + s.kind; k.textContent = s.kind;
    const n = document.createElement('span'); n.className = 'vt-sn'; n.textContent = s.name;
    const l = document.createElement('span'); l.className = 'vt-sl'; l.textContent = t('code.ln', 'Ln {line}', { line: num(s.line) });
    row.append(k, n, l);
    row.addEventListener('mousedown', (e) => { e.preventDefault(); onPick(i); });
    box.append(row);
  });
}

// Folds Vitrine makes itself, each with the words its placeholder says: lines away from find matches (state 1),
// repeated log lines and lines below a log level (state 11). Keyed by the fold's start position.
const foldLabels = new Map();
const withoutMatch = (n) => tn('code.linesWithoutMatch', n, '{n} line without a match', '{n} lines without a match');

// Removes Vitrine's folds of one kind, adds `ranges` ([from line, to line, text]) of that kind.
function setFolds(view, kind, ranges) {
  const doc = view.state.doc, fx = [];
  foldedRanges(view.state).between(0, doc.length, (from, to) => {
    if (foldLabels.get(from)?.kind === kind) { fx.push(unfoldEffect.of({ from, to })); foldLabels.delete(from); }
  });
  for (const [a, b, text] of ranges) {
    // A fold hides the lines after its start line: the line before the run anchors it.
    const anchor = Math.max(1, a - 1);
    const from = doc.line(anchor).to, to = doc.line(Math.min(b, doc.lines)).to;
    if (to <= from) continue;
    foldLabels.set(from, { kind, text });
    fx.push(foldEffect.of({ from, to }));
  }
  if (fx.length) view.dispatch({ effects: fx });
  return ranges.length;
}

// Runs of lines (at least three) for which `keep(n)` is false.
function runsWithout(doc, keep) {
  const out = [];
  let n = 1;
  while (n <= doc.lines) {
    if (keep(n)) { n++; continue; }
    let end = n;
    while (end + 1 <= doc.lines && !keep(end + 1)) end++;
    if (end - n + 1 >= 3) out.push([n === 1 ? 2 : n, end]);
    n = end + 1;
  }
  return out.filter(([a, b]) => b >= a);
}

// Fold to matches (state 1): every run of lines more than two away from a match folds into "N lines without a
// match"; turning it off unfolds exactly those.
function foldToMatches(view, query, on) {
  if (!on || !query) return setFolds(view, 'nomatch', []);
  const doc = view.state.doc, hit = new Uint8Array(doc.lines + 2);
  const cursor = query.getCursor(view.state);
  for (let m = cursor.next(); !m.done; m = cursor.next()) {
    const a = doc.lineAt(m.value.from).number;
    for (let k = Math.max(1, a - 2); k <= Math.min(doc.lines, a + 2); k++) hit[k] = 1;
  }
  return setFolds(view, 'nomatch', runsWithout(doc, (n) => hit[n] === 1).map(([a, b]) => [a, b, withoutMatch(b - a + 1)]));
}

// The chip for lines that arrived (state 12): "Following" at the end, "3 new lines · newest at the bottom" above it.
let followTimer = 0, unseen = 0;
function showFollow(added, following) {
  let chip = document.getElementById('vt-follow');
  if (!chip) {
    chip = document.createElement('button');
    chip.id = 'vt-follow';
    chip.type = 'button';
    chip.addEventListener('click', () => { const s = window.vitrine.view.scrollDOM; s.scrollTop = s.scrollHeight; unseen = 0; chip.style.display = 'none'; });
    document.body.append(chip);
  }
  unseen = following ? 0 : unseen + added;
  chip.textContent = following ? tn('code.following', added, 'Following · {n} new line', 'Following · {n} new lines')
    : tn('code.newLines', unseen, '{n} new line · newest at the bottom', '{n} new lines · newest at the bottom');
  chip.style.display = 'block';
  clearTimeout(followTimer);
  if (following) followTimer = setTimeout(() => { chip.style.display = 'none'; }, 2500);
}

// The strip above the code (state 3): how the bytes were read, where the language came from, "Reopen as…".
function showNotice(notice) {
  const bar = document.getElementById('vt-note');
  if (!bar || !notice) return;
  const text = document.createElement('span');
  text.className = 'vt-note-text';
  text.textContent = notice.text;
  const pick = document.createElement('select');
  pick.title = t('code.reopenAs', 'Reopen as…');
  const first = document.createElement('option');
  first.textContent = t('code.reopenAs', 'Reopen as…');
  first.disabled = true;
  first.selected = true;
  pick.append(first);
  for (const e of notice.encodings) {
    const o = document.createElement('option');
    o.value = String(e.raw);
    o.textContent = e.name + (e.raw === notice.current ? ' ✓' : '');
    pick.append(o);
  }
  pick.addEventListener('change', () => { post('reopen', { encoding: Number(pick.value) }); pick.selectedIndex = 0; });
  bar.append(text, pick);
  bar.style.display = 'flex';
}

async function start() {
  const config = JSON.parse(document.getElementById('vt-config').textContent);
  const source = JSON.parse(document.getElementById('vt-source').textContent);
  if (config.window) {
    Object.assign(win, { on: true, first: config.window.first, total: config.window.total, exact: config.window.exact });
    windowSize = config.window.size || windowSize;
  }
  const t0 = performance.now();
  // Display options (state 15), kept by Swift; the defaults are the design's.
  const opts = Object.assign({ theme: 'vitrine', font: 'SF Mono', fontSize: 12, lineHeight: 'normal', tabSize: 4, wrap: false,
    lineNumbers: true, indentGuides: true, changedLines: true, sticky: true, minimap: false }, config.options || {});
  const imported = config.imported || [];
  const fonts = config.fonts || ['SF Mono', 'Menlo', 'Monaco', 'Courier New'];
  changes = config.changes || [];
  let lang = bundledLanguages[config.lang] ? config.lang : null;
  let highlighter = null, theme = null;
  try {
    theme = await loadTheme(opts.theme, imported).catch(() => loadTheme('vitrine', []));
    highlighter = await createHighlighterCore({
      themes: [theme],
      langs: lang ? [bundledLanguages[lang]] : [],
      engine: createOnigurumaEngine(import('shiki/wasm')),
    });
  } catch (e) {
    lang = null;
    post('error', { message: 'Colours unavailable: ' + String(e && e.message || e) });
  }
  applyChrome(opts.theme === 'vitrine' ? null : theme);
  applyFont(opts);
  const colours = new Compartment(), numbers = new Compartment(), wrapping = new Compartment(), tabs = new Compartment();
  const guides = new Compartment(), changed = new Compartment(), stickiness = new Compartment(), map = new Compartment();
  const logs = new Compartment();
  let analysis = null;
  const numbersExt = () => opts.lineNumbers
    ? [lineNumbers({ formatNumber: (n) => win.on ? num(absolute(n)) : String(n) })] : [];
  const view = new EditorView({
    parent: document.getElementById('vt-code'),
    state: EditorState.create({
      doc: source,
      extensions: [
        changed.of(opts.changedLines ? changedLines : []), numbers.of(numbersExt()), chrome,
        codeFolding({
          preparePlaceholder: (state, range) => foldLabels.get(range.from) || null,
          placeholderDOM: (view, onclick, label) => {
            const s = document.createElement('span');
            s.className = label ? 'cm-foldPlaceholder vt-' + label.kind : 'cm-foldPlaceholder';
            s.textContent = label ? label.text : '…';
            s.onclick = onclick;
            return s;
          },
        }),
        foldGutter({ markerDOM: (open) => {
          const s = document.createElement('span'); s.className = 'vt-fold'; s.textContent = open ? '⌄' : '›'; return s; } }),
        indentFolding, EditorState.readOnly.of(true), EditorView.editable.of(false), tabs.of(EditorState.tabSize.of(opts.tabSize)),
        wrapping.of(opts.wrap ? EditorView.lineWrapping : []),
        search({ top: true, createPanel: () => ({ dom: document.createElement('div') }) }),
        colours.of(highlighter ? shikiColours(highlighter, lang, theme.name) : []),
        guides.of(opts.indentGuides ? indentGuides : []), stickiness.of(opts.sticky ? sticky : []), map.of(opts.minimap ? minimap : []),
        selectionReport, scrollReport, windowEdges, logs.of([]), ruler,
      ],
    }),
  });
  // One option changed in the popover: applied now, kept by Swift for every code file after this one.
  async function setOption(key, value) {
    if (key === 'importTheme') { post('importTheme', {}); return; }
    opts[key] = value;
    post('option', { key, value });
    const fx = [];
    if (key === 'theme') {
      const next = await loadTheme(value, imported).catch(() => null);
      if (!next || !highlighter) return;
      await highlighter.loadTheme(next);
      theme = next;
      applyChrome(value === 'vitrine' ? null : next);
      fx.push(colours.reconfigure(shikiColours(highlighter, lang, next.name)));
    }
    if (key === 'lineNumbers') fx.push(numbers.reconfigure(numbersExt()));
    if (key === 'wrap') fx.push(wrapping.reconfigure(value ? EditorView.lineWrapping : []));
    if (key === 'tabSize') fx.push(tabs.reconfigure(EditorState.tabSize.of(value)));
    if (key === 'indentGuides') fx.push(guides.reconfigure(value ? indentGuides : []));
    if (key === 'changedLines') fx.push(changed.reconfigure(value ? changedLines : []));
    if (key === 'sticky') fx.push(stickiness.reconfigure(value ? sticky : []));
    if (key === 'minimap') fx.push(map.reconfigure(value ? minimap : []));
    if (key === 'font' || key === 'fontSize' || key === 'lineHeight' || key === 'tabSize') { applyFont(opts); view.requestMeasure(); }
    if (fx.length) view.dispatch({ effects: fx });
  }

  showNotice(config.notice);
  // Minified CSS or SQL (C-5, state 4): shown formatted, the file's own text one click away.
  if (config.original) {
    const formatted = source;
    let showingFormatted = true;
    const bar = document.getElementById('vt-note');
    const say = document.createElement('span');
    say.className = 'vt-note-text';
    const flip = document.createElement('button');
    flip.className = 'vt-btn';
    flip.type = 'button';
    const label = () => {
      const n = config.original.lines;
      say.textContent = showingFormatted
        ? tn('code.formattedFrom', n, 'Formatted from {n} line for reading. The file on disk is untouched.',
          'Formatted from {n} lines for reading. The file on disk is untouched.')
        : t('code.asOnDisk', 'The file as it is on disk.');
      flip.textContent = showingFormatted ? t('code.showOriginal', 'Show original') : t('code.formatForReading', 'Format for reading');
    };
    flip.addEventListener('click', () => {
      showingFormatted = !showingFormatted;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: showingFormatted ? formatted : config.original.text } });
      label();
      post('formatted', { on: showingFormatted });
    });
    label();
    flip.style.marginLeft = 'auto';
    bar.replaceChildren(say, flip);
    bar.style.display = 'flex';
  }

  // The log view (state 11): levels, silences and folded repeats; Text shows the same lines plain.
  let logShown = false;
  function showLog(on, fresh) {
    logShown = on;
    if (on && (!analysis || fresh)) analysis = analyzeLog(view.state.doc);
    view.dispatch({ effects: logs.reconfigure(on ? logExtensions(analysis) : []) });
    rulerLevels = on ? analysis.levels : null;
    setFolds(view, 'run', on ? analysis.runs.map((r) => [r.from, r.to, t('code.showAll', '{label} · Show all', { label: runLabel(r) })]) : []);
    if (on) post('log', { errors: analysis.errors, warnings: analysis.warnings, runs: analysis.runs.length, gaps: analysis.gaps.length });
  }
  if (config.log) showLog(true);

  window.vitrine = {
    view,
    options: opts,
    // Follow tail (state 12): lines added to the file arrive at the end; the view follows when it was at the end,
    // else a chip says how many arrived and takes you there.
    appendText(tail) {
      const s = view.scrollDOM, atEnd = s.scrollTop + s.clientHeight >= s.scrollHeight - 8;
      const before = view.state.doc.lines;
      view.dispatch({ changes: { from: view.state.doc.length, insert: tail } });
      const added = Math.max(0, view.state.doc.lines - before);
      if (logShown) showLog(true, true);
      if (atEnd) s.scrollTop = s.scrollHeight;
      showFollow(added, atEnd);
      return { added, following: atEnd };
    },
    // "Reopen as…" (state 3): the same file read in another encoding.
    replaceText(text, note) {
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
      const span = document.querySelector('#vt-note .vt-note-text');
      if (span && note) span.textContent = note;
    },
    setOption,
    // The capsule's More button (state 15).
    toggleAppearance() { return togglePopover(opts, imported, fonts, setOption); },
    themeName() { return theme ? theme.name : null; },
    setChanges(list) { changes = list; view.dispatch({ effects: changed.reconfigure(opts.changedLines ? changedLines : []) }); },
    // Capsule find (I-1): every match marked, the current one selected and scrolled to; returns the count and place.
    find(query, forward) {
      if (!query) { this.clearFind(); return { count: 0, index: -1 }; }
      // Prefixes (state 1): ":42" goes to a line, "@flu" lists and steps through symbols.
      if (query.startsWith(':')) {
        showSymbols(null, null);
        const n = parseInt(query.slice(1).replace(/[^0-9]/g, ''), 10);
        if (!n) return { count: 0, index: -1, label: t('code.typeLineNumber', 'Type a line number') };
        this.goToLine(n);
        return { count: 1, index: 0, label: t('code.line', 'Line {line}', { line: num(n) }) };
      }
      if (query.startsWith('@')) {
        if (!this.symbols) this.symbols = scanSymbols(highlighter, lang, view.state.doc);
        const q = query.slice(1).toLowerCase();
        const list = this.symbols.filter((s) => s.name.toLowerCase().includes(q));
        if (this.lastSymbolQuery !== query) { this.symbolIndex = 0; this.lastSymbolQuery = query; }
        else if (list.length) this.symbolIndex = (this.symbolIndex + (forward ? 1 : list.length - 1)) % list.length;
        const pick = (i) => {
          this.symbolIndex = i;
          const s = list[i];
          const line = view.state.doc.line(s.line);
          view.dispatch({ selection: { anchor: line.from }, effects: EditorView.scrollIntoView(line.from, { y: 'start', yMargin: 40 }) });
          showSymbols(config.fileName, list, i, pick);
        };
        if (list.length) pick(this.symbolIndex); else showSymbols(config.fileName, list, -1, pick);
        return { count: list.length, index: list.length ? this.symbolIndex : -1,
          label: list.length ? tn('code.symbolOf', list.length, '{i} of {n} symbol', '{i} of {n} symbols', { i: num(this.symbolIndex + 1) })
            : t('code.noSymbols', 'No symbols') };
      }
      showSymbols(null, null);
      if (query.toLowerCase().startsWith('level:')) {
        // level:warn keeps WARN and worse; a line with no level belongs to the line above it (a stack trace).
        const want = { trace: 0, debug: 1, info: 2, notice: 2, warn: 3, warning: 3, error: 4, err: 4, fatal: 5 }[query.slice(6).trim().toLowerCase()];
        if (want === undefined) {
          setFolds(view, 'level', []);
          return { count: 0, index: -1, label: t('code.levelHint', 'trace, debug, info, warn, error or fatal') };
        }
        const doc = view.state.doc, rank = new Int8Array(doc.lines + 2);
        let last = -1, kept = 0;
        for (let n = 1; n <= doc.lines; n++) { const l = levelOf(doc.line(n).text); if (l) last = l.rank; rank[n] = last; if (last >= want) kept++; }
        const name = query.slice(6).trim().toUpperCase();
        setFolds(view, 'level', runsWithout(doc, (n) => rank[n] >= want).map(([a, b]) => [a, b,
          tn('code.linesBelowLevel', b - a + 1, '{n} line below {level}', '{n} lines below {level}', { level: name })]));
        return { count: kept, index: -1, label: tn('code.linesAtLevel', kept, '{n} line at {level} or worse', '{n} lines at {level} or worse', { level: name }) };
      }
      setFolds(view, 'level', []);
      const q = new SearchQuery({ search: query, caseSensitive: false, literal: true });
      const changed = !this.lastQuery || !this.lastQuery.eq(q);
      if (changed) view.dispatch({ effects: setSearchQuery.of(q) });
      this.lastQuery = q;
      if (changed) view.dispatch({ selection: { anchor: 0 } });
      (forward || changed ? findNext : findPrevious)(view);
      let count = 0, index = -1;
      const at = view.state.selection.main.from;
      const cursor = q.getCursor(view.state);
      for (let m = cursor.next(); !m.done && count < 100000; m = cursor.next()) {
        if (m.value.from === at) index = count;
        count++;
      }
      return { count, index, searchedAll: count < 100000 };
    },
    clearFind() {
      showSymbols(null, null);
      this.lastSymbolQuery = null;
      foldToMatches(view, null, false);
      setFolds(view, 'level', []);
      this.lastQuery = null;
      view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: '' })) });
    },
    reveal(y) { if (typeof y === 'number') view.scrollDOM.scrollTop = y; },
    scrollTop() { return view.scrollDOM.scrollTop; },
    // A line of the file: scrolled to when it is in the window, else the window around it is asked for.
    goToLine(n) {
      const local = n - win.first + 1;
      if (win.on && (local < 1 || local > view.state.doc.lines)) { requestWindow(n, 0, true); return; }
      const line = view.state.doc.line(Math.max(1, Math.min(local, view.state.doc.lines)));
      view.dispatch({ selection: { anchor: line.from }, effects: EditorView.scrollIntoView(line.from, { y: 'center' }) });
    },
    // Swift's answer to a window request: the new lines replace the old, and the line that was at the top stays
    // where it was on screen (or, for a jump, the asked-for line is centred).
    setWindow(w) {
      Object.assign(win, { first: w.first, total: w.total, exact: w.exact });
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: w.text } });
      const doc = view.state.doc, local = Math.max(1, Math.min(w.line - w.first + 1, doc.lines));
      const pos = doc.line(local).from;
      if (w.reveal) {
        view.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: 'center' }) });
      } else {
        view.scrollDOM.scrollTop = Math.max(0, view.lineBlockAt(pos).top - (w.dy || 0));
      }
      win.pending = false;
      const banner = document.getElementById('vt-loading');
      if (banner) banner.style.display = 'none';
      if (this.lastQuery) view.dispatch({ effects: setSearchQuery.of(this.lastQuery) });
    },
    foldToMatches(on) { return foldToMatches(view, this.lastQuery, on); },
    showLog,
    logAnalysis() { return analysis; },
    symbolList() { if (!this.symbols) this.symbols = scanSymbols(highlighter, lang, view.state.doc); return this.symbols; },
    rulerMarks() { return Array.from(document.querySelectorAll('.vt-ruler i')).map((i) => i.className); },
    setTotal(total, exact) { win.total = total; win.exact = exact; },
    // Copy as image (state 2): the selected lines' band, full width, clipped to what is in view; nothing selected
    // is the view itself.
    selectionRect() {
      const s = view.scrollDOM.getBoundingClientRect();
      const r = view.state.selection.main;
      if (r.empty) return { x: s.left, y: s.top, w: s.width, h: s.height };
      const doc = view.state.doc;
      const a = view.coordsAtPos(doc.lineAt(r.from).from), b = view.coordsAtPos(doc.lineAt(r.to).to);
      const top = Math.max(s.top, a ? a.top : s.top), bottom = Math.min(s.bottom, b ? b.bottom : s.bottom);
      return { x: s.left, y: top - 4, w: s.width, h: Math.max(0, bottom - top) + 8 };
    },
    window() { return { first: win.first, lines: view.state.doc.lines, total: win.total, exact: win.exact, pending: win.pending }; },
    // A streaming find over a huge file (Swift reads the file): every match in the window is marked and the first
    // one on file line `n` is selected.
    markMatch(query, n) {
      const q = new SearchQuery({ search: query, caseSensitive: false, literal: true });
      if (!this.lastQuery || !this.lastQuery.eq(q)) view.dispatch({ effects: setSearchQuery.of(q) });
      this.lastQuery = q;
      const local = n - win.first + 1;
      if (local < 1 || local > view.state.doc.lines) return false;
      const line = view.state.doc.line(local);
      const cursor = q.getCursor(view.state, line.from, line.to);
      const m = cursor.next();
      const at = m.done ? line.from : m.value.from, to = m.done ? line.from : m.value.to;
      view.dispatch({ selection: { anchor: at, head: to }, effects: EditorView.scrollIntoView(at, { y: 'center' }) });
      return true;
    },
    stickyLines() { return Array.from(document.querySelectorAll('.vt-sticky-line')).map((e) => e.textContent); },
    colouredSpans() { return document.querySelectorAll('.cm-line span[style]').length; },
    language: lang,
  };
  // CodeMirror draws its first screen while it is constructed; no animation frame is waited for, because a web view
  // that is not on screen yet (Quick Look before it shows, snapshots, tests) never gets one.
  setTimeout(() => post('ready', { ms: Math.round(performance.now() - t0), lang }), 0);
}

start().catch((e) => post('error', { message: String(e && e.stack || e) }));
