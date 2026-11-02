# Third-party notices

roadmap: S-17

Vitrine is built from its own code plus the components below. Each one is listed with the licence named in the
file shipped with it, the version, where its licence text lives in this repository and where it came from. Every
licence text named here also ships inside the app, in `Vitrine.app/Contents/Frameworks/VitrinePreviewKit.framework/Resources/web/`
(the web libraries next to their code, the native libraries in `web/licenses/`); the tiktoken notice ships beside
the data file it describes.

Nothing below is downloaded when Vitrine runs, except the data in the last section, and only after you turn it on.

## Bundled in the app

### Web libraries (drawn inside the locked preview pages)

All paths in this section are under `app/VitrinePreviewKit/Resources/web/`.

| component | version | licence (as written in its file) | licence file | source |
|---|---|---|---|---|
| KaTeX (math in Markdown), with its 20 KaTeX_*.woff2 fonts | 0.16.22 | "The MIT License (MIT) — Copyright (c) 2013-2020 Khan Academy and other contributors" | `vendor/katex/LICENSE` | npm `katex@0.16.22` (https://github.com/KaTeX/KaTeX) |
| Mermaid (diagrams in Markdown) | 12.2.0 | "The MIT License (MIT) — Copyright (c) 2014 - 2022 Knut Sveidqvist" | `vendor/mermaid/LICENSE` | npm `mermaid@12.2.0` (https://github.com/mermaid-js/mermaid) |
| Mermaid's own dependencies, compiled into `mermaid.min.js` | see [below](#inside-the-mermaid-bundle) | MIT, ISC, BSD-3-Clause, Apache-2.0, MPL-2.0 or Apache-2.0 (DOMPurify), EPL-2.0 (elkjs), Unlicense | `vendor/mermaid/licenses/` | listed below |
| CodeMirror `@codemirror/view` | 6.43.15 | "MIT License — Copyright (C) 2018-2021 by Marijn Haverbeke and others" | `code/licenses/_codemirror_view-LICENSE` | npm (https://github.com/codemirror/view) |
| CodeMirror `@codemirror/state` | 6.7.6 | same MIT text | `code/licenses/_codemirror_state-LICENSE` | npm (https://github.com/codemirror/state) |
| CodeMirror `@codemirror/language` | 6.13.1 | same MIT text | `code/licenses/_codemirror_language-LICENSE` | npm (https://github.com/codemirror/language) |
| CodeMirror `@codemirror/search` | 6.7.2 | same MIT text | `code/licenses/_codemirror_search-LICENSE` | npm (https://github.com/codemirror/search) |
| Shiki (`shiki`, `@shikijs/core`, `@shikijs/engine-oniguruma`, `@shikijs/langs`, `@shikijs/themes`) | 4.5.0 | "MIT License — Copyright (c) 2021 Pine Wu" | `code/licenses/shiki-LICENSE`, `_shikijs_core-LICENSE`, `_shikijs_engine-oniguruma-LICENSE`, `_shikijs_langs-LICENSE`, `_shikijs_themes-LICENSE` | npm (https://github.com/shikijs/shiki) |
| `@shikijs/vscode-textmate` | 10.1.0 | "The MIT License (MIT) — Copyright (c) Microsoft Corporation" | `code/licenses/_shikijs_vscode-textmate-LICENSE` | npm (https://github.com/shikijs/vscode-textmate) |
| The code view's other dependencies, compiled into the code view bundle | see [below](#inside-the-code-view-bundle) | MIT, ISC | `code/licenses/` | listed below |
| Oniguruma, the regular-expression library, built to WebAssembly by vscode-oniguruma 1.7.0 and carried by `@shikijs/engine-oniguruma` (`code/chunks/wasm-*.js`) | Oniguruma at commit `08d36110c5670c815ad6d6f969e578049d209080` (the submodule vscode-oniguruma 1.7.0 builds) | Oniguruma: BSD 2-Clause, "Copyright (c) 2002-2021 K.Kosako — All rights reserved."; vscode-oniguruma: "MIT License — Copyright (c) Microsoft Corporation." | `code/licenses/oniguruma-COPYING`, `code/licenses/vscode-oniguruma-LICENSE` | https://github.com/kkos/oniguruma, https://github.com/microsoft/vscode-oniguruma |
| The TextMate grammars (239 files from 155 projects) and colour themes (65 files from 28 projects) that `@shikijs/langs` and `@shikijs/themes` carry | tm-grammars 1.32.22, tm-themes 1.12.12 | each under its own project's licence; see [below](#shikis-grammars-and-themes) | `code/licenses/tm-grammars-NOTICE`, `code/licenses/tm-themes-NOTICE` (every grammar's and theme's licence text, as tm-grammars and tm-themes publish them), `code/licenses/tm-grammars-LICENSE`, `code/licenses/tm-themes-LICENSE` | https://github.com/shikijs/textmate-grammars-themes |

The code view (`code.js`, `diff.js`, `fences.js` and `chunks/`) is one esbuild bundle of the packages above, made by
`app/tools/vendor_web.sh` from the sources in `app/web-src/code/` (Vitrine's own code). esbuild is a build tool and
is not shipped.

#### Inside the Mermaid bundle

`mermaid.min.js` is Mermaid's self-contained browser build: its dependencies are compiled into that one file, and it
names only DOMPurify, lodash-es and three pieces of cytoscape in its own licence comments. The table is the
production dependency tree that Mermaid's own lockfile (`pnpm-lock.yaml` at the tag `mermaid@12.2.0`) resolves for
`packages/mermaid`, plus `langium` and its dependencies, whose runtime `@mermaid-js/parser` compiles into its own
build. Type-only packages (`@types/*`) are left out: they hold no code. The list errs on the side of completeness:
a few packages are only reached by Node-only code paths (the package loaders behind `@iconify/utils`, such as
`local-pkg`, `mlly`, `tinyexec`, `package-manager-detector`, `iconv-lite`) and leave no trace in `mermaid.min.js`,
so the bundler most likely dropped them. Each licence text is in `vendor/mermaid/licenses/`, named after the package
(with the version added where two versions are present).

Two of these carry terms beyond a notice:

- **elkjs 0.9.3** (the ELK graph layout engine, used for Mermaid's ELK layouts) is under the **Eclipse Public
  License 2.0**. Its source code is available from https://github.com/kieler/elkjs (tag `0.9.3`) and in the npm
  package `elkjs@0.9.3`; it is shipped unmodified inside `mermaid.min.js`, and its licence text is
  `vendor/mermaid/licenses/elkjs-LICENSE`. The EPL-2.0 applies to elkjs only, not to Vitrine.
- **DOMPurify 3.4.12** is offered under the Apache License 2.0 or the Mozilla Public License 2.0; both texts are in
  `vendor/mermaid/licenses/` (`dompurify-LICENSE`, `dompurify-LICENSE-MPL`). Its own licence comment stays in the
  bundle.

| package | version | licence | copyright (as written in its licence file) |
|---|---|---|---|
| `@antfu/install-pkg` | 1.1.0 | MIT | Copyright (c) 2021 Anthony Fu <https://github.com/antfu> |
| `@antfu/utils` | 9.2.0 | MIT | Copyright (c) 2021 Anthony Fu <https://github.com/antfu> |
| `@braintree/sanitize-url` | 7.1.2 | MIT | Copyright (c) 2017 Braintree |
| `@chevrotain/cst-dts-gen` | 13.2.0 | Apache-2.0 | no copyright line in the file (licence text only) |
| `@chevrotain/gast` | 13.2.0 | Apache-2.0 | no copyright line in the file (licence text only) |
| `@chevrotain/regexp-to-ast` | 13.2.0 | Apache-2.0 | no copyright line in the file (licence text only) |
| `@chevrotain/types` | 13.2.0 | Apache-2.0 | no copyright line in the file (licence text only) |
| `@chevrotain/utils` | 13.2.0 | Apache-2.0 | no copyright line in the file (licence text only) |
| `@iconify/types` | 2.0.0 | MIT | Copyright (c) 2021 - 2022 Vjacheslav Trushkin / Iconify OÜ |
| `@iconify/utils` | 3.0.2 | MIT | Copyright (c) 2021-PRESENT Vjacheslav Trushkin |
| `@upsetjs/venn.js` | 2.0.0 | MIT | Copyright (c) 2013 Ben Frederickson |
| `acorn` | 8.15.0 | MIT | Copyright (C) 2012-2022 by various contributors (see AUTHORS) |
| `chevrotain` | 13.2.0 | Apache-2.0 | no copyright line in the file (licence text only) |
| `chevrotain-allstar` | 0.5.0 | MIT | Copyright 2022 TypeFox GmbH |
| `commander` | 15.0.0 | MIT | Copyright (c) 2011 TJ Holowaychuk |
| `commander` | 7.2.0 | MIT | Copyright (c) 2011 TJ Holowaychuk |
| `confbox` | 0.1.8 | MIT | Copyright (c) Pooya Parsa |
| `confbox` | 0.2.2 | MIT | Copyright (c) Pooya Parsa |
| `cose-base` | 1.0.3 | MIT | Copyright (c) 2019 - present, iVis@Bilkent. |
| `cose-base` | 2.2.0 | MIT | Copyright (c) 2019 - present, iVis@Bilkent. |
| `cytoscape` | 3.34.0 | MIT | Copyright (c) 2016-2026, The Cytoscape Consortium. |
| `cytoscape-cose-bilkent` | 4.1.0 | MIT | Copyright (c) 2016-2018, The Cytoscape Consortium. |
| `cytoscape-fcose` | 2.2.0 | MIT | Copyright (c) 2018 - present, iVis-at-Bilkent. |
| `d3` | 7.9.0 | ISC | Copyright 2010-2023 Mike Bostock |
| `d3-array` | 2.12.1 | BSD-3-Clause | Copyright 2010-2020 Mike Bostock |
| `d3-array` | 3.2.4 | ISC | Copyright 2010-2023 Mike Bostock |
| `d3-axis` | 3.0.0 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-brush` | 3.0.0 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-chord` | 3.0.1 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-color` | 3.1.0 | ISC | Copyright 2010-2022 Mike Bostock |
| `d3-contour` | 4.0.2 | ISC | Copyright 2012-2023 Mike Bostock |
| `d3-delaunay` | 6.0.4 | ISC | Copyright 2018-2021 Observable, Inc. |
| `d3-dispatch` | 3.0.1 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-drag` | 3.0.0 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-dsv` | 3.0.1 | ISC | Copyright 2013-2021 Mike Bostock |
| `d3-ease` | 3.0.1 | BSD-3-Clause | Copyright 2010-2021 Mike Bostock |
| `d3-fetch` | 3.0.1 | ISC | Copyright 2016-2021 Mike Bostock |
| `d3-force` | 3.0.0 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-format` | 3.1.0 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-geo` | 3.1.1 | ISC | Copyright 2010-2024 Mike Bostock |
| `d3-hierarchy` | 3.1.2 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-interpolate` | 3.0.1 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-path` | 1.0.9 | BSD-3-Clause | Copyright 2015-2016 Mike Bostock |
| `d3-path` | 3.1.0 | ISC | Copyright 2015-2022 Mike Bostock |
| `d3-polygon` | 3.0.1 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-quadtree` | 3.0.1 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-random` | 3.0.1 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-sankey` | 0.12.3 | BSD-3-Clause | Copyright 2015, Mike Bostock |
| `d3-scale` | 4.0.2 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-scale-chromatic` | 3.1.0 | ISC | Copyright 2010-2024 Mike Bostock |
| `d3-selection` | 3.0.0 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-shape` | 1.3.7 | BSD-3-Clause | Copyright 2010-2015 Mike Bostock |
| `d3-shape` | 3.2.0 | ISC | Copyright 2010-2022 Mike Bostock |
| `d3-time` | 3.1.0 | ISC | Copyright 2010-2022 Mike Bostock |
| `d3-time-format` | 4.1.0 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-timer` | 3.0.1 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-transition` | 3.0.1 | ISC | Copyright 2010-2021 Mike Bostock |
| `d3-zoom` | 3.0.0 | ISC | Copyright 2010-2021 Mike Bostock |
| `dagre-d3-es` | 7.0.14 | MIT | Original dagre-d3 copyright: Copyright (c) 2013 Chris Pettitt |
| `dayjs` | 1.11.21 | MIT | Copyright (c) 2018-present, iamkun |
| `debug` | 4.4.3 | MIT | Copyright (c) 2014-2017 TJ Holowaychuk |
| `delaunator` | 5.0.1 | ISC | Copyright (c) 2021, Mapbox |
| `dompurify` | 3.4.12 | (MPL-2.0 OR Apache-2.0) | Copyright (c) Cure53 and other contributors (from the bundle's own @license comment) |
| `elkjs` | 0.9.3 | EPL-2.0 | no copyright line in the file (licence text only) |
| `es-toolkit` | 1.45.1 | MIT | Copyright (c) 2024 Viva Republica, Inc |
| `exsolve` | 1.0.7 | MIT | Copyright (c) Pooya Parsa |
| `globals` | 15.15.0 | MIT | Copyright (c) Sindre Sorhus (https://sindresorhus.com) |
| `hachure-fill` | 0.5.2 | MIT | Copyright (c) 2023 Preet Shihn |
| `iconv-lite` | 0.6.3 | MIT | Copyright (c) 2011 Alexander Shtuchkin |
| `internmap` | 1.0.1 | ISC | Copyright 2021 Mike Bostock |
| `internmap` | 2.0.3 | ISC | Copyright 2021 Mike Bostock |
| `katex` | 0.18.11 | MIT | Copyright (c) 2013-2020 Khan Academy and other contributors |
| `khroma` | 2.1.0 | MIT (its `license` file; package.json names none) | Copyright (c) 2019-present Fabio Spampinato, Andrew Maney |
| `kolorist` | 1.8.0 | MIT | Copyright (c) 2020-present Marvin Hagemeister |
| `langium` | 4.4.0 | MIT | Copyright 2021 TypeFox GmbH |
| `layout-base` | 1.0.2 | MIT | Copyright (c) 2019 iVis@Bilkent |
| `layout-base` | 2.0.1 | MIT | Copyright (c) 2019 iVis@Bilkent |
| `local-pkg` | 1.1.2 | MIT | Copyright (c) 2021 Anthony Fu <https://github.com/antfu> |
| `lodash-es` | 4.18.1 | MIT | Copyright OpenJS Foundation and other contributors <https://openjsf.org/> |
| `marked` | 16.3.0 | MIT | Copyright (c) 2018+, MarkedJS (https://github.com/markedjs/) |
| `mlly` | 1.8.0 | MIT | Copyright (c) Pooya Parsa |
| `ms` | 2.1.3 | MIT | Copyright (c) 2020 Vercel, Inc. |
| `package-manager-detector` | 1.3.0 | MIT | Copyright (c) 2020-PRESENT Anthony Fu <https://github.com/antfu> |
| `path-data-parser` | 0.1.0 | MIT | Copyright (c) 2020 Preet Shihn |
| `pathe` | 2.0.3 | MIT | Copyright (c) Pooya Parsa - Daniel Roe |
| `pkg-types` | 1.3.1 | MIT | Copyright (c) Pooya Parsa - Daniel Roe |
| `pkg-types` | 2.3.0 | MIT | Copyright (c) Pooya Parsa - Daniel Roe |
| `points-on-curve` | 0.2.0 | MIT | Copyright (c) 2020 Preet Shihn |
| `points-on-path` | 0.2.1 | MIT | Copyright (c) 2020 Preet |
| `quansync` | 0.2.11 | MIT | Copyright (c) 2025-PRESENT Anthony Fu <https://github.com/antfu> and Kevin Deng <https://github.com/sxzz> |
| `robust-predicates` | 3.0.2 | Unlicense | no copyright line in the file (licence text only) |
| `roughjs` | 4.6.6 | MIT | Copyright (c) 2019 Preet Shihn |
| `rw` | 1.3.3 | BSD-3-Clause | Copyright (c) 2014-2016, Michael Bostock |
| `safer-buffer` | 2.1.2 | MIT | Copyright (c) 2018 Nikita Skovoroda |
| `stylis` | 4.3.6 | MIT | Copyright (c) 2016-present Sultan Tarimo |
| `tinyexec` | 1.2.4 | MIT | Copyright (c) 2024 Tinylibs |
| `ts-dedent` | 2.2.0 | MIT | Copyright (c) 2018 Tamino Martinius |
| `ufo` | 1.6.1 | MIT | Copyright (c) Pooya Parsa |
| `uuid` | 14.0.0 | MIT | Copyright (c) 2010-2020 Robert Kieffer and other contributors |
| `vscode-jsonrpc` | 9.0.2 | MIT | Copyright (c) Microsoft Corporation |
| `vscode-jsonrpc` | 9.0.3 | MIT | Copyright (c) Microsoft Corporation |
| `vscode-languageserver` | 10.1.1 | MIT | Copyright (c) Microsoft Corporation |
| `vscode-languageserver-protocol` | 3.18.3 | MIT | Copyright (c) Microsoft Corporation |
| `vscode-languageserver-protocol` | 3.18.4 | MIT | Copyright (c) Microsoft Corporation |
| `vscode-languageserver-textdocument` | 1.0.15 | MIT | Copyright (c) Microsoft Corporation |
| `vscode-languageserver-types` | 3.18.3 | MIT | Copyright (c) Microsoft Corporation |
| `vscode-languageserver-types` | 3.18.4 | MIT | Copyright (c) Microsoft Corporation |
| `vscode-uri` | 3.1.0 | MIT | Copyright (c) Microsoft |

#### Inside the code view bundle

The packages below are the dependencies of the CodeMirror and Shiki packages listed above, as `npm install`
resolved them for `vendor_web.sh` on 2026-10-31 (the newest version published by that day that meets each
declared range). `@shikijs/engine-javascript` and its dependencies are not included: the code view uses only the
Oniguruma engine, and the bundle holds no part of the JavaScript engine. Each licence text is in `code/licenses/`,
named after the package with `/` and `@` turned into `_`.

| package | version | licence | copyright (as written in its licence file) |
|---|---|---|---|
| `@codemirror/streamparser` | 6.0.0 | MIT | Copyright (C) 2018-2021 by Marijn Haverbeke and others |
| `@lezer/common` | 1.5.5 | MIT | Copyright (C) 2018 by Marijn Haverbeke and others |
| `@lezer/highlight` | 1.2.5 | MIT | Copyright (C) 2018 by Marijn Haverbeke and others |
| `@lezer/lr` | 1.4.12 | MIT | Copyright (C) 2018 by Marijn Haverbeke and others |
| `@marijn/find-cluster-break` | 1.0.4 | MIT | Copyright (C) 2024 by Marijn Haverbeke |
| `@shikijs/primitive` | 4.5.0 | MIT | Copyright (c) 2021 Pine Wu |
| `@shikijs/types` | 4.5.0 | MIT | Copyright (c) 2021 Pine Wu |
| `@ungap/structured-clone` | 1.4.0 | ISC | Copyright (c) 2021, Andrea Giammarchi, @WebReflection |
| `ccount` | 2.0.1 | MIT | Copyright (c) 2015 Titus Wormer |
| `character-entities-html4` | 2.1.0 | MIT | Copyright (c) 2015 Titus Wormer |
| `character-entities-legacy` | 3.0.0 | MIT | Copyright (c) 2015 Titus Wormer |
| `comma-separated-tokens` | 2.0.3 | MIT | Copyright (c) 2016 Titus Wormer |
| `crelt` | 1.0.7 | MIT | Copyright (C) 2020 by Marijn Haverbeke |
| `dequal` | 2.0.3 | MIT | Copyright (c) Luke Edwards (lukeed.com) |
| `devlop` | 1.1.0 | MIT | Copyright (c) 2023 Titus Wormer |
| `hast-util-to-html` | 9.0.6 | MIT | Copyright (c) Titus Wormer |
| `hast-util-whitespace` | 3.0.0 | MIT | Copyright (c) 2016 Titus Wormer |
| `html-void-elements` | 3.0.0 | MIT | Copyright (c) 2016 Titus Wormer |
| `mdast-util-to-hast` | 13.2.1 | MIT | Copyright (c) 2016 Titus Wormer |
| `micromark-util-character` | 2.1.1 | MIT | Copyright (c) Titus Wormer |
| `micromark-util-encode` | 2.0.1 | MIT | Copyright (c) Titus Wormer |
| `micromark-util-sanitize-uri` | 2.0.1 | MIT | Copyright (c) Titus Wormer |
| `micromark-util-symbol` | 2.0.1 | MIT | Copyright (c) Titus Wormer |
| `micromark-util-types` | 2.0.3 | MIT | Copyright (c) Titus Wormer |
| `property-information` | 7.2.0 | MIT | Copyright (c) Titus Wormer |
| `space-separated-tokens` | 2.0.2 | MIT | Copyright (c) 2016 Titus Wormer |
| `stringify-entities` | 4.0.4 | MIT | Copyright (c) 2015 Titus Wormer |
| `style-mod` | 4.1.4 | MIT | Copyright (C) 2018 by Marijn Haverbeke and others |
| `trim-lines` | 3.0.1 | MIT | Copyright (c) 2015 Titus Wormer |
| `unist-util-is` | 6.0.1 | MIT | Copyright (c) 2015 Titus Wormer |
| `unist-util-position` | 5.0.0 | MIT | Copyright (c) 2015 Titus Wormer |
| `unist-util-stringify-position` | 4.0.0 | MIT | Copyright (c) 2016 Titus Wormer |
| `unist-util-visit` | 5.2.0 | MIT | Copyright (c) Titus Wormer |
| `unist-util-visit-parents` | 6.1.0 | MIT | Copyright (c) Titus Wormer |
| `vfile` | 6.0.3 | MIT | Copyright (c) 2015 Titus Wormer |
| `vfile-message` | 4.0.3 | MIT | Copyright (c) Titus Wormer |
| `w3c-keyname` | 2.2.8 | MIT | Copyright (C) 2016 by Marijn Haverbeke and others |
| `zwitch` | 2.0.4 | MIT | Copyright (c) 2016 Titus Wormer |

#### Shiki's grammars and themes

`@shikijs/langs` and `@shikijs/themes` are MIT as packages, but each grammar and colour theme in them is a copy of
a file from its own upstream project, under that project's licence. Shiki takes them from tm-grammars 1.32.22 and
tm-themes 1.12.12, whose `NOTICE` files list every file with its source, its SPDX identifier and the licence text
in full; both files ship in the app (`code/licenses/tm-grammars-NOTICE`, `code/licenses/tm-themes-NOTICE`).

| set | entries | licences (SPDX, as the NOTICE files give them) |
|---|---|---|
| grammars | 155 projects, 239 files | MIT 111, Apache-2.0 22, MPL-2.0 2, ISC 1, BSD-3-Clause 1, GPL-3.0 5, LGPL-3.0 1, and 12 the NOTICE marks NOASSERTION (their licence texts are in the NOTICE; for example llvm is Apache-2.0 with LLVM Exceptions, wolfram is MIT) |
| themes | 28 projects, 65 files | MIT 26, Apache-2.0 1, GPL-3.0 1 |

The grammars and theme under a copyleft licence are named here so nobody has to search for them, each shipped
unmodified as its own file in `code/chunks/` and loaded only when a file of that language (or that theme) is shown:

| file | licence | source |
|---|---|---|
| `ada` grammar | GPL-3.0 | https://github.com/AdaCore/ada_language_server |
| `gnuplot` grammar | GPL-3.0 | https://github.com/MarioSchwalbe/vscode-gnuplot |
| `nginx` grammar | GPL-3.0 | https://github.com/hangxingliu/vscode-nginx-conf-hint |
| `org` grammar | GPL-3.0 | https://github.com/vscode-org-mode/vscode-org-mode |
| `racket` grammar | GPL-3.0 | https://github.com/Eugleo/magic-racket |
| `ahk2` grammar | LGPL-3.0 | https://github.com/thqby/vscode-autohotkey2-lsp |
| `hcl` and `terraform` grammars | MPL-2.0 | https://github.com/hashicorp/syntax |
| `bird2` grammar | MPL-2.0 | https://github.com/bird-chinese-community/BIRD-tm-language-grammar |
| `aurora-x` theme | GPL-3.0 | https://github.com/marqu3ss/Aurora-X |

### C libraries (compiled into the app)

| component | version | licence (as written in its file) | licence file in this repository | source |
|---|---|---|---|---|
| Zstandard, decompression only | 1.5.7 | "BSD License — For Zstandard software — Copyright (c) Meta Platforms, Inc. and affiliates." (zstd is dual BSD / GPLv2; Vitrine uses it under the BSD licence) | `app/Packages/Sources/CZstd/LICENSE` (provenance: `VENDORED.md`); in the app as `web/licenses/zstd-LICENSE` | https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz, SHA-256 `eb33e51f…6fa3` |
| LZ4, the `lib/` directory (lz4, lz4frame, lz4hc) and the xxHash copy it includes | 1.10.0 | "LZ4 Library — Copyright (c) 2011-2020, Yann Collet — All rights reserved." BSD 2-Clause (only `lib/` is BSD; LZ4's programs are GPL and were not copied) | `app/Packages/Sources/CLZ4/LICENSE` (provenance: `VENDORED.md`); in the app as `web/licenses/lz4-LICENSE` | https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz, SHA-256 `53751290…f48b` |
| swift-cmark, the `gfm` branch (cmark-gfm: Markdown parsing) | revision `437611671145d47e6d9679761b8a5987766f4ae5` (pinned in `app/Packages/Package.resolved`) | `COPYING`: "Copyright (c) 2014, John MacFarlane — All rights reserved." (BSD 2-Clause), with sections for code derived from houdini ("Copyright (C) 2012 Vicent Martí", MIT), libgit2's buffer code ("(C) 2012 Github, Inc.", MIT), utf8proc (MIT) and others, each with its text | fetched by Swift Package Manager; its `COPYING` at that revision is in the app as `web/licenses/swift-cmark-COPYING` | https://github.com/swiftlang/swift-cmark |

### Data files

| component | licence | file in this repository | source |
|---|---|---|---|
| `o200k_base.tiktoken`, OpenAI's o200k_base byte-pair ranks (exact OpenAI token counts, A-4) | **No licence stated for the data file.** tiktoken's *code* is under "MIT License — Copyright (c) 2022 OpenAI, Shantanu Jain", but that licence covers the code in tiktoken's repository; OpenAI hosts the encoding file separately and has stated no licence for it (checked 2026-11-01). It is bundled unchanged, and Vitrine's counter is its own Swift code following tiktoken's algorithm. | `app/Packages/Sources/VitrineTokenizers/Resources/o200k_base.tiktoken`, notice in `tiktoken-LICENSE.txt` beside it | https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken (SHA-256 `446a9538…1a2d`); https://github.com/openai/tiktoken |
| Emoji shortcode table (`:smile:` → 😄 in Markdown), 1,913 aliases | generated from github/gemoji's `db/emoji.json`: "MIT — Copyright (c) 2019 GitHub, Inc." The generated file says so in its header. | `app/Packages/Sources/VitrineText/EmojiTable.generated.swift`; gemoji's licence in the app as `web/licenses/gemoji-LICENSE` | https://github.com/github/gemoji |

### Fonts

The only fonts shipped are KaTeX's 20 `KaTeX_*.woff2` files, distributed in the KaTeX package under the MIT licence
above (no separate font licence file came with them). Everything else uses the system fonts of macOS.

### From Obscura (same author)

`VitrineDetect`, the secret detectors (84, with their invented fixtures) behind the trust lens and the connector's
`scan_secrets`, is ported from Obscura's ObscuraDetect (https://github.com/XBTDMT/obscura, GPL-3.0-or-later). It is
the same author's code, offered here under Vitrine's licence, so it carries no third-party obligation; it is listed
so the origin is clear.

### Not bundled

These are part of macOS and are used, not shipped: libarchive (`/usr/lib/libarchive.2.dylib`, through Vitrine's own
declarations in `app/Packages/Sources/CArchive`), SQLite, WebKit, Quick Look, Foundation Models and the other Apple
frameworks.

## Downloaded at run time, only when you turn it on

| data | when | licence | source |
|---|---|---|---|
| OSV vulnerability lists, one file per package ecosystem (npm, PyPI, crates.io, Go, RubyGems, Packagist, SwiftURL), for the vulnerability hints on lockfile previews | Only after you switch an ecosystem on in Settings › Privacy; refreshed when you ask, or every week if you turn that on. The whole public list is fetched, so nothing about your files is sent. Off by default. | Varies by the advisory's original source, as OSV publishes it: **CC-BY 4.0** (for example GitHub Advisory Database, PyPI, Go) or **CC0 1.0** (for example the RustSec database for crates.io). Each record names its source. | https://storage.googleapis.com/osv-vulnerabilities/ (OSV, https://osv.dev) |

CC-BY 4.0 asks for attribution: Settings › About credits OSV.dev with "Advisories from OSV.dev, under each source's
licence (CC-BY 4.0 or CC0)".
