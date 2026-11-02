// Code appearance (code design state 15; C-2, C-4, I-14): 24 built-in themes that follow light and dark, an imported
// editor theme, and the display options (font, size, line height, tab width, wrap, line numbers, indent guides,
// changed lines, sticky scope, minimap). The popover opens from the capsule's More button; every change applies at
// once and is kept by Swift for the next file. roadmap: S-5

import { t, num } from './strings.js';

const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
// Shiki's colour map takes hex only: `rgba(60,60,67,.62)` becomes `#3c3c439e`, a hex colour is kept as it is.
export const hex = (value) => {
  const m = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$/i.exec(value);
  if (!m) return value;
  const h = (n) => Math.round(Number(n)).toString(16).padStart(2, '0');
  return '#' + h(m[1]) + h(m[2]) + h(m[3]) + (m[4] === undefined ? '' : h(Number(m[4]) * 255));
};

// One TextMate theme from a palette of the unified syntax roles (G14): com, str, num, bool, const, kw, fn, ty, prop,
// key, attr, punct.
function themeFrom(name, type, bg, fg, c) {
  const rule = (scope, token, fontStyle) => ({ scope, settings: { foreground: c[token], ...(fontStyle ? { fontStyle } : {}) } });
  return {
    name, type,
    colors: { 'editor.foreground': fg, 'editor.background': bg },
    settings: [
      { settings: { foreground: fg } },
      rule(['comment', 'punctuation.definition.comment'], 'com', 'italic'),
      rule(['string', 'string.quoted', 'string.template', 'punctuation.definition.string'], 'str'),
      rule(['constant.numeric'], 'num'),
      rule(['constant.language.boolean', 'constant.language.null', 'constant.language'], 'bool'),
      rule(['constant', 'variable.other.constant', 'support.constant'], 'const'),
      rule(['keyword', 'storage', 'storage.type', 'storage.modifier', 'keyword.control', 'keyword.operator.new'], 'kw'),
      rule(['entity.name.function', 'support.function', 'meta.function-call entity.name.function'], 'fn'),
      rule(['entity.name.type', 'entity.name.class', 'support.type', 'support.class', 'entity.other.inherited-class',
            'storage.type.primitive', 'meta.type.annotation entity.name.type'], 'ty'),
      rule(['variable.other.property', 'variable.other.object.property', 'support.variable.property', 'meta.property-name'], 'prop'),
      rule(['support.type.property-name', 'meta.object-literal.key', 'entity.name.tag.yaml', 'meta.mapping.key'], 'key'),
      rule(['entity.other.attribute-name', 'meta.attribute', 'entity.name.function.decorator'], 'attr'),
      rule(['entity.name.tag'], 'kw'),
      rule(['punctuation', 'meta.brace', 'keyword.operator'], 'punct'),
    ],
  };
}

// The unified syntax palette, read from the page's `--v-syn-*` tokens (it follows the Mac's appearance).
function vitrineTheme() {
  const roles = ['com', 'str', 'num', 'bool', 'const', 'kw', 'fn', 'ty', 'prop', 'key', 'attr', 'punct'];
  const c = Object.fromEntries(roles.map((r) => [r, hex(css('--v-syn-' + r))]));
  return themeFrom('vitrine', document.documentElement.dataset.appearance === 'dark' ? 'dark' : 'light',
    hex(css('--v-page')), hex(css('--v-t1')), c);
}

// Vitrine's own themes. Ground, text, keyword and string are the approved swatches (design/mockups/unified/code.html
// state 15); the other roles are drawn to sit with them.
const OWN = {
  porcelain: () => themeFrom('porcelain', 'light', '#FAF8F4', '#2B2A28', {
    com: '#8A857C', str: '#A3521F', num: '#2F6A8F', bool: '#2F6A8F', const: '#2F6A8F', kw: '#7A4FB5', fn: '#3D6B3A',
    ty: '#8C5A12', prop: '#5A4E3F', key: '#3D6B3A', attr: '#7A4FB5', punct: '#6B6760' }),
  graphite: () => themeFrom('graphite', 'dark', '#26272B', '#E6E6EA', {
    com: '#8E8F98', str: '#F0A979', num: '#8CC8E8', bool: '#8CC8E8', const: '#8CC8E8', kw: '#C49BF0', fn: '#9FD69A',
    ty: '#F2D07E', prop: '#C9CAD3', key: '#9FD69A', attr: '#C49BF0', punct: '#A3A4AD' }),
  harbor: () => themeFrom('harbor', 'light', '#F2F7FA', '#18323F', {
    com: '#6E8794', str: '#B5532A', num: '#7A4BA8', bool: '#7A4BA8', const: '#7A4BA8', kw: '#1F6E8C', fn: '#2B7A5B',
    ty: '#9A5B0F', prop: '#2E4C5A', key: '#2B7A5B', attr: '#1F6E8C', punct: '#557380' }),
  ember: () => themeFrom('ember', 'dark', '#1E1A18', '#EDE3DA', {
    com: '#93857B', str: '#E8C26B', num: '#B9A3F0', bool: '#B9A3F0', const: '#B9A3F0', kw: '#F08C5A', fn: '#9ED29A',
    ty: '#F2B37A', prop: '#D9CCC1', key: '#9ED29A', attr: '#F08C5A', punct: '#AD9F94' }),
};

// The editor themes Shiki ships (VS Code's own theme files, MIT), each its own chunk, loaded when picked or shown.
const SHIKI = {
  'github-light': () => import('@shikijs/themes/github-light'), 'github-dark': () => import('@shikijs/themes/github-dark'),
  'github-light-high-contrast': () => import('@shikijs/themes/github-light-high-contrast'),
  'github-dark-high-contrast': () => import('@shikijs/themes/github-dark-high-contrast'),
  'light-plus': () => import('@shikijs/themes/light-plus'), 'dark-plus': () => import('@shikijs/themes/dark-plus'),
  'one-light': () => import('@shikijs/themes/one-light'), 'one-dark-pro': () => import('@shikijs/themes/one-dark-pro'),
  'solarized-light': () => import('@shikijs/themes/solarized-light'), 'solarized-dark': () => import('@shikijs/themes/solarized-dark'),
  'catppuccin-latte': () => import('@shikijs/themes/catppuccin-latte'), 'catppuccin-mocha': () => import('@shikijs/themes/catppuccin-mocha'),
  'rose-pine-dawn': () => import('@shikijs/themes/rose-pine-dawn'), 'rose-pine': () => import('@shikijs/themes/rose-pine'),
  'vitesse-light': () => import('@shikijs/themes/vitesse-light'), 'vitesse-dark': () => import('@shikijs/themes/vitesse-dark'),
  'gruvbox-light-medium': () => import('@shikijs/themes/gruvbox-light-medium'), 'gruvbox-dark-medium': () => import('@shikijs/themes/gruvbox-dark-medium'),
  'everforest-light': () => import('@shikijs/themes/everforest-light'), 'everforest-dark': () => import('@shikijs/themes/everforest-dark'),
  'ayu-light': () => import('@shikijs/themes/ayu-light'), 'ayu-mirage': () => import('@shikijs/themes/ayu-mirage'),
  'kanagawa-lotus': () => import('@shikijs/themes/kanagawa-lotus'), 'kanagawa-wave': () => import('@shikijs/themes/kanagawa-wave'),
  'night-owl-light': () => import('@shikijs/themes/night-owl-light'), 'night-owl': () => import('@shikijs/themes/night-owl'),
  'min-light': () => import('@shikijs/themes/min-light'), 'min-dark': () => import('@shikijs/themes/min-dark'),
  'material-theme-lighter': () => import('@shikijs/themes/material-theme-lighter'), 'material-theme-darker': () => import('@shikijs/themes/material-theme-darker'),
  dracula: () => import('@shikijs/themes/dracula'), nord: () => import('@shikijs/themes/nord'),
  'tokyo-night': () => import('@shikijs/themes/tokyo-night'), monokai: () => import('@shikijs/themes/monokai'),
  'github-light-default': () => import('@shikijs/themes/github-light-default'),
  'github-dark-default': () => import('@shikijs/themes/github-dark-default'),
  'github-dark-dimmed': () => import('@shikijs/themes/github-dark-dimmed'),
  'horizon-bright': () => import('@shikijs/themes/horizon-bright'),
  'horizon': () => import('@shikijs/themes/horizon'),
  'slack-ochin': () => import('@shikijs/themes/slack-ochin'),
  'slack-dark': () => import('@shikijs/themes/slack-dark'),
  'rose-pine-moon': () => import('@shikijs/themes/rose-pine-moon'),
  'catppuccin-frappe': () => import('@shikijs/themes/catppuccin-frappe'),
  'catppuccin-macchiato': () => import('@shikijs/themes/catppuccin-macchiato'),
  'kanagawa-dragon': () => import('@shikijs/themes/kanagawa-dragon'),
  'gruvbox-light-hard': () => import('@shikijs/themes/gruvbox-light-hard'),
  'gruvbox-dark-hard': () => import('@shikijs/themes/gruvbox-dark-hard'),
  'gruvbox-light-soft': () => import('@shikijs/themes/gruvbox-light-soft'),
  'gruvbox-dark-soft': () => import('@shikijs/themes/gruvbox-dark-soft'),
  'ayu-dark': () => import('@shikijs/themes/ayu-dark'),
  'vitesse-black': () => import('@shikijs/themes/vitesse-black'),
  'material-theme-ocean': () => import('@shikijs/themes/material-theme-ocean'),
  'material-theme-palenight': () => import('@shikijs/themes/material-theme-palenight'),
  'material-theme': () => import('@shikijs/themes/material-theme'),
  'dracula-soft': () => import('@shikijs/themes/dracula-soft'),
  'poimandres': () => import('@shikijs/themes/poimandres'),
  'vesper': () => import('@shikijs/themes/vesper'),
  'houston': () => import('@shikijs/themes/houston'),
  'synthwave-84': () => import('@shikijs/themes/synthwave-84'),
  'snazzy-light': () => import('@shikijs/themes/snazzy-light'),
  'andromeeda': () => import('@shikijs/themes/andromeeda'),
  'aurora-x': () => import('@shikijs/themes/aurora-x'),
  'laserwave': () => import('@shikijs/themes/laserwave'),
  'plastic': () => import('@shikijs/themes/plastic'),
};

// The 24 built-in choices. A pair follows the Mac's light and dark; a single theme stays as it is.
export const BUILT_IN = [
  { id: 'vitrine', name: 'Vitrine (auto)', light: 'vitrine', dark: 'vitrine' },
  { id: 'porcelain', name: 'Porcelain', light: 'porcelain', dark: 'porcelain' },
  { id: 'graphite', name: 'Graphite', light: 'graphite', dark: 'graphite' },
  { id: 'harbor', name: 'Harbor', light: 'harbor', dark: 'harbor' },
  { id: 'ember', name: 'Ember', light: 'ember', dark: 'ember' },
  { id: 'github', name: 'GitHub', light: 'github-light', dark: 'github-dark' },
  { id: 'github-hc', name: 'GitHub High Contrast', light: 'github-light-high-contrast', dark: 'github-dark-high-contrast' },
  { id: 'vscode', name: 'VS Code', light: 'light-plus', dark: 'dark-plus' },
  { id: 'one', name: 'One', light: 'one-light', dark: 'one-dark-pro' },
  { id: 'solarized', name: 'Solarized', light: 'solarized-light', dark: 'solarized-dark' },
  { id: 'catppuccin', name: 'Catppuccin', light: 'catppuccin-latte', dark: 'catppuccin-mocha' },
  { id: 'rose-pine', name: 'Rosé Pine', light: 'rose-pine-dawn', dark: 'rose-pine' },
  { id: 'vitesse', name: 'Vitesse', light: 'vitesse-light', dark: 'vitesse-dark' },
  { id: 'gruvbox', name: 'Gruvbox', light: 'gruvbox-light-medium', dark: 'gruvbox-dark-medium' },
  { id: 'everforest', name: 'Everforest', light: 'everforest-light', dark: 'everforest-dark' },
  { id: 'ayu', name: 'Ayu', light: 'ayu-light', dark: 'ayu-mirage' },
  { id: 'kanagawa', name: 'Kanagawa', light: 'kanagawa-lotus', dark: 'kanagawa-wave' },
  { id: 'night-owl', name: 'Night Owl', light: 'night-owl-light', dark: 'night-owl' },
  { id: 'min', name: 'Min', light: 'min-light', dark: 'min-dark' },
  { id: 'material', name: 'Material', light: 'material-theme-lighter', dark: 'material-theme-darker' },
  { id: 'dracula', name: 'Dracula', light: 'dracula', dark: 'dracula' },
  { id: 'nord', name: 'Nord', light: 'nord', dark: 'nord' },
  { id: 'tokyo-night', name: 'Tokyo Night', light: 'tokyo-night', dark: 'tokyo-night' },
  { id: 'monokai', name: 'Monokai', light: 'monokai', dark: 'monokai' },
];

// "More themes" in the popover: the rest of Shiki's set, so the whole is past the parity target's 38 (C-2).
export const MORE = [
  { id: 'github-default', name: 'GitHub Default', light: 'github-light-default', dark: 'github-dark-default' },
  { id: 'github-dimmed', name: 'GitHub Dimmed', light: 'github-dark-dimmed', dark: 'github-dark-dimmed' },
  { id: 'horizon', name: 'Horizon', light: 'horizon-bright', dark: 'horizon' },
  { id: 'slack', name: 'Slack', light: 'slack-ochin', dark: 'slack-dark' },
  { id: 'rose-pine-moon', name: 'Rosé Pine Moon', light: 'rose-pine-moon', dark: 'rose-pine-moon' },
  { id: 'catppuccin-frappe', name: 'Catppuccin Frappé', light: 'catppuccin-frappe', dark: 'catppuccin-frappe' },
  { id: 'catppuccin-macchiato', name: 'Catppuccin Macchiato', light: 'catppuccin-macchiato', dark: 'catppuccin-macchiato' },
  { id: 'kanagawa-dragon', name: 'Kanagawa Dragon', light: 'kanagawa-dragon', dark: 'kanagawa-dragon' },
  { id: 'gruvbox-hard', name: 'Gruvbox Hard', light: 'gruvbox-light-hard', dark: 'gruvbox-dark-hard' },
  { id: 'gruvbox-soft', name: 'Gruvbox Soft', light: 'gruvbox-light-soft', dark: 'gruvbox-dark-soft' },
  { id: 'ayu-dark', name: 'Ayu Dark', light: 'ayu-dark', dark: 'ayu-dark' },
  { id: 'vitesse-black', name: 'Vitesse Black', light: 'vitesse-black', dark: 'vitesse-black' },
  { id: 'material-ocean', name: 'Material Ocean', light: 'material-theme-ocean', dark: 'material-theme-ocean' },
  { id: 'material-palenight', name: 'Material Palenight', light: 'material-theme-palenight', dark: 'material-theme-palenight' },
  { id: 'dracula-soft', name: 'Dracula Soft', light: 'dracula-soft', dark: 'dracula-soft' },
  { id: 'poimandres', name: 'Poimandres', light: 'poimandres', dark: 'poimandres' },
  { id: 'vesper', name: 'Vesper', light: 'vesper', dark: 'vesper' },
  { id: 'houston', name: 'Houston', light: 'houston', dark: 'houston' },
  { id: 'synthwave-84', name: 'Synthwave ’84', light: 'synthwave-84', dark: 'synthwave-84' },
  { id: 'snazzy', name: 'Snazzy Light', light: 'snazzy-light', dark: 'snazzy-light' },
  { id: 'andromeeda', name: 'Andromeeda', light: 'andromeeda', dark: 'andromeeda' },
  { id: 'aurora-x', name: 'Aurora X', light: 'aurora-x', dark: 'aurora-x' },
  { id: 'laserwave', name: 'Laserwave', light: 'laserwave', dark: 'laserwave' },
  { id: 'plastic', name: 'Plastic', light: 'plastic', dark: 'plastic' },
];

const dark = () => document.documentElement.dataset.appearance === 'dark';

// The TextMate theme object for one choice in the current appearance; imported themes come from Swift already in
// Shiki's form (name, type, colors, tokenColors).
export async function loadTheme(choice, imported) {
  const own = imported.find((t) => t.id === choice);
  if (own) return { ...own.theme, name: 'imported-' + own.id };
  const entry = BUILT_IN.find((t) => t.id === choice) || MORE.find((t) => t.id === choice) || BUILT_IN[0];
  const id = dark() ? entry.dark : entry.light;
  if (id === 'vitrine') return vitrineTheme();
  if (OWN[id]) return OWN[id]();
  return (await SHIKI[id]()).default;
}

// The colours a theme gives the page around the code: ground, text, line numbers, selection.
export function chromeColours(theme) {
  const c = theme.colors || {};
  const fg = c['editor.foreground'] || (theme.type === 'dark' ? '#E6E6EA' : '#1D1D1F');
  return {
    bg: c['editor.background'] || (theme.type === 'dark' ? '#1E1E20' : '#FFFFFF'),
    fg,
    gutter: c['editorLineNumber.foreground'] || fg + '73',
    active: c['editorLineNumber.activeForeground'] || fg,
    sel: c['editor.selectionBackground'] || (theme.type === 'dark' ? '#3E4451' : '#ADD6FF80'),
    guide: c['editorIndentGuide.background1'] || c['editorIndentGuide.background'] || fg + '1F',
  };
}

// Keyword and string colours for a theme's tile (`const a = "x"`), read from its rules.
function swatch(theme) {
  const rules = theme.tokenColors || theme.settings || [];
  const find = (want) => {
    for (const r of rules) {
      const scopes = [].concat(r.scope || []).flatMap((s) => String(s).split(','));
      if (scopes.some((s) => want.some((w) => s.trim() === w || s.trim().startsWith(w + '.'))) && r.settings?.foreground) return r.settings.foreground;
    }
    return null;
  };
  const ch = chromeColours(theme);
  return { bg: ch.bg, fg: ch.fg, k: find(['storage.type', 'keyword', 'storage']) || ch.fg, s: find(['string']) || ch.fg };
}

// MARK: The popover

const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

// Opens (or closes) the Code appearance popover above the capsule's right end. `opts` is the current settings;
// `onChange(key, value)` applies and keeps one.
export async function togglePopover(opts, imported, fonts, onChange) {
  const open = document.getElementById('vt-tpop');
  if (open) { open.remove(); return false; }
  const pop = el('div', 'vt-tpop');
  pop.id = 'vt-tpop';
  pop.setAttribute('role', 'dialog');
  pop.setAttribute('aria-label', t('code.appearance', 'Code appearance'));
  pop.append(el('h6', null, t('code.appearance', 'Code appearance')));

  const grid = el('div', 'vt-thg');
  const moreGrid = el('div', 'vt-thg vt-more');
  // Theme names are names (Dracula, Nord), never translated; only Vitrine's automatic one says what it does.
  const shown = (ch) => (ch.id === 'vitrine' ? t('code.autoTheme', ch.name) : ch.name);
  const choices = [...BUILT_IN, ...imported.map((it) => ({ id: it.id, name: t('code.imported', '{name} · imported', { name: it.name }) }))];
  const addTile = (ch, into) => {
    const tile = el('button', 'vt-thw' + (ch.id === opts.theme ? ' on' : ''));
    tile.type = 'button';
    tile.dataset.theme = ch.id;
    tile.title = shown(ch);
    // A code sample, never translated.
    const code = el('span', 'vt-thc');
    const k = el('span', null, 'const'), s = el('span', null, '"x"');
    code.append(k, ' a = ', s);
    tile.append(code, el('span', 'vt-thn', shown(ch)));
    tile.addEventListener('click', () => {
      pop.querySelectorAll('.vt-thw.on').forEach((t) => t.classList.remove('on'));
      tile.classList.add('on');
      onChange('theme', ch.id);
    });
    into.append(tile);
    loadTheme(ch.id, imported).then((theme) => {
      const sw = swatch(theme);
      tile.style.background = sw.bg; tile.style.color = sw.fg; k.style.color = sw.k; s.style.color = sw.s;
    }).catch(() => {});
  };
  choices.forEach((ch) => addTile(ch, grid));
  pop.append(grid);
  // The rest of the set, drawn only when opened (each tile loads its theme).
  const moreOpen = MORE.some((t) => t.id === opts.theme);
  const moreLabel = (isOpen) => (isOpen ? t('code.fewerThemes', 'Fewer themes ({n})', { n: num(MORE.length) })
    : t('code.moreThemes', 'More themes ({n})', { n: num(MORE.length) }));
  const more = el('button', 'vt-btn vt-morebtn', moreLabel(moreOpen));
  more.type = 'button';
  const fillMore = () => { if (!moreGrid.childElementCount) MORE.forEach((ch) => addTile(ch, moreGrid)); };
  moreGrid.style.display = moreOpen ? 'grid' : 'none';
  if (moreOpen) fillMore();
  more.addEventListener('click', () => {
    const open = moreGrid.style.display === 'none';
    if (open) fillMore();
    moreGrid.style.display = open ? 'grid' : 'none';
    more.textContent = moreLabel(open);
  });
  pop.append(more, moreGrid);

  const row = (label, control) => { const r = el('div', 'vt-orow'); r.append(el('span', 'vt-olab', label), control); return r; };
  const segmented = (key, items) => {
    const seg = el('div', 'vt-seg');
    for (const [value, title] of items) {
      const b = el('button', value === opts[key] ? 'on' : '', title);
      b.type = 'button';
      b.addEventListener('click', () => {
        seg.querySelectorAll('.on').forEach((x) => x.classList.remove('on'));
        b.classList.add('on');
        onChange(key, value);
      });
      seg.append(b);
    }
    return seg;
  };

  const font = el('div', 'vt-font');
  const family = el('select');
  for (const f of fonts) { const o = el('option', null, f); o.value = f; o.selected = f === opts.font; family.append(o); }
  family.addEventListener('change', () => onChange('font', family.value));
  const pt = (n) => t('code.pt', '{size} pt', { size: num(n) });
  const size = el('span', 'vt-size', pt(opts.fontSize));
  const step = (d) => {
    const b = el('button', 'vt-step', d < 0 ? '−' : '+');
    b.type = 'button';
    b.title = d < 0 ? t('code.smaller', 'Smaller') : t('code.larger', 'Larger');
    b.addEventListener('click', () => {
      opts.fontSize = Math.max(9, Math.min(24, opts.fontSize + d));
      size.textContent = pt(opts.fontSize);
      onChange('fontSize', opts.fontSize);
    });
    return b;
  };
  font.append(family, step(-1), size, step(1));
  pop.append(row(t('code.font', 'Font'), font));
  pop.append(row(t('code.lineHeight', 'Line height'), segmented('lineHeight', [['tight', t('code.tight', 'Tight')],
    ['normal', t('code.normal', 'Normal')], ['roomy', t('code.roomy', 'Roomy')]])));
  pop.append(row(t('code.tabWidth', 'Tab width'), segmented('tabSize', [[2, num(2)], [4, num(4)], [8, num(8)]])));

  const toggles = el('div', 'vt-togs');
  for (const [key, title] of [['wrap', t('code.wrap', 'Wrap lines')], ['lineNumbers', t('code.lineNumbers', 'Line numbers')],
    ['indentGuides', t('code.indentGuides', 'Indent guides')], ['changedLines', t('code.changedLines', 'Changed lines')],
    ['sticky', t('code.sticky', 'Sticky scope')], ['minimap', t('code.minimap', 'Minimap')]]) {
    const label = el('label', 'vt-tog');
    const box = el('input');
    box.type = 'checkbox';
    box.checked = !!opts[key];
    box.addEventListener('change', () => onChange(key, box.checked));
    label.append(box, el('span', null, title));
    toggles.append(label);
  }
  pop.append(toggles);

  const foot = el('div', 'vt-ofoot');
  const imp = el('button', 'vt-btn', t('code.importTheme', 'Import theme…'));
  imp.type = 'button';
  imp.addEventListener('click', () => onChange('importTheme', true));
  foot.append(imp, el('span', 'vt-onote', t('code.importNote', 'VS Code, Zed or TextMate · {n} built in · stays on this Mac',
    { n: num(BUILT_IN.length + MORE.length) })));
  pop.append(foot);

  document.body.append(pop);
  const close = (e) => {
    if (e.type === 'keydown' && e.key !== 'Escape') return;
    if (e.type === 'mousedown' && pop.contains(e.target)) return;
    pop.remove();
    document.removeEventListener('mousedown', close, true);
    document.removeEventListener('keydown', close, true);
  };
  setTimeout(() => { document.addEventListener('mousedown', close, true); document.addEventListener('keydown', close, true); }, 0);
  return true;
}
