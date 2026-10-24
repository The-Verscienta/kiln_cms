defmodule KilnCMS.RelatedLinkSpikeTest do
  use KilnCMS.DataCase, async: true
  alias KilnCMS.CMS

  defp user(role),
    do:
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "s#{System.unique_integer([:positive])}@x.com",
        hashed_password: "x",
        confirmed_at: DateTime.utc_now(),
        role: role
      })

  defp slug, do: "s#{System.unique_integer([:positive])}"
  defp titles(list), do: Enum.map(list, & &1.title)

  setup do
    admin = user(:admin)

    [src, a, b, c, d] =
      for t <- ~w(S A B C D), do: CMS.create_post!(%{title: t, slug: slug()}, actor: admin)

    [a, b, c] = for p <- [a, b, c], do: CMS.publish_post!(p, %{}, actor: admin)
    %{admin: admin, src: src, a: a, b: b, c: c, d: d}
  end

  test "1. complete set: loads in position order for every reader", ctx do
    src =
      CMS.update_post!(ctx.src, %{related_post_ids: [ctx.c.id, ctx.a.id, ctx.b.id]},
        actor: ctx.admin
      )

    src = CMS.publish_post!(src, %{}, actor: ctx.admin)
    editor = user(:editor)

    for actor <- [ctx.admin, editor, nil] do
      got = CMS.get_post!(src.id, actor: actor, load: [:related_posts]).related_posts
      assert titles(got) == ~w(C A B), inspect(actor && actor.role)
    end

    src =
      CMS.update_post!(src, %{related_post_ids: [ctx.b.id, ctx.c.id, ctx.a.id]}, actor: ctx.admin)

    assert titles(Ash.load!(src, :related_posts, actor: ctx.admin).related_posts) == ~w(B C A)
  end

  test "2. many sources in one read, each in its own order; limit per source", ctx do
    s1 =
      CMS.update_post!(ctx.src, %{related_post_ids: [ctx.c.id, ctx.a.id, ctx.b.id]},
        actor: ctx.admin
      )

    s2 =
      CMS.create_post!(
        %{title: "S2", slug: slug(), related_post_ids: [ctx.b.id, ctx.c.id, ctx.a.id]},
        actor: ctx.admin
      )

    got =
      CMS.list_posts!(
        actor: ctx.admin,
        query: [filter: [id: [in: [s1.id, s2.id]]]],
        load: [:related_posts]
      )
      |> Map.new(&{&1.title, titles(&1.related_posts)})

    assert got == %{"S" => ~w(C A B), "S2" => ~w(B C A)}

    limited =
      CMS.list_posts!(
        actor: ctx.admin,
        query: [filter: [id: [in: [s1.id, s2.id]]]],
        load: [related_posts: Ash.Query.limit(KilnCMS.CMS.Post, 2)]
      )
      |> Map.new(&{&1.title, titles(&1.related_posts)})

    assert limited == %{"S" => ~w(C A), "S2" => ~w(B C)}
  end

  test "3. a draft target is hidden from anonymous readers, order kept", ctx do
    src =
      CMS.update_post!(ctx.src, %{related_post_ids: [ctx.c.id, ctx.d.id, ctx.a.id]},
        actor: ctx.admin
      )

    src = CMS.publish_post!(src, %{}, actor: ctx.admin)

    assert titles(CMS.get_post!(src.id, actor: nil, load: [:related_posts]).related_posts) ==
             ~w(C A)

    assert titles(CMS.get_post!(src.id, actor: ctx.admin, load: [:related_posts]).related_posts) ==
             ~w(C D A)
  end

  test "4. add/remove verbs and unrelate write only related rows", ctx do
    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: "buddy",
        label: "Buddy",
        field_type: :reference,
        target_type: "post"
      }, actor: ctx.admin)

    src =
      CMS.update_post!(
        ctx.src,
        %{related_post_ids: [ctx.a.id, ctx.b.id], custom_fields: %{"buddy" => ctx.a.id}},
        actor: ctx.admin
      )

    src = CMS.update_post!(src, %{add_related_post_ids: [ctx.c.id]}, actor: ctx.admin)
    assert titles(Ash.load!(src, :related_posts, actor: ctx.admin).related_posts) == ~w(A B C)

    # A is both related and referenced: removing it from related must keep the reference edge.
    src = CMS.update_post!(src, %{remove_related_post_ids: [ctx.a.id]}, actor: ctx.admin)
    assert titles(Ash.load!(src, :related_posts, actor: ctx.admin).related_posts) == ~w(B C)

    links =
      CMS.list_content_links!(
        actor: KilnCMS.CMS.Bookkeeping.system(),
        tenant: src.org_id,
        query: [filter: [source_id: src.id]]
      )
      |> Enum.map(&{&1.kind, &1.target_id})
      |> Enum.sort()

    assert {:reference, ctx.a.id} in links
    refute {:related, ctx.a.id} in links

    src = CMS.update_post!(src, %{related_post_ids: []}, actor: ctx.admin)
    assert Ash.load!(src, :related_posts, actor: ctx.admin).related_posts == []

    assert {:reference, ctx.a.id} in Enum.map(
             CMS.list_content_links!(
               actor: KilnCMS.CMS.Bookkeeping.system(),
               tenant: src.org_id,
               query: [filter: [source_id: src.id]]
             ),
             &{&1.kind, &1.target_id}
           )
  end

  test "5. a cross-type :related payload link does not leak in", ctx do
    page = CMS.create_page!(%{title: "P", slug: slug()}, actor: ctx.admin)
    src = CMS.update_post!(ctx.src, %{related_post_ids: [ctx.a.id]}, actor: ctx.admin)

    CMS.create_content_link!(%{source_id: src.id, target_id: page.id, kind: :related},
      actor: ctx.admin,
      tenant: src.org_id
    )

    assert titles(Ash.load!(src, :related_posts, actor: ctx.admin).related_posts) == ~w(A)
  end

  test "6. SQL", ctx do
    s1 =
      CMS.update_post!(ctx.src, %{related_post_ids: [ctx.c.id, ctx.a.id, ctx.b.id]},
        actor: ctx.admin
      )

    me = self()

    :telemetry.attach(
      "spike-sql",
      [:kiln_cms, :repo, :query],
      fn _, _, meta, _ -> send(me, {:sql, meta.query}) end,
      nil
    )

    CMS.list_posts!(
      actor: ctx.admin,
      query: [filter: [id: [in: [s1.id]]]],
      load: [related_posts: [:title]]
    )

    :telemetry.detach("spike-sql")
    sqls = collect([])
    IO.puts("QUERIES: #{length(sqls)}")
    for q <- sqls, q =~ "content_links", do: IO.puts("SQL>> " <> q)
  end

  defp collect(acc) do
    receive do
      {:sql, q} -> collect([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
