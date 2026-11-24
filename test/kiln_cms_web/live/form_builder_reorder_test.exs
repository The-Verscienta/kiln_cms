defmodule KilnCMSWeb.FormBuilderReorderTest do
  @moduledoc """
  The builder's drag reorder when a write is refused (#2717): nothing moves,
  the flash names the field and says why, and the canvas is re-rendered in the
  saved order.

  LiveViewTest covers the flash, the database and the server render. That the
  browser's dragged cards snap back depends on the canvas' id changing, so
  morphdom replaces the node (and the Sortable hook remounts); here that shows
  only as the new id.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField

  @password "password123456"

  defp authed_user(role) do
    email = "fbr-#{System.unique_integer([:positive])}@example.com"

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

  # `a` (0), a legacy dropdown without options `topic` (1) — every update of
  # it is refused, a position-only one too — and `c` (2).
  defp builder_with_legacy_field(conn) do
    admin = authed_user(:admin)

    form =
      CMS.create_form!(%{name: "Contact", slug: "fbr-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    a =
      CMS.create_form_field!(
        %{form_id: form.id, name: "a", label: "A", field_type: :string, position: 0},
        actor: admin
      )

    topic =
      Ash.Seed.seed!(FormField, %{
        form_id: form.id,
        name: "topic",
        label: "Topic",
        field_type: :select,
        options: [],
        position: 1
      })

    c =
      CMS.create_form_field!(
        %{form_id: form.id, name: "c", label: "C", field_type: :string, position: 2},
        actor: admin
      )

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")
    {form, [a, topic, c], lv}
  end

  defp names(form), do: form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name)

  defp canvas_order(lv) do
    lv
    |> element("[id^=builder-canvas-]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-sort-id]")
    |> LazyHTML.attribute("data-sort-id")
  end

  test "a refused write moves nothing and names the field", %{conn: conn} do
    {form, [a, topic, c], lv} = builder_with_legacy_field(conn)
    assert has_element?(lv, "#builder-canvas-0")

    # `c` and `a` are written before `topic` is refused.
    html = render_hook(lv, "reorder", %{"order" => [c.id, a.id, topic.id]})

    assert html =~
             "Couldn&#39;t save the new order, so nothing was moved. Fix the field “topic” and try again: " <>
               "Invalid value provided for options: a select field must list at least one option."

    # Through `Exception.message/1`: no raw `%{…}` template.
    refute html =~ "%{"

    assert names(form) == ["a", "topic", "c"]

    # A new canvas node, rendered in the saved order.
    refute has_element?(lv, "#builder-canvas-0")
    assert has_element?(lv, "#builder-canvas-1")
    assert canvas_order(lv) == [a.id, topic.id, c.id]
  end

  test "a reorder that saves flashes nothing and keeps the canvas", %{conn: conn} do
    {form, [a, topic, c], lv} = builder_with_legacy_field(conn)

    # `topic` stays at index 1, so it is never written.
    html = render_hook(lv, "reorder", %{"order" => [c.id, topic.id, a.id]})

    refute html =~ "Couldn&#39;t save the new order"
    assert names(form) == ["c", "topic", "a"]
    assert has_element?(lv, "#builder-canvas-0")
    assert canvas_order(lv) == [c.id, topic.id, a.id]
  end
end
