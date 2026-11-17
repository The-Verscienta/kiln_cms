defmodule KilnCMS.Staging.ScrubCoverageTest do
  @moduledoc """
  Every table in the schema is either handled by the staging scrub
  (`KilnCMS.Staging.Scrub.dispositions/0`) or kept on purpose, with a reason
  (#2721). A new table therefore cannot reach a staging clone unexamined: it
  fails here until someone decides whether the scrub purges it.

  Column names alone would not do: personal data also lives in `jsonb`
  (`form_submissions.data`, `oban_jobs.args`, a webhook payload), which no
  column pattern finds. The column check below is the second net, for a kept
  table that later grows an address column.

  A plugin's or the overlay's tables are handled by their plugin's
  `c:Kiln.Plugin.staging_scrub/0` (#2975): the ones it purges or rewrites are
  in `dispositions/0`, the ones it keeps in `Scrub.plugin_kept/0`, and the
  scrub refuses to run while one is in neither (`KilnCMS.Staging.PluginScrub`,
  tested in `plugin_scrub_test.exs`).

  The tables are read from the test database, so a stale local database from
  another branch (a table this branch has not got, or lacks one it has) turns
  this red. Rebuild it with `MIX_ENV=test mix ash.reset` before reading
  anything into a failure here.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Repo
  alias KilnCMS.Staging.PluginScrub
  alias KilnCMS.Staging.Scrub

  # Tables a scrubbed clone keeps as they are, and why.
  @kept %{
    "billing_membership_events" =>
      "entitlement trail; references memberships, which are scrubbed, and accounts, which are anonymized",
    "block_embeddings" => "search vectors derived from content",
    "categories" => "content taxonomy",
    "chain_checkpoint_entries" => "provenance chain over content history (hashes)",
    "chain_checkpoints" => "provenance chain over content history (hashes)",
    "collab_doc_states" => "collaborative editing state of content documents",
    "comments" =>
      "editorial comments by staff accounts, which are anonymized; free-text body is a known follow-up",
    "content_consents" =>
      "consent records for content (rights, releases); the grantor column is listed in @kept_personal",
    "content_experiment_variant_days" => "aggregate experiment counts, no visitor identifiers",
    "content_experiment_variants" => "experiment configuration",
    "content_experiments" => "experiment configuration",
    "content_links" => "link graph between content",
    "content_releases" => "scheduled content releases",
    "content_view_days" => "aggregate view counts, no visitor identifiers",
    "content_views" => "aggregate view counts, no visitor identifiers",
    "document_chunk_embeddings" => "search vectors derived from content",
    "document_events" => "content change log; actors are accounts, which are anonymized",
    "entries" => "content",
    "entries_versions" => "content history",
    "external_links" => "link-checker results for URLs in content",
    "federation_blocks" =>
      "moderation list of remote domains and actors; the clone's federation identity is purged, so it federates with no one",
    "federation_seen_signatures" => "short-lived replay cache of signature hashes",
    "feed_settings" => "site configuration",
    "field_definitions" => "content schema",
    "field_sections" => "content schema",
    "form_fields" => "form definitions (the submissions are purged)",
    "form_spam_settings" => "site configuration",
    "funnel_steps" => "analytics funnel configuration",
    "funnels" => "analytics funnel configuration",
    "history_anchors" => "provenance anchors over content history",
    "ip_block_rules" =>
      "operator-entered block rules; the cidr column is listed in @kept_personal",
    "media_derivatives" => "content assets",
    "media_items" => "content assets",
    "menu_items" => "site navigation",
    "menus" => "site navigation",
    "newsletter_segments" => "segment definitions; the subscribers in them are purged",
    "newsletter_sends" => "send history: subject and counts, no recipients",
    "oban_peers" => "Oban leader election, rewritten by whichever node boots",
    "org_memberships" => "account-to-site links; the accounts are anonymized",
    "organizations" => "the sites themselves",
    "pages" => "content",
    "pages_versions" => "content history",
    "platform_security_alerts" => "instance configuration",
    "posts" => "content",
    "posts_versions" => "content history",
    "propagations" => "content propagation records",
    "provenance_settings" =>
      "content signing key; scrubbing it would break governance on the clone (follow-up)",
    "published_artifacts" => "published content",
    "redirects" => "site configuration",
    "reference_edges" => "reference graph between content",
    "release_items" => "scheduled content releases",
    "referrer_days" => "aggregate referrer counts, no visitor identifiers",
    "roles" => "role definitions",
    "saved_views" => "editor filter presets; owners are anonymized accounts",
    "schema_migrations" => "Ecto migration bookkeeping",
    "search_synonyms" => "site configuration",
    "site_admin_allowlist" => "admin access rule; the cidrs column is listed in @kept_personal",
    "site_bot_budgets" => "site configuration",
    "site_branding" => "site configuration",
    "site_code_injection" => "site content (snippets the site serves)",
    "site_code_injection_versions" => "site content history",
    "site_compliance" => "site configuration",
    "site_editorial_settings" => "site configuration",
    "site_embed_settings" => "site configuration",
    "site_link_check" => "site configuration",
    "site_locale_settings" => "site configuration",
    "site_password_policy" => "site configuration",
    "site_registration" => "site configuration",
    "site_safety_fields" => "site configuration",
    "site_second_factor_policy" => "site configuration",
    "site_security_alerts" => "site configuration",
    "site_security_log" => "site configuration (log retention)",
    "site_security_txt" =>
      "the site's published security.txt; the contacts column is listed in @kept_personal",
    "site_session_policy" => "site configuration",
    "site_sso_domains" =>
      "verified sign-in domains; inert once the site's SSO provider is purged",
    "site_storages" =>
      "which storage profile a site uses; storage credentials are a known follow-up",
    "social_posts" => "post history of content; the accounts are deactivated",
    "storage_profiles" =>
      "media storage (S3) settings; holds credentials, kept because media breaks without them (follow-up)",
    "sync_exposures" => "change-feed disclosure records for content",
    "tag_embeddings" => "search vectors derived from tags",
    "tag_groups" => "content taxonomy",
    "taggings" => "content taxonomy",
    "tags" => "content taxonomy",
    "tasks" =>
      "editorial tasks assigned to accounts, which are anonymized; free-text note is a known follow-up",
    "type_definitions" => "content schema"
  }

  # Columns of kept tables whose name says they may hold personal data, and
  # why each stays.
  @kept_personal %{
    {"content_consents", "grantor"} =>
      "who granted rights to a piece of content: part of the content's legal record (follow-up)",
    {"ip_block_rules", "cidr"} =>
      "operator-entered abuse blocks, not visitor logs; the clone should refuse the same sources",
    {"site_admin_allowlist", "cidrs"} =>
      "the operator's own admin networks; dropping them would widen admin access on the clone",
    {"site_security_txt", "contacts"} => "published in the site's security.txt, public by design",
    {"storage_profiles", "endpoint"} => "an S3 endpoint URL, not a person"
  }

  defp base_tables do
    Repo.query!("""
    SELECT table_name FROM information_schema.tables
    WHERE table_type = 'BASE TABLE'
      AND table_schema NOT IN ('pg_catalog', 'information_schema')
      AND table_name NOT LIKE 'join\\_probe\\_%'
    """).rows
    |> List.flatten()
    |> MapSet.new()
  end

  test "every table is handled by the scrub or kept with a reason" do
    handled = Scrub.dispositions() |> Map.keys() |> MapSet.new()
    kept = @kept |> Map.merge(Scrub.plugin_kept()) |> Map.keys() |> MapSet.new()
    tables = base_tables()

    unclassified = tables |> MapSet.difference(handled) |> MapSet.difference(kept)

    assert MapSet.size(unclassified) == 0, """
    These tables are neither scrubbed (KilnCMS.Staging.Scrub.dispositions/0)
    nor in @kept here:

      #{unclassified |> Enum.sort() |> Enum.join("\n  ")}

    Decide for each whether a production clone may keep its rows. If it holds
    personal data, an outbound secret, or work that would act on production's
    behalf, add it to the scrub; otherwise add it to @kept with the reason.
    """

    stale = kept |> MapSet.union(handled) |> MapSet.difference(tables)

    assert MapSet.size(stale) == 0,
           "No such table any more (or the test database is stale): #{inspect(Enum.sort(stale))}"

    both = MapSet.intersection(kept, handled)
    assert MapSet.size(both) == 0, "Both scrubbed and kept: #{inspect(Enum.sort(both))}"
  end

  test "a kept table's personal-looking column is kept on purpose" do
    kept = Map.keys(@kept)

    found =
      Repo.query!(
        """
        SELECT table_name, column_name, udt_name FROM information_schema.columns
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
          AND table_name = ANY($1)
          AND udt_name <> 'bool'
        """,
        [kept]
      ).rows
      |> Enum.filter(fn [_table, column, udt] -> PluginScrub.personal_column?(column, udt) end)
      |> MapSet.new(fn [table, column, _udt] -> {table, column} end)

    listed = @kept_personal |> Map.keys() |> MapSet.new()

    unlisted = MapSet.difference(found, listed)

    assert MapSet.size(unlisted) == 0, """
    These columns of kept tables look like personal data:

      #{unlisted |> Enum.sort() |> Enum.map_join("\n  ", fn {t, c} -> "#{t}.#{c}" end)}

    Scrub them (KilnCMS.Staging.Scrub) or list them in @kept_personal with the
    reason the clone may keep them.
    """

    stale = MapSet.difference(listed, found)
    assert MapSet.size(stale) == 0, "No such kept column any more: #{inspect(Enum.sort(stale))}"
  end

  test "every purged table is empty after a scrub" do
    Scrub.run([])

    nonempty =
      for {table, {:purged, _key}} <- Scrub.dispositions(),
          %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{table}"|),
          n > 0,
          do: {table, n}

    assert nonempty == []
  end

  # With a plugin that declares tables, whether or not they exist yet: its
  # purges and rewrites are counted under their own keys, and dispositions
  # still name exactly what the summary holds.
  test "dispositions name exactly the summary's counts, with a plugin's tables" do
    opts = [
      plugins: [KilnCMS.PluginScrubFixtures.DeclaringPlugin],
      ash_domains: PluginScrub.core_domains()
    ]

    from_dispositions =
      opts |> Scrub.dispositions() |> Map.values() |> MapSet.new(fn {_kind, key} -> key end)

    from_summary =
      opts |> Scrub.run() |> Map.delete(:admin_provisioned) |> Map.keys() |> MapSet.new()

    assert from_dispositions == from_summary
    assert {:plugin, "booking", "psf_bookings"} in from_summary
  end

  test "dispositions name exactly the summary's counts" do
    from_dispositions =
      Scrub.dispositions() |> Map.values() |> MapSet.new(fn {_kind, key} -> key end)

    from_summary = Scrub.run([]) |> Map.delete(:admin_provisioned) |> Map.keys() |> MapSet.new()

    assert from_dispositions == from_summary
  end
end
