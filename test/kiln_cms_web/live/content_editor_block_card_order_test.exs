defmodule KilnCMSWeb.ContentEditorBlockCardOrderTest do
  @moduledoc """
  The block canvas (`#blocks-sortable`) holds block cards and nothing else,
  and each card keeps its position across the form rebuild that follows a
  draft's autosave.

  Two clients read the canvas's direct children: the `Sortable` hook, which
  treats them as the blocks it reorders, and morphdom, which walks them
  positionally on every patch. A block sub-form's hidden inputs
  (`_persistent_id`, `_union_type`, `_touched`, …) used to render as the
  card's siblings, and the set differs between a block just added in memory
  and the same block on the form rebuilt from the saved record. When new
  unkeyed inputs appeared ahead of the keyed card, morphdom detached and
  re-appended the card to put it back — and a detached focused element loses
  focus, so the author's next keystrokes after the first autosave went to
  `<body>`. The hidden inputs now render inside the card, at its end, where
  their count can change without moving anything.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp authed_editor do
    email = "cardorder-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp draft_page do
    Ash.Seed.seed!(Page, %{
      title: "Card order",
      slug: "card-order-#{System.unique_integer([:positive])}",
      state: :draft
    })
  end

  # `{tag, id}` of every direct child of the canvas — what Sortable and
  # morphdom see.
  defp canvas_children(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#blocks-sortable > *")
    |> Enum.map(fn {tag, _, _} = el -> {tag, el |> Floki.attribute("id") |> List.first()} end)
  end

  defp hidden_names_in(html, card_id) do
    html
    |> Floki.parse_document!()
    |> Floki.find("##{card_id} input[type=hidden]")
    |> Floki.attribute("name")
  end

  # The canvas must not gain anything ahead of a card between the render that
  # added the block and the one that follows its first autosave — the two
  # renders whose hidden-input sets differ (a create sub-form vs. an update
  # sub-form with data, which adds the record's `id`).
  test "a block card keeps its position across the first autosave", %{conn: conn} do
    page = draft_page()

    {:ok, lv, _html} =
      conn |> log_in(authed_editor()) |> live(~p"/editor/pages/#{page.id}")

    render_hook(lv, "add_block", %{"type" => "rich_text"})
    added = render(lv)

    assert canvas_children(added) == [{"div", "block-0"}]

    # The sub-form's bookkeeping still travels with the block — inside the card.
    names = hidden_names_in(added, "block-0")
    assert "form[blocks][0][_persistent_id]" in names
    assert "form[blocks][0][_form_type]" in names
    assert "form[blocks][0][_union_type]" in names
    assert "form[blocks][0][id]" in names

    send(lv.pid, :autosave)
    saved = render(lv)

    assert canvas_children(saved) == [{"div", "block-0"}]
    saved_names = hidden_names_in(saved, "block-0")
    assert "form[blocks][0][_form_type]" in saved_names
    assert "form[blocks][0][_union_type]" in saved_names
    # The stable id is written exactly once per card, whichever sub-form kind
    # rendered it.
    assert Enum.count(saved_names, &(&1 == "form[blocks][0][id]")) == 1

    # And the relocated inputs still carry the block through a submit as the
    # type it was added as.
    lv |> form("#page-editor") |> render_submit()

    assert [%Ash.Union{type: :rich_text}] = CMS.get_page!(page.id, authorize?: false).blocks
  end
end
