defmodule KilnCMS.CMS.CustomSortTargetKeyTest do
  @moduledoc """
  `custom_sort` on a single `:reference` / `:media` field (#2444): the key is
  the target's *current* title (filename), `NULL` where the caller cannot read
  the target, so an unreadable target's order is never revealed — across a
  rename, a draft target, a keyset page boundary and a polymorphic field.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cstk-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp name(base), do: "#{base}#{System.unique_integer([:positive])}"
  defp slug, do: "cstk-#{System.unique_integer([:positive])}"

  defp define!(attrs, admin) do
    CMS.create_field_definition!(Map.merge(%{content_type: :page, label: "Field"}, attrs),
      actor: admin
    )
  end

  defp target!(admin, title, publish?) do
    page = CMS.create_page!(%{title: title, slug: slug()}, actor: admin)
    if publish?, do: CMS.publish_page!(page, %{}, actor: admin), else: page
  end

  # A published referrer (readable anonymously) pointing at `value` under `field`.
  defp referrer!(admin, scope, field, value) do
    fields = if value, do: %{field => value}, else: %{}

    page =
      CMS.create_page!(%{title: scope, slug: slug(), custom_fields: fields}, actor: admin)

    CMS.publish_page!(page, %{}, actor: admin)
  end

  # Keyset-paged, one page wide: keyset reads add the primary key as the final
  # tie-break, which an unpaged read does not guarantee (ties are arbitrary).
  defp ids(sort, scope, actor, opts \\ [page: [limit: 100]]) do
    %{custom_sort: sort}
    |> CMS.list_pages!([actor: actor, query: [filter: [title: scope]]] ++ opts)
    |> then(&if(is_struct(&1, Ash.Page.Keyset), do: &1.results, else: &1))
    |> Enum.map(& &1.id)
  end

  setup do
    admin = user(:admin)
    field = name("ref")
    define!(%{name: field, field_type: :reference, target_type: "page"}, admin)
    {:ok, admin: admin, field: field, scope: "scope-#{System.unique_integer([:positive])}"}
  end

  test "orders by the target's current title, not the stored snapshot", ctx do
    %{admin: admin, field: field, scope: scope} = ctx
    cherry = target!(admin, "Cherry", true)
    apple = target!(admin, "Apple", true)
    banana = target!(admin, "Banana", true)

    r_cherry = referrer!(admin, scope, field, cherry.id)
    r_apple = referrer!(admin, scope, field, apple.id)
    r_banana = referrer!(admin, scope, field, banana.id)
    unset = referrer!(admin, scope, field, nil)

    assert ids(field, scope, admin) == [r_apple.id, r_banana.id, r_cherry.id, unset.id]
    assert ids("-" <> field, scope, admin) == [r_cherry.id, r_banana.id, r_apple.id, unset.id]

    # Renamed after the referrers were saved: their snapshots still say
    # "Apple", the key follows the target.
    CMS.update_page!(apple, %{title: "Zucchini"}, actor: admin)

    assert ids(field, scope, admin) == [r_banana.id, r_cherry.id, r_apple.id, unset.id]
  end

  test "an unreadable target has no key: its title cannot move it", ctx do
    %{admin: admin, field: field, scope: scope} = ctx
    pub_a = target!(admin, "Alpha", true)
    pub_z = target!(admin, "Zulu", true)
    draft = target!(admin, "Mmm", false)

    r_a = referrer!(admin, scope, field, pub_a.id)
    r_z = referrer!(admin, scope, field, pub_z.id)
    r_draft = referrer!(admin, scope, field, draft.id)
    unset = referrer!(admin, scope, field, nil)

    tail = Enum.sort([r_draft.id, unset.id])

    # An anonymous reader sees the draft target as unset (the read masks it),
    # so the draft's referrer sorts with the unset ones, by id, whatever the
    # draft is called.
    assert ids(field, scope, nil) == [r_a.id, r_z.id | tail]
    assert ids("-" <> field, scope, nil) == [r_z.id, r_a.id | tail]

    draft = CMS.update_page!(draft, %{title: "Aaa first"}, actor: admin)
    assert ids(field, scope, nil) == [r_a.id, r_z.id | tail]

    draft = CMS.update_page!(draft, %{title: "Zzz last"}, actor: admin)
    assert ids(field, scope, nil) == [r_a.id, r_z.id | tail]

    # An editor can read the draft, so it takes its place by title.
    CMS.update_page!(draft, %{title: "Mmm"}, actor: admin)
    assert ids(field, scope, admin) == [r_a.id, r_draft.id, r_z.id, unset.id]
  end

  test "keyset pages across the boundary, ties and NULLs included", ctx do
    %{admin: admin, field: field, scope: scope} = ctx
    shared = target!(admin, "Same", true)
    other = target!(admin, "Other", true)
    draft = target!(admin, "Hidden", false)

    for target <- [shared, shared, other, draft, nil, nil] do
      referrer!(admin, scope, field, target && target.id)
    end

    for actor <- [admin, nil], sort <- [field, "-" <> field] do
      full = ids(sort, scope, actor)
      assert length(full) == 6

      walked =
        Stream.unfold(nil, fn
          :done ->
            nil

          cursor ->
            page_opts = [limit: 2] ++ if(cursor, do: [after: cursor], else: [])

            page =
              CMS.list_pages!(%{custom_sort: sort},
                actor: actor,
                page: page_opts,
                query: [filter: [title: scope]]
              )

            {Enum.map(page.results, & &1.id),
             if(page.more?, do: List.last(page.results).__metadata__.keyset, else: :done)}
        end)
        |> Enum.to_list()

      assert List.flatten(walked) == full
      assert length(walked) == 3
    end
  end

  test "a polymorphic reference orders across its target types", ctx do
    %{admin: admin, scope: scope} = ctx
    field = name("poly")
    define!(%{name: field, field_type: :reference, target_types: ["page", "post"]}, admin)

    page = target!(admin, "Beta", true)

    post =
      CMS.create_post!(%{title: "Alpha", slug: slug()}, actor: admin)
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))

    r_page = referrer!(admin, scope, field, %{"id" => page.id, "type" => "page"})
    r_post = referrer!(admin, scope, field, %{"id" => post.id, "type" => "post"})

    assert ids(field, scope, nil) == [r_post.id, r_page.id]
  end

  test "a media field orders by the item's current filename, NULL when unreadable", ctx do
    %{admin: admin, scope: scope} = ctx
    field = name("hero")
    define!(%{name: field, field_type: :media}, admin)

    item = fn filename, audience ->
      Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
        filename: filename,
        url: "/uploads/#{System.unique_integer([:positive])}.png",
        audience: audience
      })
    end

    b = item.("b.png", :public)
    a = item.("a.png", :public)
    private = item.("0-private.png", :member)

    r_b = referrer!(admin, scope, field, b.id)
    r_a = referrer!(admin, scope, field, a.id)
    r_private = referrer!(admin, scope, field, private.id)

    assert ids(field, scope, nil) == [r_a.id, r_b.id, r_private.id]
    assert ids("-" <> field, scope, nil) == [r_b.id, r_a.id, r_private.id]

    Ash.Seed.update!(a, %{filename: "z.png"})
    assert ids(field, scope, nil) == [r_b.id, r_a.id, r_private.id]
    assert ids(field, scope, admin) == [r_private.id, r_b.id, r_a.id]
  end

  test "a multiple field is refused", ctx do
    %{admin: admin} = ctx
    field = name("many")
    define!(%{name: field, field_type: :reference, target_type: "page", multiple: true}, admin)

    assert {:error, %Ash.Error.Invalid{} = error} =
             CMS.list_pages(%{custom_sort: field}, actor: admin)

    assert Exception.message(error) =~ "holds a list and is not sortable"
  end

  test "a snapshot id from another organization has no key", ctx do
    %{admin: admin, field: field, scope: scope} = ctx

    other_org =
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "Other #{System.unique_integer([:positive])}",
        slug: "other-#{System.unique_integer([:positive])}"
      })

    foreign =
      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Aaa foreign",
        slug: slug(),
        locale: "en",
        state: :published,
        org_id: other_org.id
      })

    own = target!(admin, "Mmm own", true)
    r_foreign = referrer!(admin, scope, field, own.id)

    # Forge the snapshot: the stored id names a published page of another org.
    Ash.Seed.update!(r_foreign, %{
      custom_fields: %{
        field => %{"id" => foreign.id, "type" => "page", "slug" => "x", "title" => "x"}
      }
    })

    r_own = referrer!(admin, scope, field, own.id)

    assert ids(field, scope, nil) == [r_own.id, r_foreign.id]
    assert ids("-" <> field, scope, nil) == [r_own.id, r_foreign.id]
  end
end
