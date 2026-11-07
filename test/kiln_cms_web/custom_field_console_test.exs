defmodule KilnCMSWeb.CustomFieldConsoleTest do
  @moduledoc """
  The console surfaces of per-custom-field grants (#2281): the content editor's
  custom fields panel, the `/editor` list's column / filter options and the
  CSV / JSON export.

  A private field's canary value is stored on a page; an editor whose
  `field_read_grants` hides the field must not see the input, the column, or
  the value in any download (`private=1` included), while an unrestricted
  editor sees all three, so a broken seed cannot make the absence vacuous.
  A field the editor may read but whose write grant does not name it renders
  read-only, with a hint.
  """
  # async: false — `PrivateFields.all/1` is cached per org in a global cache,
  # and these tests define private fields on the shared default org.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMSWeb.EditorLive.ListScope

  @password "password123456"
  @canary "CANARY-c0n501e"

  defp uniq, do: System.unique_integer([:positive])

  defp seed(role, attrs \\ %{}) do
    email = "console-#{uniq()}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp define!(admin, name, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :page, name: name, label: String.capitalize(name), field_type: :string},
        attrs
      ),
      actor: admin
    )
  end

  setup do
    admin = seed(:admin)

    define!(admin, "notes")
    define!(admin, "summary")
    define!(admin, "secret", %{private: true})

    page =
      CMS.create_page!(
        %{
          title: "Console #{uniq()}",
          slug: "console-#{uniq()}",
          custom_fields: %{"notes" => "n", "summary" => "s", "secret" => @canary}
        },
        actor: admin
      )

    restricted = seed(:editor, %{field_read_grants: %{"page" => []}})
    open = seed(:editor)

    %{admin: admin, page: page, restricted: restricted, open: open}
  end

  describe "the editor panel" do
    test "a hidden private field is not rendered; an unrestricted editor sees it", ctx do
      {:ok, lv, html} =
        live(log_in(ctx.conn, ctx.restricted), ~p"/editor/content/page/#{ctx.page.id}")

      assert has_element?(lv, "#custom-field-notes")
      refute has_element?(lv, "#custom-field-secret")
      refute html =~ @canary

      {:ok, lv, html} =
        live(log_in(build_conn(), ctx.open), ~p"/editor/content/page/#{ctx.page.id}")

      assert has_element?(lv, "#custom-field-secret")
      assert html =~ @canary
    end

    test "saving as a restricted editor leaves the hidden value alone", ctx do
      {:ok, lv, _html} =
        live(log_in(ctx.conn, ctx.restricted), ~p"/editor/content/page/#{ctx.page.id}")

      lv
      |> form("#page-editor", %{"form" => %{"custom_fields" => %{"notes" => "changed"}}})
      |> render_change()

      lv |> form("#page-editor") |> render_submit()

      reread = CMS.get_page!(ctx.page.id, actor: ctx.admin)
      assert reread.custom_fields["notes"] == "changed"
      assert reread.custom_fields["secret"] == @canary
    end

    test "a field the write grant does not name is read-only, with a hint", ctx do
      editor = seed(:editor, %{field_grants: %{"page" => ["custom_fields.notes"]}})

      {:ok, lv, _html} = live(log_in(ctx.conn, editor), ~p"/editor/content/page/#{ctx.page.id}")

      refute has_element?(lv, "#cf-read-only-notes")
      assert has_element?(lv, "#cf-read-only-summary", "can see this field but not change it")
      assert has_element?(lv, "#cf-read-only-secret")
      assert has_element?(lv, "fieldset[disabled] #custom-field-summary")
      refute has_element?(lv, "fieldset[disabled] #custom-field-notes")
    end
  end

  describe "list options" do
    test "a hidden field is not offered as a column, filter or sort", ctx do
      names = fn actor ->
        ListScope.field_definitions(CMS.ContentTypes.all(), "page", actor, nil)
        |> Enum.map(& &1.name)
      end

      refute "secret" in names.(ctx.restricted)
      assert "notes" in names.(ctx.restricted)
      assert "secret" in names.(ctx.open)
    end

    test "a hidden field cannot be saved as a list column", ctx do
      assert {:error, _} =
               Accounts.set_content_list_columns(
                 ctx.restricted,
                 Accounts.default_org_id(),
                 "page",
                 ["secret"],
                 actor: ctx.restricted
               )

      assert {:ok, _} =
               Accounts.set_content_list_columns(
                 ctx.open,
                 Accounts.default_org_id(),
                 "page",
                 ["secret"],
                 actor: ctx.open
               )
    end
  end

  describe "export" do
    # A column saved before the restriction existed: written straight to the
    # row, as an older release or an earlier role would have left it.
    defp with_columns(attrs, names),
      do:
        seed(
          :editor,
          Map.put(attrs, :content_list_columns, %{
            Accounts.default_org_id() => %{"page" => names}
          })
        )

    defp export(user, format, params),
      do: get(log_in(build_conn(), user), "/editor/content/export.#{format}", params)

    test "a restricted editor's download never holds the canary, private=1 included", ctx do
      restricted = with_columns(%{field_read_grants: %{"page" => []}}, ["secret", "notes"])
      prefix = ctx.page.title

      for format <- [:csv, :json], private <- [nil, "1"] do
        params = %{"type" => "page", "q" => prefix}
        params = if private, do: Map.put(params, "private", private), else: params
        body = restricted |> export(format, params) |> response(200)

        refute body =~ @canary, "#{format} private=#{inspect(private)} leaked the value"
        refute body =~ "secret", "#{format} private=#{inspect(private)} named the column"
        assert body =~ "notes"
      end
    end

    test "an unrestricted editor's private=1 download holds it", ctx do
      open = with_columns(%{}, ["secret"])

      body =
        open
        |> export(:csv, %{"type" => "page", "q" => ctx.page.title, "private" => "1"})
        |> response(200)

      assert body =~ @canary
    end
  end

  test "the page fixture is a Page", ctx do
    assert %Page{} = ctx.page
  end
end
