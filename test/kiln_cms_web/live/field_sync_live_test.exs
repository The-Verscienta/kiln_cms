defmodule KilnCMSWeb.FieldSyncLiveTest do
  @moduledoc """
  The field-definition sync screen (#2438, `/editor/fields/sync`): admin only,
  upload limits, a preview that writes nothing, separate prune / data-loss
  confirmations, an apply that refuses a plan that moved, and its audit event.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldSync

  @password "password1234!"

  defp rating_doc(extra \\ []) do
    fields =
      [%{"name" => "rating", "label" => "Rating", "field_type" => "integer"}] ++ extra

    %{
      "format" => "kiln-field-definitions",
      "version" => 1,
      "owners" => [%{"kind" => "compiled", "type" => "post", "fields" => fields}]
    }
  end

  defp upload(lv, doc, name \\ "fields.json") do
    content = if is_binary(doc), do: doc, else: Jason.encode!(doc)

    file_input(lv, "#sync-upload-form", :definitions, [
      %{name: name, content: content, type: "application/json"}
    ])
  end

  defp preview(lv, doc, name \\ "fields.json") do
    lv |> upload(doc, name) |> render_upload(name)
    lv |> form("#sync-upload-form") |> render_submit()
  end

  defp names(admin),
    do: admin |> then(&CMS.field_definitions_for!(:post, actor: &1)) |> Enum.map(& &1.name)

  setup %{conn: conn} do
    admin = authed_user(:admin)
    org = Accounts.get_organization!(Accounts.default_org_id(), authorize?: false)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields/sync")
    %{admin: admin, lv: lv, org: org}
  end

  test "an anonymous visitor is sent to sign-in and an editor is turned away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/fields/sync")

    assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
             conn |> log_in(authed_user(:editor)) |> live(~p"/editor/fields/sync")
  end

  test "the fields screen links to it", %{conn: conn, admin: admin} do
    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/fields")
    assert html =~ "fields-sync-link"
  end

  describe "upload limits" do
    test "a file that is not .json is refused", %{lv: lv} do
      assert {:error, [[_ref, :not_accepted]]} =
               lv |> upload(rating_doc(), "fields.txt") |> render_upload("fields.txt")
    end

    test "a file over 2 MB is refused", %{lv: lv} do
      big = String.duplicate(" ", 2_100_000)
      assert {:error, [[_ref, :too_large]]} = lv |> upload(big) |> render_upload("fields.json")
    end

    test "content that is not a JSON object is refused by content, not name", %{lv: lv} do
      html = preview(lv, "[1, 2]")
      assert html =~ "not a JSON object"
      refute has_element?(lv, "#sync-preview")
    end

    test "a JSON object that is not a field-definitions file is reported by the import", %{lv: lv} do
      html = preview(lv, %{"hello" => "world"})
      assert html =~ "not a kiln-field-definitions document"
      assert has_element?(lv, "#sync-errors")
      refute has_element?(lv, "#sync-ask-apply:not([disabled])")
    end
  end

  describe "preview and apply" do
    test "the preview writes nothing and apply needs the confirm step", %{lv: lv, admin: admin} do
      html = preview(lv, rating_doc())

      assert html =~ "post.rating"
      assert html =~ "1 to create"
      refute "rating" in names(admin)

      # The confirm button does not exist until "Apply…" is pressed.
      refute has_element?(lv, "#sync-apply")
      lv |> element("#sync-ask-apply") |> render_click()
      assert has_element?(lv, "#sync-confirm")
      refute "rating" in names(admin)

      html = lv |> element("#sync-apply") |> render_click()
      assert html =~ "Field definitions applied."
      assert "rating" in names(admin)
    end

    test "a successful apply is audited with its counts", %{lv: lv, admin: admin, org: org} do
      preview(lv, rating_doc())
      lv |> element("#sync-ask-apply") |> render_click()
      lv |> element("#sync-apply") |> render_click()

      assert [event] =
               KilnCMS.Security.list_events!(actor: admin, tenant: org.id, page: [limit: 50])
               |> Map.get(:results)
               |> Enum.filter(&(&1.type == :org_setting_changed))

      assert event.metadata["setting"] == "field_definitions"
      assert event.metadata["created"] == 1
      assert event.metadata["prune"] == false
      assert event.actor_id == admin.id
    end

    test "an apply refuses a plan that moved since the preview", %{lv: lv, admin: admin} do
      preview(lv, rating_doc())
      lv |> element("#sync-ask-apply") |> render_click()

      # Another admin creates the same field after the preview was shown.
      CMS.create_field_definition!(
        %{content_type: :post, name: "rating", label: "Rating", field_type: :integer},
        actor: admin
      )

      html = lv |> element("#sync-apply") |> render_click()
      assert html =~ "changed since this preview"
      refute has_element?(lv, "#sync-confirm")
      refute html =~ "Field definitions applied."
      assert Enum.count(names(admin), &(&1 == "rating")) == 1
    end
  end

  describe "separate confirmations" do
    setup %{admin: admin} do
      CMS.create_field_definition!(
        %{content_type: :post, name: "old", label: "Old", field_type: :string},
        actor: admin
      )

      CMS.create_post!(
        %{
          title: "T",
          slug: "fs-#{System.unique_integer([:positive])}",
          custom_fields: %{"old" => "x"}
        },
        actor: admin
      )

      :ok
    end

    test "a field the file does not list stays unless prune is confirmed", %{lv: lv, admin: admin} do
      html = preview(lv, rating_doc())
      assert html =~ "Not in the file (kept)"
      refute html =~ "Delete</span>"

      lv |> form("#sync-flags", %{"prune" => "true"}) |> render_change()
      # Holding data, so deleting it is refused until data loss is allowed too.
      assert has_element?(lv, "#sync-blocked", "post.old")
      assert has_element?(lv, "#sync-ask-apply[disabled]")
      assert "old" in names(admin)

      lv
      |> form("#sync-flags", %{"prune" => "true", "allow_data_loss" => "true"})
      |> render_change()

      refute has_element?(lv, "#sync-ask-apply[disabled]")

      lv |> element("#sync-ask-apply") |> render_click()
      assert render(lv) =~ "You confirmed deleting fields"
      assert render(lv) =~ "You confirmed changes that drop stored values"
      lv |> element("#sync-apply") |> render_click()

      refute "old" in names(admin)
      assert "rating" in names(admin)
    end

    test "allowing data loss alone deletes nothing and changing a flag cancels the confirm", %{
      lv: lv,
      admin: admin
    } do
      preview(lv, rating_doc())
      lv |> element("#sync-ask-apply") |> render_click()
      assert has_element?(lv, "#sync-confirm")

      lv |> form("#sync-flags", %{"allow_data_loss" => "true"}) |> render_change()
      refute has_element?(lv, "#sync-confirm")

      lv |> element("#sync-ask-apply") |> render_click()
      lv |> element("#sync-apply") |> render_click()
      assert "old" in names(admin)
    end

    test "a new file starts with both confirmations off", %{lv: lv} do
      preview(lv, rating_doc())

      lv
      |> form("#sync-flags", %{"prune" => "true", "allow_data_loss" => "true"})
      |> render_change()

      preview(lv, rating_doc())

      refute has_element?(lv, "#sync-flags input[name=prune][checked]")
      refute has_element?(lv, "#sync-flags input[name=allow_data_loss][checked]")
    end
  end

  test "FieldSync.digest ignores whether the report is a dry run", %{admin: admin} do
    {:ok, dry} = FieldSync.import_doc(rating_doc(), actor: admin)
    {:ok, applied} = FieldSync.import_doc(rating_doc(), actor: admin, apply?: true)
    assert FieldSync.digest(dry) == FieldSync.digest(applied)
  end

  defp authed_user(role) do
    email = "fsl-#{role}-#{System.unique_integer([:positive])}@example.com"

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
end
