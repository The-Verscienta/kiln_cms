defmodule KilnCMSWeb.ContentEditorIntelligenceTest do
  @moduledoc """
  The "Similar content" panel in the content editor (#339 phase 2):
  near-duplicate warnings and one-click tag suggestions, both computed from the
  block embeddings the document already has.

  Toggles the global `KilnCMS.Search` env to select the stub embedder, so
  `async: false`. **No model is loaded and nothing leaves the process.**
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Search.BlockIndexer

  @password "password123456"

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(original, KilnCMS.StubEmbedder.search_env())
    )

    :ok
  end

  defp authed_user(role) do
    email = "intel-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "intel-#{System.unique_integer([:positive])}"

  defp indexed_page(actor, text, opts) do
    page =
      CMS.create_page!(
        %{
          title: Keyword.get(opts, :title, "Doc"),
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]
        },
        actor: actor
      )

    page = CMS.publish_page!(page, %{}, actor: actor)
    {:ok, _} = BlockIndexer.reindex(page)
    page
  end

  defp open(conn, user, page) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    lv
  end

  defp analyze(lv) do
    lv |> element("button[phx-click='content_intel_refresh']") |> render_click()
    # `start_async` — the result arrives on a later message, so let the async
    # assign settle before reading the panel (never a bare render_async/1).
    render_async(lv, 2_000)
  end

  test "the panel loads nothing until it is clicked", %{conn: conn} do
    actor = authed_user(:admin)
    anchor = indexed_page(actor, "brewing herbal tea slowly", title: "Same")
    twin = indexed_page(actor, "brewing herbal tea slowly", title: "Same")

    {:ok, _lv, html} = conn |> log_in(actor) |> live(~p"/editor/content/page/#{anchor.id}")

    # The section and its button render; the (expensive) results do not.
    # (`twin.id` alone is no signal — the relationship pickers list every
    # sibling page — so the assertion is on the panel's own link.)
    assert html =~ "Similar content"
    assert html =~ "Analyze content"
    refute html =~ "/editor/content/page/#{twin.id}"
  end

  test "clicking Analyze surfaces a near-duplicate with a link to it", %{conn: conn} do
    actor = authed_user(:admin)

    # Identical *documents*, not just identical bodies: block embeddings are
    # hierarchical, so a differing title moves the vectors well past the
    # near-duplicate threshold even when the prose is word-for-word the same.
    anchor = indexed_page(actor, "brewing herbal tea slowly", title: "Same")
    twin = indexed_page(actor, "brewing herbal tea slowly", title: "Same")
    other = indexed_page(actor, "carburetor maintenance schedules", title: "Unrelated")

    html = conn |> open(actor, anchor) |> analyze()

    assert html =~ "possible duplicate"
    assert html =~ "/editor/content/page/#{twin.id}"
    refute html =~ "/editor/content/page/#{other.id}"
  end

  test "tag suggestions apply to the form on one click and leave the list", %{conn: conn} do
    actor = authed_user(:admin)
    tag = CMS.create_tag!(%{name: "herbal tea", slug: slug()}, actor: actor)
    page = indexed_page(actor, "brewing herbal tea slowly", title: "Anchor")

    lv = open(conn, actor, page)
    html = analyze(lv)

    assert html =~ "Suggested tags"
    assert html =~ "herbal tea"

    applied =
      lv
      |> element("button[phx-click='intel_add_tag'][phx-value-id='#{tag.id}']")
      |> render_click()

    # Ticked in the picker the editor already has, rather than written straight
    # to the record — so it saves with everything else and unticking undoes it.
    assert applied =~ ~s(value="#{tag.id}" checked)

    # And gone from the suggestion list: re-offering an applied tag is a button
    # that visibly does nothing.
    refute applied =~ ~s(phx-value-id="#{tag.id}")
  end

  test "an id we never suggested is ignored rather than attached", %{conn: conn} do
    actor = authed_user(:admin)
    other = CMS.create_tag!(%{name: "unrelated tag", slug: slug()}, actor: actor)
    page = indexed_page(actor, "brewing herbal tea slowly", title: "Anchor")

    # Deliberately no `analyze/1`: nothing has been suggested, so this is a
    # forged or replayed event, and the panel's controls aren't even rendered.
    # An `intel_add_tag` handler that trusted the pushed id would attach an
    # arbitrary tag on a click the author never made.
    html = render_click(open(conn, actor, page), "intel_add_tag", %{"id" => other.id})

    refute html =~ ~s(value="#{other.id}" checked)
  end

  test "with semantic search off the panel explains itself instead of sitting empty", %{
    conn: conn
  } do
    actor = authed_user(:admin)
    page = indexed_page(actor, "brewing herbal tea slowly", title: "Anchor")

    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(original, :semantic, false))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    html = conn |> open(actor, page) |> analyze()

    assert html =~ "Semantic search is off"
  end

  test "a never-published draft finds its duplicate (#852)", %{conn: conn} do
    # This test used to assert the opposite — "Publish this page to index it" —
    # because embeddings were only written by firing, and firing runs on
    # publish. That inverted the feature: near-duplicate detection is a
    # PRE-publication check, and it only became available once the second copy
    # had already been published.
    actor = authed_user(:admin)

    twin = indexed_page(actor, "brewing herbal tea slowly", title: "Same")

    draft =
      CMS.create_page!(
        %{
          title: "Same",
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>brewing herbal tea slowly</p>", order: 0}]
        },
        actor: actor
      )

    html = conn |> open(actor, draft) |> analyze()

    # The twin's editor LINK, not its title: both documents are titled "Same"
    # (they have to be — the hierarchical embedding folds the title in), so
    # asserting on the title would be satisfied by the editor's own title input
    # and would pass with the fix removed.
    assert html =~ "/editor/content/page/#{twin.id}"
  end

  test "a draft with nothing written in it says so", %{conn: conn} do
    # The remaining honest empty state, and a different instruction: there is
    # no block text to embed, so there is nothing to compare *from* — fixed by
    # writing something, not by publishing or by changing a setting.
    actor = authed_user(:admin)
    _twin = indexed_page(actor, "brewing herbal tea slowly", title: "Same")

    blank = CMS.create_page!(%{title: "Blank", slug: slug(), blocks: []}, actor: actor)

    html = conn |> open(actor, blank) |> analyze()

    assert html =~ "Add some content"
  end

  # #1076: computing a never-published draft's centroid (the same #852 path
  # above) now draws on `KilnCMS.LLM.Budget`'s `"search_embedding"` bucket. A
  # blocked call must not read as "no duplicates" — see `intel_outcome/1` and
  # its comment in `KilnCMSWeb.ContentEditorLive`.
  test "a spent embedding budget flashes instead of reading as a clean bill of health", %{
    conn: conn
  } do
    actor = authed_user(:admin)
    # A body distinct from every other test's ("brewing herbal tea slowly" is
    # reused all over this file, including by an unpublished draft in "a
    # never-published draft finds its duplicate (#852)" above) — since #1076's
    # fix, a cache hit correctly bypasses the budget entirely, so reusing that
    # text would let this test pass whether or not the budget check ran at all.
    uniq = System.unique_integer([:positive])
    text = "budget ceiling passage #{uniq}"
    _twin = indexed_page(actor, text, title: "Same #{uniq}")

    draft =
      CMS.create_page!(
        %{
          title: "Same #{uniq}",
          slug: slug(),
          blocks: [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]
        },
        actor: actor
      )

    # `{0, _}` refuses unconditionally regardless of what any other test in
    # this run already spent against the shared default org — the same "zero
    # ceiling" shape `KilnCMS.Search.RelatedTest` uses to prove the negative.
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.put(original, :embedding_per_org_limit, {0, :timer.hours(1)})
    )

    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    html = conn |> open(actor, draft) |> analyze()

    assert html =~ "rate limit"
    # The ordinary empty state must NOT also render — that copy is a *result*
    # ("nothing similar found"), and this is the absence of one.
    refute html =~ "possible duplicate"
  end
end
