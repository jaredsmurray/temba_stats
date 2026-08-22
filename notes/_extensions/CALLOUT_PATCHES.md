# Local callout extension patches

Pinned and verified on 2026-07-30.

## `custom-numbered-blocks` 0.7.1-1

Upstream: <https://github.com/ute/custom-numbered-blocks>

The project owns two narrow changes:

1. `cnb-3-crossref.lua` lets level-one headings establish and reset the
   chapter prefix when a PDF book is processed as one Pandoc document.
2. `textcontainers/foldbox/foldbox.lua` renders appearances with
   `collapse: false` as static HTML blocks with semantic Bootstrap icons.
   Collapsible appearances continue to use `<details>`.

## `details` 0.0.0-dev.2

The project owns one narrow change in `details.lua`: author-supplied classes
other than the implementation class `.details` are preserved on the generated
HTML `<details>` element. This supports semantic `.formula-details` and
`.solution-details` styling.

Before upgrading either extension, check whether these changes are upstream,
remove obsolete patches rather than layering over them, and run:

```bash
tools/check_callouts.sh
```
