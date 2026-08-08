defmodule KilnCMS.CMS.AnonymousRuleSurfacesTest do
  @moduledoc """
  One rule, several expressions of it, asserted together (#1013).

  "May an anonymous visitor read this?" — published, `audience: :public`, and no
  passphrase — is stated in one Elixir function
  (`KilnCMS.CMS.Audiences.public_to_anonymous?/1`) and in several Ash `expr`
  filters that cannot call it: the `pinned_state` behind the three search twins,
  `Slugs.find_published_by_alias/5`, the feed controller.

  `read :published` is the deliberate exception and is asserted as one below —
  an index is a discovery surface, and the blog index publishes gated titles to
  anonymous visitors on purpose.

  Comments bind them today. This binds them with a test: every surface below is
  handed the same three documents and must return exactly the open one. A future
  edit that widens one expression and not the others fails here, naming the
  surface, instead of being found by whoever was relying on it.

  The credential is the point. Each call carries an **admin** actor, because
  that is the case the read policy does not cover: the `OrgAdmin` bypass
  authorizes an admin past both the audience grant and the passphrase check, and
  a bearer API key authorizes as the account that minted it. A delivery site
  handed an admin-minted key is not a hypothetical — it is what
  `docs/headless-consumer-guide.md` warns about.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  setup do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "anonrule-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    term = "anonrule#{System.unique_integer([:positive])}"

    open = published_post("#{term} open", %{}, actor)
    gated = published_post("#{term} members", %{audience: :member}, actor)

    locked =
      "#{term} locked"
      |> published_post(%{}, actor)
      |> then(&CMS.update_post!(&1, %{access_password: "shared secret"}, actor: actor))

    %{actor: actor, term: term, open: open, gated: gated, locked: locked}
  end

  defp published_post(title, attrs, actor) do
    attrs
    |> Map.merge(%{title: title, slug: "anonrule-#{System.unique_integer([:positive])}"})
    |> CMS.create_post!(actor: actor)
    |> then(&CMS.publish_post!(&1, %{}, actor: actor))
  end

  defp only_open(ids, ctx, surface) do
    assert ctx.open.id in ids, "#{surface} dropped the open document"
    refute ctx.gated.id in ids, "#{surface} returned an audience-gated document"
    refute ctx.locked.id in ids, "#{surface} returned a passphrase-locked document"
  end

  test "read :published is NOT one of these surfaces, deliberately", ctx do
    # The exception, asserted so nobody "fixes" it into line. An index is a
    # discovery surface, and gated metadata is public here by design:
    # `ContentController.blog_index/2` reads this action with
    # `authorize?: false` and renders a gated post with a "Members" badge
    # rather than hiding it (`PaywallDeliveryTest`). Narrowing it to
    # `audience == :public` takes the paywall teaser off the blog index.
    ids =
      CMS.list_published_posts!(actor: ctx.actor, tenant: ctx.open.org_id)
      |> Enum.map(& &1.id)

    assert ctx.open.id in ids
    assert ctx.gated.id in ids
  end

  test "search_published", ctx do
    ids =
      CMS.search_published_posts!(ctx.term, actor: ctx.actor, tenant: ctx.open.org_id)
      |> Enum.map(& &1.id)

    only_open(ids, ctx, "search_published")
  end

  test "autocomplete_published", ctx do
    ids =
      CMS.autocomplete_published_posts!(ctx.term, actor: ctx.actor, tenant: ctx.open.org_id)
      |> Enum.map(& &1.id)

    only_open(ids, ctx, "autocomplete_published")
  end

  test "the in-memory statement agrees with all of them", ctx do
    # The one that is a plain function, so the SQL and the Elixir cannot drift
    # in opposite directions without this failing.
    alias KilnCMS.CMS.Audiences

    assert Audiences.public_to_anonymous?(reload(ctx.open))
    refute Audiences.public_to_anonymous?(reload(ctx.gated))
    refute Audiences.public_to_anonymous?(reload(ctx.locked))
  end

  defp reload(record), do: Ash.reload!(record, authorize?: false, tenant: record.org_id)
end
