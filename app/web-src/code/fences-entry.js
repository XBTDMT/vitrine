// Markdown's code blocks coloured by the same Shiki as the code view (S-4 note, S-5): each fenced block with a
// language is tokenized with that language's TextMate grammar and drawn in the Markdown theme's own five code colours
// (--sk keyword, --ss string, --sn number, --sc comment, --sf function and type; the rest in --fg, punctuation in
// --fg2). Bundled beside code.js (tools/vendor_web.sh code) and loaded by the Markdown page as
// vitrine://app/code/fences.js; grammars load only for the languages the document uses. roadmap: S-5
import { createHighlighterCore } from 'shiki/core';
import { createOnigurumaEngine } from 'shiki/engine/oniguruma';
import { bundledLanguages, bundledLanguagesAlias } from 'shiki/langs';
import { hex } from './appearance.js';

const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

// The page's theme as a TextMate theme; rebuilt when the "Aa" menu changes the Markdown theme.
function markdownTheme() {
  const c = (n) => hex(css(n)) || hex(css('--fg'));
  const rule = (scope, colour, fontStyle) => ({ scope, settings: { foreground: colour, ...(fontStyle ? { fontStyle } : {}) } });
  const name = 'md-' + [css('--sk'), css('--ss'), css('--sn'), css('--sc'), css('--sf'), css('--fg')].join('').replace(/[^0-9a-z]/gi, '');
  return {
    name, type: document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light',
    colors: { 'editor.foreground': c('--fg') },
    settings: [
      { settings: { foreground: c('--fg') } },
      rule(['comment', 'punctuation.definition.comment'], c('--sc'), 'italic'),
      rule(['string', 'string.quoted', 'string.template', 'punctuation.definition.string'], c('--ss')),
      rule(['constant.numeric', 'constant.language', 'constant', 'variable.other.constant', 'support.constant'], c('--sn')),
      rule(['keyword', 'storage', 'storage.type', 'storage.modifier', 'keyword.control', 'entity.name.tag'], c('--sk')),
      rule(['entity.name.function', 'support.function', 'entity.name.type', 'entity.name.class', 'support.type', 'support.class'], c('--sf')),
      rule(['punctuation', 'meta.brace', 'keyword.operator'], c('--fg2')),
    ],
  };
}

const MAX_BLOCK = 200 * 1024;
let highlighter = null;

async function colour(root) {
  const blocks = Array.from((root || document).querySelectorAll('.cb pre > code[class*="language-"]'))
    .filter((code) => !code.dataset.vtColoured && !code.classList.contains('language-mermaid') && code.textContent.length <= MAX_BLOCK);
  if (!blocks.length) return 0;
  const wanted = new Map();
  for (const code of blocks) {
    const name = (code.className.match(/language-([\w+#.-]+)/) || [])[1]?.toLowerCase();
    const id = bundledLanguages[name] ? name : bundledLanguagesAlias[name] ? name : null;
    if (id) wanted.set(code, id);
  }
  if (!wanted.size) return 0;
  const theme = markdownTheme();
  if (!highlighter) {
    highlighter = await createHighlighterCore({ themes: [theme], langs: [], engine: createOnigurumaEngine(import('shiki/wasm')) });
  } else if (!highlighter.getLoadedThemes().includes(theme.name)) {
    await highlighter.loadTheme(theme);
  }
  const langs = [...new Set(wanted.values())];
  await Promise.all(langs.map((l) => highlighter.getLoadedLanguages().includes(l) ? null
    : highlighter.loadLanguage(bundledLanguages[l] || bundledLanguagesAlias[l]).catch(() => null)));
  let done = 0;
  for (const [code, lang] of wanted) {
    if (!highlighter.getLoadedLanguages().includes(lang)) continue;
    const { tokens } = highlighter.codeToTokens(code.textContent, { lang, theme: theme.name });
    const frag = document.createDocumentFragment();
    tokens.forEach((line, i) => {
      for (const t of line) {
        const s = document.createElement('span');
        s.textContent = t.content;
        if (t.color) s.style.color = t.color;
        if (t.fontStyle & 1) s.style.fontStyle = 'italic';
        if (t.fontStyle & 2) s.style.fontWeight = '600';
        frag.append(s);
      }
      if (i < tokens.length - 1) frag.append('\n');
    });
    code.replaceChildren(frag);
    code.dataset.vtColoured = '1';
    done++;
  }
  return done;
}

// markdown.js calls this after each render (first paint, live reload, a theme change); it is also run once here,
// since this module may load after the first render.
window.vitrineFences = {
  colour,
  // A theme change redraws the page's text; blocks lose their marks and colour again in the new theme.
  recolour() { document.querySelectorAll('code[data-vt-coloured]').forEach((c) => { c.textContent = c.textContent; delete c.dataset.vtColoured; }); return colour(document); },
};
colour(document).then((n) => {
  try { window.webkit.messageHandlers.vitrine.postMessage({ name: 'fences', body: n }); } catch (e) { /* not in Vitrine */ }
});
