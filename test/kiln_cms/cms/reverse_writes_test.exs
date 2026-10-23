defmodule KilnCMS.CMS.ReverseWritesTest do
  @moduledoc """
  Workstream R4b of `docs/relationships-plan.md` (decision D23): adding,
  removing and reordering a connection from the target's side is an edit of
  the **source** — its own update, as the caller, so policies, the source's
  validations, versioning and the optimistic lock all apply, and a published
  source's change waits in its working copy until it is published.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.ReverseFields

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "reverse-w-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "reverse-w-#{uniq()}"

  defp page!(admin, title),
    do: CMS.create_page!(%{title: title, slug: slug()}, actor: admin)

  defp post!(admin, title, fields, opts \\ []) do
    post = CMS.create_post!(%{title: title, slug: slug(), custom_fields: fields}, actor: admin)
    if opts[:publish], do: CMS.publish_post!(post, %{}, actor: admin), else: post
  end

  defp reload(post), do: CMS.get_post!(post.id, authorize?: false)

  defp ids(post, field),
    do: post.custom_fields |> Map.get(field) |> List.wrap() |> Enum.map(& &1["id"])

  defp edges(target, field) do
    CMS.list_content_links!(
      authorize?: false,
      query: [
        filter: [target_id: target.id, kind: :reference, field: field],
        sort: [position: :asc]
      ]
    )
  end

  defp rows(target, reverse, actor),
    do: ReverseFields.rows(target, reverse, actor: actor).rows |> Map.new(&{&1.source.id, &1})

  setup do
    admin = user(:admin)

    field =
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "ingredients_#{uniq()}",
          label: "Ingredients",
          field_type: :reference,
          target_type: "page",
          multiple: true,
          max_items: 3,
          inverse_label: "Used in"
        },
        actor: admin
      )

    note =
      CMS.create_field_definition!(
        %{content_type: :post, name: "note_#{uniq()}", label: "Note", field_type: :string},
        actor: admin
      )

    [reverse] = ReverseFields.for_type(:page, nil)
    target = page!(admin, "Flour")
    other = page!(admin, "Sugar")

    %{
      admin: admin,
      field: field.name,
      note: note.name,
      reverse: reverse,
      target: target,
      other: other
    }
  end

  describe "on a draft source" do
    test "connect appends to the source's own value, keeps its other fields, and versions it",
         ctx do
      source = post!(ctx.admin, "Cake", %{ctx.field => [ctx.other.id], ctx.note => "keep me"})

      versions =
        length(
          ContentTypes.list_versions!(:post,
            authorize?: false,
            query: [filter: [version_source_id: source.id]]
          )
        )

      assert {:ok, _source} =
               ReverseFields.connect(ctx.target, ctx.reverse, source, actor: ctx.admin)

      source = reload(source)
      assert ids(source, ctx.field) == [ctx.other.id, ctx.target.id]
      assert source.custom_fields[ctx.note] == "keep me"
      assert [%{position: 1}] = edges(ctx.target, ctx.field)

      assert length(
               ContentTypes.list_versions!(:post,
                 authorize?: false,
                 query: [filter: [version_source_id: source.id]]
               )
             ) >
               versions
    end

    test "disconnect and move rewrite the list, edges and all", ctx do
      source = post!(ctx.admin, "Cake", %{ctx.field => [ctx.other.id, ctx.target.id]})

      assert {:ok, source} =
               ReverseFields.move(ctx.target, ctx.reverse, source, :up, actor: ctx.admin)

      assert ids(reload(source), ctx.field) == [ctx.target.id, ctx.other.id]
      assert [%{position: 0}] = edges(ctx.target, ctx.field)

      assert {:ok, _source} =
               ReverseFields.disconnect(ctx.target, ctx.reverse, source, actor: ctx.admin)

      assert ids(reload(source), ctx.field) == [ctx.other.id]
      assert edges(ctx.target, ctx.field) == []
    end

    test "the source's own rules apply: max_items refuses a fourth connection", ctx do
      full = for t <- ["A", "B", "C"], do: page!(ctx.admin, t).id
      source = post!(ctx.admin, "Cake", %{ctx.field => full})

      assert {:error, %Ash.Error.Invalid{}} =
               ReverseFields.connect(ctx.target, ctx.reverse, source, actor: ctx.admin)

      assert ids(reload(source), ctx.field) == full
    end

    test "a single reference that already connects another record is not taken over", ctx do
      single =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "hero_#{uniq()}",
            label: "Hero",
            field_type: :reference,
            target_type: "page",
            inverse_label: "Hero of"
          },
          actor: ctx.admin
        )

      reverse = ReverseFields.find(:page, single.inverse_name, nil)
      taken = post!(ctx.admin, "Taken", %{single.name => ctx.other.id})
      empty = post!(ctx.admin, "Empty", %{})

      assert {:error, :occupied} =
               ReverseFields.connect(ctx.target, reverse, taken, actor: ctx.admin)

      assert {:ok, _} = ReverseFields.connect(ctx.target, reverse, empty, actor: ctx.admin)
      assert reload(empty).custom_fields[single.name]["id"] == ctx.target.id

      assert {:ok, _} =
               ReverseFields.disconnect(ctx.target, reverse, reload(empty), actor: ctx.admin)

      assert reload(empty).custom_fields[single.name] in [nil, ""]
    end
  end

  describe "on a published source" do
    test "a connection lands in the working copy and shows as pending until published", ctx do
      source = post!(ctx.admin, "Bread", %{ctx.field => [ctx.other.id]}, publish: true)

      assert {:ok, _} = ReverseFields.connect(ctx.target, ctx.reverse, source, actor: ctx.admin)

      source = reload(source)
      assert ids(source, ctx.field) == [ctx.other.id], "the live value is untouched"
      assert edges(ctx.target, ctx.field) == []

      assert %{pending: :add, link: %{position: 1}} =
               rows(ctx.target, ctx.reverse, ctx.admin)[source.id]

      # An anonymous reader sees nothing of it.
      assert ReverseFields.rows(ctx.target, ctx.reverse, actor: nil).rows == []

      CMS.publish_post_changes!(source, %{}, actor: ctx.admin)
      assert %{pending: nil} = rows(ctx.target, ctx.reverse, ctx.admin)[source.id]
      assert [_edge] = edges(ctx.target, ctx.field)
    end

    test "removing and reordering are pending too", ctx do
      source =
        post!(ctx.admin, "Bread", %{ctx.field => [ctx.other.id, ctx.target.id]}, publish: true)

      assert {:ok, _} = ReverseFields.move(ctx.target, ctx.reverse, source, :up, actor: ctx.admin)
      assert %{pending: :move} = rows(ctx.target, ctx.reverse, ctx.admin)[source.id]

      assert {:ok, _} =
               ReverseFields.disconnect(ctx.target, ctx.reverse, reload(source), actor: ctx.admin)

      assert %{pending: :remove} = rows(ctx.target, ctx.reverse, ctx.admin)[source.id]
      assert ids(reload(source), ctx.field) == [ctx.other.id, ctx.target.id]
    end
  end

  test "a lock conflict fails that source only", ctx do
    stale = post!(ctx.admin, "Stale", %{})
    fresh = post!(ctx.admin, "Fresh", %{})

    # Someone else saves `stale` after the reverse list read it.
    CMS.update_post!(stale, %{custom_fields: %{ctx.note => "theirs"}}, actor: ctx.admin)

    assert {:error, error} =
             ReverseFields.connect(ctx.target, ctx.reverse, stale, actor: ctx.admin)

    assert KilnCMSWeb.InlineEditing.stale_conflict?(error)
    assert {:ok, _} = ReverseFields.connect(ctx.target, ctx.reverse, fresh, actor: ctx.admin)

    assert ids(reload(stale), ctx.field) == []
    assert ids(reload(fresh), ctx.field) == [ctx.target.id]
  end

  # R1b's cap runs inside the source's update (`ContentLinks.reconcile`), so
  # a connect from the target's side meets it exactly as the source's own
  # editor would — refused, with the source left as it was.
  describe "a target full under max_sources" do
    setup ctx do
      [definition] =
        CMS.list_field_definitions!(
          authorize?: false,
          query: [filter: [content_type: :post, name: ctx.field]]
        )

      CMS.update_field_definition!(definition, %{max_sources: 1}, actor: ctx.admin)
      %{reverse: ReverseFields.find(:page, ctx.reverse.name, nil)}
    end

    test "refuses a connect from a draft source and leaves it untouched", ctx do
      first = post!(ctx.admin, "Cake", %{})
      second = post!(ctx.admin, "Bread", %{ctx.field => [ctx.other.id]})

      assert {:ok, _} = ReverseFields.connect(ctx.target, ctx.reverse, first, actor: ctx.admin)

      assert {:error, %Ash.Error.Invalid{} = error} =
               ReverseFields.connect(ctx.target, ctx.reverse, second, actor: ctx.admin)

      assert Exception.message(error) =~ "is full: it already has 1 of 1"
      assert ids(reload(second), ctx.field) == [ctx.other.id]
      assert [%{source_id: source_id}] = edges(ctx.target, ctx.field)
      assert source_id == first.id
    end

    test "frees a slot when the connected source lets go", ctx do
      first = post!(ctx.admin, "Cake", %{})
      second = post!(ctx.admin, "Bread", %{})

      assert {:ok, _} = ReverseFields.connect(ctx.target, ctx.reverse, first, actor: ctx.admin)

      assert {:ok, _} =
               ReverseFields.disconnect(ctx.target, ctx.reverse, reload(first), actor: ctx.admin)

      assert {:ok, _} = ReverseFields.connect(ctx.target, ctx.reverse, second, actor: ctx.admin)
      assert ids(reload(second), ctx.field) == [ctx.target.id]
    end
  end

  test "a source the caller may not update is not editable, and the write is refused", ctx do
    source = post!(ctx.admin, "Cake", %{})
    editor = user(:editor, %{readable_types: ["page", "post"], editable_types: ["page"]})

    refute ReverseFields.editable?(source, ctx.reverse, editor, [])
    assert ReverseFields.editable?(source, ctx.reverse, ctx.admin, [])

    assert {:error, %Ash.Error.Forbidden{}} =
             ReverseFields.connect(ctx.target, ctx.reverse, source, actor: editor)

    assert ids(reload(source), ctx.field) == []
  end
end
