// The log view (code design state 11, E-7): level tags in their colours, runs of near-identical lines folded into
// one row ("×38 retrying connection (attempt 3 … 40) over 41 s"), and silences of a minute or more marked between
// lines ("4 min 12 s with no lines"). `level:warn` in find keeps WARN and worse. roadmap: S-5
import { ViewPlugin, Decoration, WidgetType, EditorView } from '@codemirror/view';
import { StateField, RangeSetBuilder } from '@codemirror/state';
import { t, num } from './strings.js';

const LEVELS = { trace: 0, debug: 1, info: 2, notice: 2, warn: 3, warning: 3, error: 4, err: 4, fatal: 5, critical: 5, crit: 5, panic: 5 };
const LEVEL_RE = /(^|[\s\[|(])(TRACE|DEBUG|INFO|NOTICE|WARN|WARNING|ERROR|ERR|FATAL|CRITICAL|CRIT|PANIC|trace|debug|info|notice|warn|warning|error|fatal|critical)(?=[\s\]|):]|$)/;
// A timestamp at the start: 2026-10-30T09:41:02.118Z, 2026-10-30 09:41:02,118, [09:41:02], Oct 30 09:41:02.
const TIME_RE = /^\[?(?:(\d{4})-(\d{2})-(\d{2})[T ])?(?:[A-Z][a-z]{2} +\d{1,2} )?(\d{2}):(\d{2}):(\d{2})(?:[.,](\d{1,6}))?/;

export function levelOf(text) {
  const head = text.slice(0, 80);
  const m = LEVEL_RE.exec(head);
  if (!m) return null;
  const word = m[2].toLowerCase();
  return { word: m[2], rank: LEVELS[word], from: m.index + m[1].length, to: m.index + m[1].length + m[2].length,
    name: word === 'warning' ? 'warn' : word === 'err' ? 'error' : (word === 'critical' || word === 'crit' || word === 'panic') ? 'fatal' : word };
}

export function timeOf(text) {
  const m = TIME_RE.exec(text);
  if (!m) return null;
  const day = m[1] ? Date.UTC(+m[1], +m[2] - 1, +m[3]) / 1000 : 0;
  return { seconds: day + (+m[4]) * 3600 + (+m[5]) * 60 + (+m[6]) + (m[7] ? Number('0.' + m[7]) : 0), length: m[0].length };
}

// The words of a line that say what happened: no timestamp, no level, numbers as #.
const shape = (text) => {
  const t = timeOf(text);
  let rest = t ? text.slice(t.length) : text;
  const l = levelOf(rest);
  if (l) rest = rest.slice(l.to);
  return rest.replace(/\d+/g, '#').trim();
};
const message = (text) => {
  const t = timeOf(text);
  let rest = t ? text.slice(t.length) : text;
  const l = levelOf(rest);
  if (l) rest = rest.slice(l.to);
  return rest.trim();
};

export const duration = (s) => {
  s = Math.round(s);
  if (s < 60) return t('code.dur.s', '{s} s', { s: num(s) });
  if (s < 3600) {
    const m = Math.floor(s / 60);
    return s % 60 ? t('code.dur.ms', '{m} min {s} s', { m: num(m), s: num(s % 60) }) : t('code.dur.m', '{m} min', { m: num(m) });
  }
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
  return m ? t('code.dur.hm', '{h} h {m} min', { h: num(h), m: num(m) }) : t('code.dur.h', '{h} h', { h: num(h) });
};

// "retrying connection (attempt 3 … 40)": the first folded line's words, with each number that changes across the
// run written as its first and last value.
function rangeText(first, last) {
  const a = message(first), b = message(last);
  const na = a.match(/\d+/g) || [], nb = b.match(/\d+/g) || [];
  let i = 0;
  return a.replace(/\d+/g, (d) => { const other = nb[i++]; return other !== undefined && other !== d && na.length === nb.length ? d + ' … ' + other : d; });
}

// Everything the log view draws, from the document: level marks, silences, folded runs, counts.
export function analyzeLog(doc, gapSeconds = 60) {
  const levels = [], gaps = [], runs = [];
  let errors = 0, warnings = 0, prevTime = null, runStart = 1, runShape = null;
  const closeRun = (end) => {
    // A run of three or more lines with the same shape: the first stays, the rest fold.
    if (runShape !== null && end - runStart + 1 >= 3) {
      const t1 = timeOf(doc.line(runStart + 1).text), t2 = timeOf(doc.line(end).text);
      runs.push({ from: runStart + 1, to: end, count: end - runStart, text: rangeText(doc.line(runStart + 1).text, doc.line(end).text),
        span: t1 && t2 ? t2.seconds - t1.seconds : null });
    }
  };
  for (let n = 1; n <= doc.lines; n++) {
    const text = doc.line(n).text;
    const l = levelOf(text);
    if (l) {
      levels.push({ line: n, from: l.from, to: l.to, name: l.name, rank: l.rank });
      if (l.rank >= 4) errors++; else if (l.rank === 3) warnings++;
    }
    const t = timeOf(text);
    if (t) {
      if (prevTime !== null && t.seconds - prevTime >= gapSeconds) gaps.push({ line: n, seconds: t.seconds - prevTime });
      prevTime = t.seconds;
    }
    const s = text.trim() ? shape(text) : null;
    if (s !== null && s === runShape) continue;
    closeRun(n - 1);
    runStart = n; runShape = s;
  }
  closeRun(doc.lines);
  return { levels, gaps, runs, errors, warnings };
}

class GapWidget extends WidgetType {
  constructor(seconds) { super(); this.seconds = seconds; }
  eq(o) { return o.seconds === this.seconds; }
  toDOM() {
    const d = document.createElement('div'); d.className = 'vt-gap';
    d.textContent = t('code.gap', '{duration} with no lines', { duration: duration(this.seconds) });
    return d;
  }
}

// The log extensions for one analysis: level colours (a view plugin, visible lines only) and silences (block
// widgets, which only a state field may provide).
export function logExtensions(analysis) {
  const byLine = new Map(analysis.levels.map((l) => [l.line, l]));
  const marks = {};
  const mark = (name) => marks[name] || (marks[name] = Decoration.mark({ class: 'vt-lv vt-lv-' + name }));
  const levelColours = ViewPlugin.fromClass(class {
    constructor(view) { this.decorations = this.build(view); }
    update(u) { if (u.viewportChanged || u.docChanged) this.decorations = this.build(u.view); }
    build(view) {
      const b = new RangeSetBuilder(), doc = view.state.doc;
      for (const { from, to } of view.visibleRanges) {
        for (let n = doc.lineAt(from).number, last = doc.lineAt(to).number; n <= last; n++) {
          const l = byLine.get(n);
          if (l) { const start = doc.line(n).from; b.add(start + l.from, start + l.to, mark(l.name)); }
        }
      }
      return b.finish();
    }
  }, { decorations: (v) => v.decorations });
  const silences = StateField.define({
    create(state) {
      const b = new RangeSetBuilder();
      for (const g of analysis.gaps) {
        if (g.line <= state.doc.lines) b.add(state.doc.line(g.line).from, state.doc.line(g.line).from, Decoration.widget({ widget: new GapWidget(g.seconds), block: true, side: -1 }));
      }
      return b.finish();
    },
    update(value, tr) { return tr.docChanged ? value.map(tr.changes) : value; },
    provide: (f) => EditorView.decorations.from(f),
  });
  return [levelColours, silences];
}

// The placeholder text for a folded run.
export function runLabel(run) {
  const args = { count: num(run.count), text: run.text };
  return run.span != null && run.span > 0
    ? t('code.runOver', '×{count} {text} over {duration}', Object.assign(args, { duration: duration(run.span) }))
    : t('code.run', '×{count} {text}', args);
}
