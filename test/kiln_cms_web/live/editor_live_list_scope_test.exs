defmodule KilnCMSWeb.EditorLive.ListScopeTest do
  @moduledoc """
  The list's scope without a socket (#2293): the export links the screen
  offers and the bounded count behind "Export N matching".
  """
  # async: false — the row cap is `Application` env, put back on exit.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.Page
  alias KilnCMSWeb.EditorLive.Filters
  alias KilnCMSWeb.EditorLive.ListScope

  @ctx %{types: ["page", "post"], locales: ["en"]}

  defp filters(params), do: Filters.parse(params, @ctx)

  describe "export_path/3" do
    test "carries only the filters that differ from the default" do
      assert ListScope.export_path(:csv, filters(%{})) == "/editor/content/export.csv"

      path = ListScope.export_path(:json, filters(%{"type" => "page", "status" => "draft"}))
      assert %URI{path: "/editor/content/export.json", query: query} = URI.parse(path)
      assert URI.decode_query(query) == %{"type" => "page", "status" => "draft"}
    end

    test "a selection carries the type and ids but none of the other filters" do
      ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      f = filters(%{"type" => "page", "status" => "draft", "q" => "x"})

      %URI{query: query} = :csv |> ListScope.export_path(f, ids: ids) |> URI.parse()
      assert URI.decode_query(query) == %{"type" => "page", "ids" => Enum.join(ids, ",")}
    end

    test "the private opt-in is a param" do
      %URI{query: query} =
        :csv |> ListScope.export_path(filters(%{}), private?: true) |> URI.parse()

      assert URI.decode_query(query) == %{"private" => "1"}
    end
  end

  describe "export_count/6" do
    setup do
      original = Application.get_env(:kiln_cms, :content_export)

      on_exit(fn ->
        if original,
          do: Application.put_env(:kiln_cms, :content_export, original),
          else: Application.delete_env(:kiln_cms, :content_export)
      end)

      admin =
        Ash.Seed.seed!(User, %{
          email: "scope-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      %{admin: admin, org: Accounts.default_org()}
    end

    test "is exact up to the cap and :over_cap past it", %{admin: admin, org: org} do
      prefix = "Scope#{System.unique_integer([:positive])}"

      for n <- 1..3 do
        Ash.Seed.seed!(Page, %{title: "#{prefix} #{n}", slug: "sc-#{prefix}-#{n}", state: :draft})
      end

      types = ListScope.filtered_types(ListScope.types(admin, org), "page")
      f = filters(%{"type" => "page", "q" => prefix})

      assert {:ok, 3} = ListScope.export_count(types, f, admin, org, [])

      Application.put_env(:kiln_cms, :content_export, max_rows: 3)
      assert {:ok, 3} = ListScope.export_count(types, f, admin, org, [])

      Application.put_env(:kiln_cms, :content_export, max_rows: 2)
      assert :over_cap = ListScope.export_count(types, f, admin, org, [])
    end
  end
end
