# TEMBA Statistics — public course site

This Quarto repository contains approved source for the TEMBA Statistics
website. It normally lives under `public/` in the private course checkout.
Root pages and slides render into `_book`; the nested notes book renders into
`_book/notes`. Files and explicitly selected data resources are deployed too.

Content is authored in private staging and promoted after review. Public book
membership and navigation describe released material. Pushing this repository
exposes committed source; deploying Pages exposes generated output and resources.
Gitignore is not a privacy boundary for files already on disk.

## Publishing

Use the private course repository's `WORKFLOWS.md` and root publisher:

```text
./publish.sh --prepare
./publish.sh --deploy <prepared-build-directory>
./publish.sh --verify <prepared-build-directory>
```

The wrapper here forwards to that private workflow. A standalone public clone
cannot use it to deploy. Preparation requires a clean reviewed source commit,
creates a private full build with fresh execution, and does not deploy.
Deployment uploads the inspected build without re-rendering. No-argument and
old partial/default publication commands do not deploy.

Problem-set PDFs enter through the private PS preparation/promotion command.
Solutions, assessment source, private review records and exams remain private.

## Data

`tools/get_data.sh` materializes the release named by `data_pin`, using an
authenticated `gh` for the private teaching-data repository. Build data is
ignored by Git. `_quarto.yml` explicitly selects datasets served publicly;
`data.qmd` documents those data. Review eligibility before changing that selection.
Data cards may also supply rendered documentation in the notes.

Routine cached previews can miss shared-code or data changes. Release preparation
uses fresh execution. Fetch data rather than editing its materialized copies.

## License

The instructor has not yet selected a content license. Dataset terms are
separate and must be checked before redistribution.
