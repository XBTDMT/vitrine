// The page's words (H-6, S-12). Swift puts one JSON object of already-localized strings in
// <script type="application/json" id="vt-strings"> (PageStrings.swift); every lookup falls back to the English given
// here, so a page without the block still reads. `{name}` in a string is filled from `args`; a counted phrase is an
// object of templates per plural category, picked with Intl.PluralRules in the strings' language. roadmap: S-12
let table = null;
const load = () => {
  if (table) return table;
  try { table = JSON.parse(document.getElementById('vt-strings')?.textContent || '{}') || {}; } catch (e) { table = {}; }
  return table;
};

// The person's locale for numbers (from Swift); undefined = WebKit's own.
export const locale = () => load()._locale || undefined;
export const num = (n) => Number(n).toLocaleString(locale());
export const percent = (fraction) => Number(fraction).toLocaleString(locale(), { style: 'percent', maximumFractionDigits: 0 });

const fill = (s, args) => (args ? s.replace(/\{(\w+)\}/g, (m, k) => (k in args ? String(args[k]) : m)) : s);

export function t(key, fallback, args) {
  const v = load()[key];
  return fill(typeof v === 'string' ? v : fallback, args);
}

let rules = null;
// A counted phrase: `one` and `other` are the English fallbacks, each with {n}.
export function tn(key, n, one, other, args) {
  const v = load()[key];
  let s = null;
  if (v && typeof v === 'object') {
    try { rules = rules || new Intl.PluralRules(load()._lang || 'en'); s = v[rules.select(n)] || v.other; } catch (e) { s = v.other; }
  }
  if (typeof s !== 'string') s = n === 1 ? one : other;
  return fill(s, Object.assign({ n: num(n) }, args));
}
