defmodule KilnCMSWeb.DuplicateContentTest do
  @moduledoc """
  The Duplicate action's two editor surfaces (#471): the content list's row
  button and the content editor's header button. Both clone the record into a
  new draft and land the editor in it; the clone mechanics themselves are
  covered by `KilnCMS.CMS.DuplicationTest`.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  require Ash.Query

  @password "password123456"

  defp authed_user(role) do
    email = "dupui-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
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

  defp slug, do: "dupui-#{System.unique_integer([:positive])}"

  defp copy_of(source) do
    KilnCMS.CMS.Page
    |> Ash.Query.filter(title == ^(source.title <> " (copy)"))
    |> Ash.read_one!(authorize?: false)
  end

  test "the content list's Duplicate button clones the row and opens the copy", %{conn: conn} do
    editor = authed_user(:editor)

    source =
      CMS.create_page!(
        %{
          title: "Launch checklist",
          slug: slug(),
          seo_title: "Checklist",
          blocks: [%{"_type" => "heading", "text" => "Step one"}]
        },
        actor: editor
      )

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

    assert {:error, {:live_redirect, %{to: to}}} =
             lv
             |> element("button[phx-click='duplicate'][phx-value-id='#{source.id}']")
             |> render_click()

    copy = copy_of(source)

    assert to == "/editor/content/page/#{copy.id}"
    assert copy.state == :draft
    assert copy.seo_title == "Checklist"
    assert copy.slug != source.slug
    assert [%Ash.Union{value: %{text: "Step one"}}] = copy.blocks
  end

  test "the content editor's Duplicate button clones the record and opens the copy", %{conn: conn} do
    editor = authed_user(:editor)
    source = CMS.create_page!(%{title: "Recipe", slug: slug()}, actor: editor)

    {:ok, lv, _html} =
      conn |> log_in(editor) |> live(~p"/editor/content/page/#{source.id}")

    assert {:error, {:live_redirect, %{to: to}}} =
             lv |> element("button[phx-click='duplicate']") |> render_click()

    copy = copy_of(source)

    assert to == "/editor/content/page/#{copy.id}"
    assert copy.id != source.id
    assert copy.state == :draft
  end

  # This used to assert the opposite — that clicking Duplicate on a type the
  # editor may not author produces an error flash. That was institutionalizing
  # the bug (#926): the button had no business being there, and its only
  # possible outcome was that flash. The row is now gated on the same question
  # the create policy asks, so the button is absent.
  test "a type the editor may not author offers no row actions", %{conn: conn} do
    admin = authed_user(:admin)
    source = CMS.create_page!(%{title: "Off limits", slug: slug()}, actor: admin)

    scoped = authed_user(:editor)

    {:ok, scoped} =
      KilnCMS.Accounts.manage_user_access(scoped, %{editable_types: ["post"]}, actor: admin)

    {:ok, lv, html} = conn |> log_in(scoped) |> live(~p"/editor")

    refute has_element?(lv, "button[phx-click='duplicate'][phx-value-id='#{source.id}']")
    # Nor the "New page" button for a type they cannot author.
    refute html =~ "New page"
  end

  # The server side still refuses, whatever the client sends — the gating is a
  # usability fix, not the authorization.
  test "a duplicate posted for an unauthored type is still refused", %{conn: conn} do
    admin = authed_user(:admin)
    source = CMS.create_page!(%{title: "Off limits", slug: slug()}, actor: admin)

    scoped = authed_user(:editor)

    {:ok, scoped} =
      KilnCMS.Accounts.manage_user_access(scoped, %{editable_types: ["post"]}, actor: admin)

    {:ok, lv, _html} = conn |> log_in(scoped) |> live(~p"/editor")

    assert render_click(lv, "duplicate", %{"kind" => "page", "id" => source.id}) =~
             "Couldn&#39;t duplicate that content."
  end

  # #922. `/editor/content/:kind/:id` deliberately admits an actor who may OPEN
  # a record without being able to write it (#550), and the header's Duplicate
  # button was the one write affordance there with no `:if` — offered to a
  # reader, with an error flash as its only possible outcome. Its siblings in
  # the same file (the SEO panel, the intelligence panels) are all hidden.
  describe "the editor header's Duplicate button, for a reader" do
    setup %{conn: conn} do
      admin = authed_user(:admin)
      source = CMS.create_page!(%{title: "Someone else's draft", slug: slug()}, actor: admin)

      reader = authed_user(:editor)

      {:ok, reader} =
        KilnCMS.Accounts.manage_user_access(reader, %{editable_types: ["post"]}, actor: admin)

      # The premise the rest of this block rests on: they can open it, and what
      # they get is the real editor for THIS record. `{:ok, lv, _html}` already
      # fails on a redirect; the title assertion is what would catch a stub page
      # rendered for readers, which would make every refute below vacuous.
      {:ok, lv, html} =
        conn |> log_in(reader) |> live(~p"/editor/content/page/#{source.id}")

      assert html =~ "Someone else&#39;s draft"

      %{lv: lv, source: source}
    end

    test "is not offered", %{lv: lv} do
      refute has_element?(lv, "button[phx-click='duplicate']")
    end

    # The translations panel renders for this reader — `en` is linked and
    # `fr`/`es` have no record yet — so its "Create translation" buttons are in
    # the reader's DOM unless the same gate removes them. Without this the
    # panel half of the fix was unpinned: reverting `and @may_write?` on that
    # button left 251 tests green across seven files.
    test "nor is Create translation", %{lv: lv} do
      refute has_element?(lv, "button[phx-click='create_translation']")
    end

    # The hidden button is not the boundary — a replayed or forged event arrives
    # regardless, which is why `seo_suggest` refuses server-side as well.
    #
    # Asserting on the *flash*, not on the absence of a copy: the type's
    # `:create` policy already refuses this actor (`Checks.EditableContentType`
    # gates authoring and updating alike), so no copy is written either way and
    # that assertion could not fail. What the gate changes is that the refusal
    # happens before any work, rather than as an error the reader is shown for
    # an action they were never offered.
    test "a forged duplicate event is refused", %{lv: lv} do
      render_click(lv, "duplicate", %{})

      refute has_element?(lv, "#flash-error")
    end

    # Same shape, same file: `create_translation` forks the record's payload
    # into a new draft too, and was the other affordance offered to a reader.
    test "a forged create_translation event is refused", %{lv: lv} do
      render_click(lv, "create_translation", %{"locale" => "fr"})

      refute has_element?(lv, "#flash-error")
    end
  end

  # `kind` and `id` ride on the clicked row, so they are client input. A crafted
  # pair must flash, not take the LiveView down with it.
  test "a crafted kind or id flashes instead of crashing the list", %{conn: conn} do
    editor = authed_user(:editor)
    _source = CMS.create_page!(%{title: "Anything", slug: slug()}, actor: editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

    for params <- [
          %{"kind" => "not_a_type", "id" => Ash.UUID.generate()},
          %{"kind" => "page", "id" => Ash.UUID.generate()},
          %{"kind" => "page", "id" => "not-a-uuid"}
        ] do
      assert render_click(lv, "duplicate", params) =~ "Couldn&#39;t duplicate that content."
    end
  end
end
