# Reading paths by role

<!-- seo-description: Where to start in the Kiln docs: the guides an editor, a
developer and an operator should read first, in order. -->

Kiln's guides are grouped by subject, which is a good way to find one guide
and a poor way to know where to begin. Pick the role closest to yours below
and read its guides in the order given. Each list is short on purpose; the
full catalogue is grouped by subject on the documentation index.

## Editor

You write, review and publish content in the Kiln editor.

1. [The editorial workflow](editorial-workflow.md): a page from draft to
   review to published, and what viewers, editors and admins can each do.
2. [Editor shortcuts](editor-shortcuts.md): the keyboard shortcuts and slash
   commands that make the editor quick to use.
3. [Markdown](markdown.md): pasting and importing Markdown, and what it
   becomes.
4. [The working copy](working-copy.md): editing a live document without
   changing what readers see until you publish.
5. [Content releases](content-releases.md): publishing several changes
   together, as one change at one moment.
6. [Discussions](comments.md): comments on a block during review, resolved
   or turned into a task.
7. [Editorial advisories](advisories.md): the editor's advice on what you
   are writing, such as a skipped heading level or an image with no alt text.
8. [SEO](seo.md): the search analysis and the help drafting titles and
   descriptions.

## Developer

You read Kiln's content from your own site or app, or extend Kiln itself.

1. [Headless consumer guide](headless-consumer-guide.md): which API to use
   for your front end, and where to go next.
2. [JSON:API](json-api.md): reading and writing content over HTTP.
3. [GraphQL](headless-graphql-api.md): the same content as a GraphQL schema.
4. [Webhooks](webhooks.md): hearing about a change as soon as it is
   published, including retractions.
5. [Extending the content model](extending-content.md): adding content types
   and fields.
6. [The overlay contract](overlay-contract.md): what your own project may rely
   on across Kiln releases.
7. [Plugins](plugin-extensibility.md): adding behaviour at runtime with a
   plugin.

## Operator

You install, run and upgrade a Kiln site.

1. [System requirements](system-requirements.md): what a server needs before
   you start.
2. [Deploy](deploy.md): the image, the required settings and the first admin
   account. [One-click deploy platforms](deploy-platforms.md) covers the
   hosted options.
3. [Environment variables](environment-variables.md): every setting, and
   which ones you must set.
4. [Backups and restore](backups.md): what to back up, and how to bring a site
   back.
5. [Observability](observability.md): telemetry and performance profiling
   for the editor, with an optional Prometheus exporter.
6. [Account administration](account-administration.md): adding people and
   giving them roles. [Granular RBAC](granular-rbac.md) covers finer-grained
   permissions.
7. [Secrets rotation](secrets-rotation.md): replacing each secret a
   deployment depends on, and what breaks while you do.
8. [Threat model](threat-model.md): what the public APIs expose, and how each
   risk is handled.

Upgrade steps live in the release guide, under Contributing to Kiln:
[Updating a project to a release](releasing.md#updating-a-project-to-a-release).
