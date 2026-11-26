defmodule KilnCMS.CMS.ReservedRouteSlugsTest do
  @moduledoc """
  Routes declared ahead of `/:slug` that the reserved list missed (#2898):
  `GET /developers`, `/ready`, `/setup`, `/sign-out`, `/actor`, … are served
  before delivery, so a page slugged after one was saved but never reachable.
  New writes are now refused; records stored before are listed by
  `mix kiln.reserved_paths`, and a dynamic type whose segment was reserved
  later can still be edited.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.ReservedPathAudit
  alias KilnCMS.CMS.SlugRegeneration

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "admin-rrs-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "rrs-#{System.unique_integer([:positive])}"

  describe "a page slug" do
    for reserved <- ~w(developers ready setup sign-out sign-in actor mcp) do
      test "#{reserved} is refused" do
        assert {:error, error} =
                 CMS.create_page(%{title: "T", slug: unquote(reserved)}, actor: admin())

        assert Exception.message(error) =~ "conflicts with the /#{unquote(reserved)} section URL"
      end
    end

    test "sitemap.xml is refused by the slug format" do
      assert {:error, _} = CMS.create_page(%{title: "T", slug: "sitemap.xml"}, actor: admin())
    end

    test "changed to a reserved one on update is refused" do
      actor = admin()
      page = CMS.create_page!(%{title: "T", slug: slug()}, actor: actor)

      assert {:error, error} = CMS.update_page(page, %{slug: "developers"}, actor: actor)
      assert Exception.message(error) =~ "conflicts with the /developers section URL"
    end

    test "derived from a title steps around a reserved one" do
      page = CMS.create_page!(%{title: "Developers"}, actor: admin())
      assert page.slug == "developers-2"
    end

    test "regenerated from a title steps around a reserved one" do
      actor = admin()
      page = CMS.create_page!(%{title: "Before the rename"}, actor: actor)
      CMS.update_page!(page, %{title: "Developers"}, actor: actor)

      SlugRegeneration.run(:page, KilnCMS.Accounts.default_org_id(),
        include_pinned: true,
        actor: actor
      )

      assert CMS.get_page!(page.id, actor: actor).slug == "developers-2"
    end
  end

  test "a path alias starting with a newly reserved segment is refused" do
    assert {:error, error} =
             CMS.create_post(%{title: "T", slug: slug(), path_alias: "/developers/old"},
               actor: admin()
             )

    assert Exception.message(error) =~ "starts with a URL segment the system already owns"
  end

  test "a post slug is not refused: it lives under /blog/" do
    assert CMS.create_post!(%{title: "T", slug: "developers"}, actor: admin()).slug ==
             "developers"
  end

  test "a page stored before the segment was reserved still reads, and is reported" do
    actor = admin()
    page = CMS.create_page!(%{title: "Our developers", slug: slug()}, actor: actor)

    # Raw SQL: a row written before the rule, so no action or validation runs.
    KilnCMS.Repo.query!("UPDATE pages SET slug = 'developers' WHERE id = $1", [
      Ecto.UUID.dump!(page.id)
    ])

    assert %{slug: "developers"} = CMS.get_page!(page.id, actor: actor)

    assert %{kind: :slug, path: "/developers"} =
             Enum.find(ReservedPathAudit.report(), &(&1.id == page.id))

    # Editing anything but the slug still saves.
    assert %{title: "Renamed"} = CMS.update_page!(page, %{title: "Renamed"}, actor: actor)
  end

  describe "a dynamic type's path segment" do
    test "cannot be newly set to a reserved route" do
      assert {:error, _} =
               CMS.create_type_definition(
                 %{
                   name: "dyn#{System.unique_integer([:positive])}",
                   label: "X",
                   path_segment: "ready"
                 },
                 actor: admin()
               )
    end

    test "taken before it was reserved does not block later edits" do
      legacy =
        Ash.Seed.seed!(CMS.TypeDefinition, %{
          name: "dyn#{System.unique_integer([:positive])}",
          label: "Legacy",
          path_segment: "developers",
          org_id: KilnCMS.Accounts.default_org_id()
        })

      assert %{label: "Renamed"} =
               CMS.update_type_definition!(legacy, %{label: "Renamed"}, actor: admin())
    end
  end

  describe "plugin routes" do
    defmodule RoutesPlugin do
      @moduledoc false
      def public_routes, do: [{"/book", __MODULE__, :index}, {"book/confirm", __MODULE__, :show}]
      def plug_routes, do: [{:post, "/hooks/stripe", __MODULE__, []}]
    end

    test "reserve the first segment of each public and plug route" do
      assert Enum.sort(ContentTypes.plugin_route_roots([RoutesPlugin])) == ["book", "hooks"]
    end

    test "reserve nothing when no plugin declares a route" do
      assert ContentTypes.plugin_route_roots([]) == []
    end
  end
end
