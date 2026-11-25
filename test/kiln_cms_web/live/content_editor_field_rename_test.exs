defmodule KilnCMSWeb.ContentEditorFieldRenameTest do
  @moduledoc """
  An editor with a live record open while an admin renames one of its custom
  fields (#2744). The rename rewrites the record's working copy and bumps its
  `lock_version`, so the editor's next autosave is refused as stale and the
  conflict banner asks for a reload — rather than writing the pre-rename
  custom fields back over the rewritten copy.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "rename-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

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

  defp slug, do: "rename-live-#{System.unique_integer([:positive])}"

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  test "an open editor gets the conflict banner, not a silent overwrite", %{conn: conn} do
    admin = authed_user(:admin)
    editor = authed_user(:editor)
    name = "subtitle_#{System.unique_integer([:positive])}"

    field =
      CMS.create_field_definition!(
        %{content_type: :page, name: name, label: "Subtitle", field_type: :string},
        actor: admin
      )

    page =
      CMS.create_page!(
        %{title: "Live title", slug: slug(), custom_fields: %{name => "Live sub"}},
        actor: admin
      )

    CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    {:ok, _saved} =
      CMS.save_page_working_copy(
        reload(page),
        %{fields: %{"custom_fields" => %{name => "Held sub"}}},
        actor: admin,
        tenant: page.org_id
      )

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

    CMS.update_field_definition!(field, %{name: "tagline"}, actor: admin)

    lv
    |> form("#page-editor")
    |> render_change(%{"form" => %{"title" => "Edited"}, "_target" => ["form", "title"]})

    send(lv.pid, :autosave)
    html = render(lv)

    assert html =~ "This content changed elsewhere"

    after_autosave = reload(page)
    assert after_autosave.working_fields["custom_fields"] == %{"tagline" => "Held sub"}
    refute after_autosave.working_title == "Edited"
  end
end
