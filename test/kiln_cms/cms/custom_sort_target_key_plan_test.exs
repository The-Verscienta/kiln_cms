defmodule KilnCMS.CMS.CustomSortTargetKeyPlanTest do
  @moduledoc """
  The plan of a `custom_sort` on a reference field at scale (#2444): 20,000
  published referrers over 2,000 targets. The key is a correlated primary-key
  probe per referrer (`Relations.sort_key/2`), so the assertion is the shape
  the cost rests on — each probe is an index lookup on the target's primary
  key, never a scan of the target table — not a wall-clock bound.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Repo

  @referrers 20_000
  @targets 2_000

  test "each probe is a primary-key lookup, for an editor and for an anonymous reader" do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "cstkp-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    org_id = KilnCMS.Accounts.default_org_id()
    org = Ecto.UUID.dump!(org_id)
    field = "plan_ref"

    CMS.create_field_definition!(
      %{
        content_type: :page,
        label: "Ref",
        name: field,
        field_type: :reference,
        target_type: "page"
      },
      actor: admin
    )

    Repo.query!(
      """
      INSERT INTO pages (id, title, slug, org_id, locale, state, custom_fields)
      SELECT gen_random_uuid(), 'cstkp target ' || lpad(i::text, 5, '0'), 'cstkp-t-' || i, $1, 'en',
             CASE WHEN i % 10 = 0 THEN 'draft' ELSE 'published' END, '{}'::jsonb
      FROM generate_series(1, $2) AS i
      """,
      [org, @targets]
    )

    Repo.query!(
      """
      INSERT INTO pages (id, title, slug, org_id, locale, state, custom_fields)
      SELECT gen_random_uuid(), 'cstkp referrer', 'cstkp-r-' || i, $1, 'en', 'published',
             jsonb_build_object($3::text, jsonb_build_object('id', t.id, 'type', 'page', 'slug', t.slug, 'title', t.title))
      FROM generate_series(1, $2) AS i
      JOIN LATERAL (SELECT id, slug, title FROM pages
                     WHERE slug = 'cstkp-t-' || (i % $4 + 1)) t ON true
      """,
      [org, @referrers, field, @targets]
    )

    Repo.query!("ANALYZE pages")

    for actor <- [admin, nil], sort <- [field, "-" <> field] do
      {sql, params} =
        capture(fn ->
          CMS.list_pages!(%{custom_sort: sort},
            actor: actor,
            tenant: org_id,
            page: [limit: 20],
            query: [filter: [title: "cstkp referrer"]]
          )
        end)

      plan =
        Repo.query!("EXPLAIN (ANALYZE, FORMAT TEXT) " <> sql, params).rows
        |> Enum.map_join("\n", &hd/1)

      # The probe is the subplan aliased `sp0`; the outer scan of the referrers
      # is `p0` and is the one scan the read is allowed.
      assert plan =~ "Index Scan using pages_pkey on pages sp0", plan
      refute plan =~ "Seq Scan on pages sp0", plan
      assert plan =~ "top-N heapsort", plan
    end
  end

  defp capture(fun) do
    test = self()
    handler = "cstkp-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _m, meta, _c ->
        if self() == test and meta[:source] == "pages" and meta[:query] =~ "ORDER BY",
          do: send(test, {:captured, meta[:query], meta[:params]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    receive_last(nil)
  end

  defp receive_last(last) do
    receive do
      {:captured, sql, params} -> receive_last({sql, params})
    after
      0 -> last || flunk("no query captured")
    end
  end
end
