defmodule KilnCMS.CMS.SiteMeilisearch do
  @moduledoc """
  A site's own Meilisearch instance (#1558): the URL, API key and index this
  site's published content is indexed into, entered by the site's admin at
  `/editor/site-search` instead of by the operator in `MEILI_*` environment
  variables.

  The third of the per-site integrations #1322 moves out of the environment,
  built on the shape `KilnCMS.CMS.SiteMailRelay` set. Read through
  `KilnCMS.Search.Meilisearch.SiteInstance`, which owns the precedence rule and
  the fail direction for both indexing and querying; nothing else should read
  this row.

  ## Who can write it, and what that means

  Org admin, like every `KilnCMS.CMS.OrgSettings` resource. On a hosted
  deployment that is a tenant, so the same two rules as the site relay apply:

    * **The API key is database-only.** It is encrypted into
      `api_key_encrypted` (`KilnCMS.Keys.Vault`) and never read back into a
      form. There is no env-var or file source: a tenant who could point "the
      Meilisearch key" at an environment variable could send
      `SECRET_KEY_BASE` to their own server as a bearer token.
    * **The URL is SSRF-checked**, at save (`Validations.SearchUrl`) and again on
      every request (`KilnCMS.SafeFetch`: resolved once, pinned, no redirects).
      No private, loopback, link-local or metadata address, and HTTPS only. An
      operator who needs an internal instance sets `MEILI_URL`, which is
      trusted and unchecked.

  Reads are admin-only too. Nothing here is rendered to a visitor.

  ## What leaves the deployment

  Every published document on this site that an anonymous visitor could read —
  title, excerpt and full body text — is sent to `url`. That is the point of
  the setting, and the page says so before the admin saves it.

  ## The key on a save

  A blank key keeps the stored one — the form never has it to send back.
  `api_key_encrypted` is left out of the upsert's `upsert_fields` on purpose,
  for the reason `SiteMailRelay` gives: a `:save` that lost a create race must
  not overwrite the winner's key.

  Every write — including switching it off and removing it — enqueues a
  reindex of the site into whichever instance it now resolves to
  (`Changes.EnqueueSearchReindex`), because the new instance starts empty.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_meilisearch",
    accept: [:enabled, :url, :index],
    save_arguments: [{:api_key, :string, sensitive?: true}],
    save_changes: [
      KilnCMS.CMS.Changes.StoreMeilisearchKey,
      KilnCMS.CMS.Changes.EnqueueSearchReindex
    ],
    read: :admin

  changes do
    # Removing the row moves the site back onto the operator's instance (or
    # off Meilisearch altogether), which needs the same full reindex a save does.
    change KilnCMS.CMS.Changes.EnqueueSearchReindex, on: [:destroy]
  end

  validations do
    validate present([:url, :index]), where: [attribute_equals(:enabled, true)]
    validate KilnCMS.CMS.Validations.SearchUrl

    # Meilisearch's own rule for an index uid. Checked here so a typo is an
    # error on the form, not a failed job an hour later.
    validate match(:index, ~r/\A[A-Za-z0-9_-]{1,400}\z/),
      message: "may only contain letters, digits, hyphens and underscores"
  end

  attributes do
    # Off keeps the details but indexes into the operator's instance again (if
    # the deployment has one) — the way back from a broken instance that does
    # not mean retyping it.
    attribute :enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    # The instance's base URL, e.g. `https://search.example.com`. A path is
    # kept (an instance behind a reverse proxy at `/meili`); a query string,
    # fragment or userinfo is refused by `Validations.SearchUrl`.
    attribute :url, :string,
      public?: true,
      constraints: [max_length: 2048]

    attribute :index, :string do
      default "kiln_content"
      public? true
      constraints max_length: 400
    end

    # Set only by `Changes.StoreMeilisearchKey`, from the `:api_key` argument.
    # `Vault.Ciphertext`, not plain `:binary`, so `mix kiln.vault.reencrypt`
    # walks it across a `SECRET_KEY_BASE` rotation (#1487).
    attribute :api_key_encrypted, KilnCMS.Keys.Vault.Ciphertext do
      sensitive? true
      writable? false
    end
  end
end
