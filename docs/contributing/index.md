# Contributing to the docs

These docs live in the `con-services` repository, in the `docs/` folder, and
are built with [MkDocs](https://www.mkdocs.org) and the
[Material for MkDocs](https://squidfunk.github.io/mkdocs-material/) theme.
Every page has an edit button (the pencil at the top) that opens it on
GitHub.

## How the docs are organised

```text
mkdocs.yml                 site settings and the navigation
docs/
  index.md                 home page and module list
  getting-started/         tutorials: first steps, troubleshooting
  concepts/                how things work: architecture, sign-in, pairing, glossary
  modules/
    index.md               module list
    den/                   one folder per module
      index.md             overview
      admin-guide.md       the module from an administrator's point of view
      configuration.md     every setting
      api.md               every endpoint
  operations/              running, backups, production
  contributing/            this section
  requirements.txt         the Python packages needed to build the site
```

Each kind of page has one job:

- **Getting started** pages are tutorials: one path, every step, nothing
  optional.
- **Concepts** explain *what* and *why*, with diagrams. No step-by-step
  instructions.
- **Admin guides** describe each screen and task.
- **Configuration** and **API** pages are references: complete, in tables,
  one example each.
- **Operations** is for whoever runs the installation.

The code of each module lives in its own repository. The docs link there
for source code, ADRs and anything too detailed for the site.

## Writing style

- Friendly, plain English. Short sentences. Explain words the first time
  you use them, or link to the [glossary](../concepts/glossary.md).
- Explain **what** something is before **how** to use it.
- Show an example for everything: a command, a request, a JSON document.
- Only document what the code does. If something is unclear, say so or leave
  it out; do not guess.
- Use the development passwords from the repository in examples only when
  necessary, and always mark them as development-only.
- Give commands for each operating system with tabs when they differ:

    ````markdown
    === "macOS / Linux"

        ```sh
        cp .env.example .env
        ```

    === "Windows"

        ```powershell
        Copy-Item .env.example .env
        ```
    ````

- Use admonitions (`!!! note`, `!!! warning`, `!!! danger`) for things people
  must not miss, and Mermaid code blocks (` ```mermaid `) for diagrams.

## Preview the site locally

You need Python 3.

=== "macOS / Linux"

    ```sh
    python3 -m venv .venv
    source .venv/bin/activate
    pip install -r docs/requirements.txt
    mkdocs serve
    ```

=== "Windows"

    ```powershell
    python -m venv .venv
    .venv\Scripts\Activate.ps1
    pip install -r docs/requirements.txt
    mkdocs serve
    ```

Open <http://127.0.0.1:8000>. The page reloads when you save a file.

Before you push, check that the site builds without warnings:

```sh
mkdocs build --strict
```

`--strict` turns every warning into an error, including broken links and
missing anchors. The published site is built the same way, so a warning
here would stop the publication. The build writes to `site/`, which Git
ignores.

## Publishing

The GitHub Actions workflow `.github/workflows/docs.yml` builds the site with
`mkdocs build --strict` and publishes it to GitHub Pages at
<https://aglelectronics.github.io/con-services/>. It runs on every push to
`main` that changes `docs/` or `mkdocs.yml`, and can be started by hand from
the repository's **Actions** tab (**Docs** → **Run workflow**).

One-time setup: in the repository's **Settings → Pages**, set **Source** to
**GitHub Actions**.

## Adding a module's docs

1. Create `docs/modules/<module>/` with the same four pages as Den:
   `index.md`, `admin-guide.md`, `configuration.md` and `api.md`.
2. Add them to `nav` in `mkdocs.yml`, under **Modules**, after Den.
3. Link the module from `docs/index.md` and `docs/modules/index.md`.
4. Point the module's `README.md` at its section of the site.
5. Run `mkdocs build --strict`.

The full standards (API docs, secrets, versioning, and a
**before it looks open-source ready** checklist) are in
[Documentation standards](documentation-standards.md).

## Checklist for every change

Documentation is part of the change, not a follow-up. Before you open a
merge request, check what applies:

- [ ] The docs page describing the behaviour is updated (or a new page is
      added and linked from `nav` in `mkdocs.yml`).
- [ ] **API changes:** method and path, who may call it, request and response
      bodies, error codes and a `curl` example with a realistic response.
- [ ] **New environment variable:** a row in the module's configuration
      table (name, default, required, purpose) and an entry in
      `.env.example`.
- [ ] **Changelog:** an entry under `## [Unreleased]` in the module's
      `CHANGELOG.md`; shared infrastructure goes in the root one
      ([Changelogs](changelog.md)).
- [ ] **Deployment files in sync:** Kustomize (`deploy/kubernetes/`), the
      Helm chart (`deploy/charts/`), the root `docker-compose.yml` and the
      docs. A new connection between pods needs NetworkPolicy rules on
      **both** sides and a row in
      [Every allowed flow](../operations/network-policies.md#every-allowed-flow).
- [ ] **New secret:** a row in the [Secrets inventory](../operations/secrets.md#inventory),
      an obvious dev value in the example overlay's `secrets.yaml`, and the
      `ExternalSecret` example.
- [ ] **Decision with lasting consequences:** an ADR in the module's
      `docs/adr/`.
- [ ] `mkdocs build --strict` passes.

## Changelogs

Every repository keeps a `CHANGELOG.md`; see [Changelogs](changelog.md).

## Troubleshooting

**`mkdocs: command not found`** (or *'mkdocs' is not recognized*)
: The virtual environment is not active. Run the `activate` command from
  [Preview the site locally](#preview-the-site-locally) again, or use
  `python -m mkdocs build --strict`.

**`The following pages exist in the docs directory, but are not included in the "nav" configuration`**
: Add the page to `nav` in `mkdocs.yml`, in the right section.

**`… contains a link 'x.md#some-heading', but the doc 'x.md' does not contain an anchor '#some-heading'`**
: The heading was renamed or the anchor is misspelled. Anchors are the
  heading in lower case, spaces replaced by `-`, punctuation removed:
  `## Add a module's secrets` becomes `#add-a-modules-secrets`. Open the
  built page and copy the link from the heading's ¶ symbol.

**`… contains a link 'x.md', but the target is not found among documentation files`**
: Links are relative to the current file: from `operations/` to a
  getting-started page use `../getting-started/page.md`.

**Tabs or admonitions render as plain text**
: Content inside `=== "Tab"` and `!!! note` must be indented by four
  spaces, and there must be an empty line before the block.

**Mermaid diagrams show as code locally**
: They are rendered in the browser; check the browser console for a
  syntax error in the diagram.
