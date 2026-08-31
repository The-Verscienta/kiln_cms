defmodule KilnCMSWeb.ContentEditorSuggestTest do
  @moduledoc """
  The "Suggest with AI" flow in the content editor (#60): async generation,
  per-field accept, and the guards that stop a generated string reaching a
  published `<meta>` tag by accident.

  Swaps global app env to select a stub generator, so `async: false`.
  **No test here makes a network call** — the shipped ReqLLM adapter is never
  selected.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.Presence

  @password "password123456"

  defp authed_user(role, grants \\ %{}) do
    email = "seo-suggest-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        grants
      )
    )

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

  defp open_editor(conn, user, page) do
    {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    {lv, html}
  end

  defp put_seo(overrides) do
    previous = Application.get_env(:kiln_cms, KilnCMS.Seo, [])
    Application.put_env(:kiln_cms, KilnCMS.Seo, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Seo, previous) end)
  end

  defp enable_stub(generator \\ KilnCMS.StubSeoGenerator),
    do: put_seo(generator: generator, model: "stub:stub")

  # Long enough to clear KilnCMS.Seo.min_words/0.
  defp prose_blocks do
    body =
      for i <- 1..8 do
        %{
          "_type" => "block",
          "style" => "normal",
          "children" => [
            %{
              "text" =>
                "Step #{i} is simple. Load the shelves with care. " <>
                  "Set the ramp rate low for the first hour. Watch the cones as the heat climbs."
            }
          ]
        }
      end

    [%{"_type" => "rich_text", "body" => body}]
  end

  defp page(attrs \\ %{}, actor) do
    CMS.create_page!(
      Map.merge(
        %{
          title: "Understanding kiln firing",
          slug: "suggest-#{System.unique_integer([:positive])}",
          blocks: prose_blocks()
        },
        attrs
      ),
      actor: actor
    )
  end

  defp change(lv, field, params) do
    render_change(lv, "validate", %{"form" => params, "_target" => ["form", field]})
  end

  # How many suggestion cards are currently offered.
  defp cards(html),
    do: html |> String.split(~s(phx-click="seo_accept")) |> length() |> Kernel.-(1)

  defp field_value(lv, field) do
    html = lv |> element(~s([name="form[#{field}]"])) |> render()

    case Regex.run(~r/\bvalue="([^"]*)"/, html, capture: :all_but_first) do
      [value] -> value
      # Textareas carry their value as content, not an attribute.
      nil -> html |> String.replace(~r/<[^>]*>/, "") |> String.trim()
    end
  end

  describe "authorization (#550)" do
    # An editor scoped to author only "post" can READ pages (empty readable
    # scope = unrestricted) but cannot autosave one — the "read-only on this
    # type" role the issue is about.
    defp read_only_editor,
      do: authed_user(:editor, %{editable_types: ["post"], readable_types: []})

    test "the Suggest control is hidden from an editor who cannot write the record", %{conn: conn} do
      enable_stub()
      page = page(authed_user(:admin))

      {_lv, html} = open_editor(conn, read_only_editor(), page)

      refute html =~ "Suggest with AI"
    end

    test "a forged seo_suggest event is refused server-side and starts no billed run",
         %{conn: conn} do
      # The counting stub proves the guard independently of rendering: the button
      # is hidden, but that alone wouldn't prove the *handler* refused — only that
      # the card didn't render. Asserting the generator was never called does.
      put_seo(generator: KilnCMS.StubSeoGenerator.Counting, model: "stub:stub")
      {:ok, _} = KilnCMS.StubSeoGenerator.Counting.start_link()
      KilnCMS.StubSeoGenerator.Counting.reset()

      page = page(authed_user(:admin))
      {lv, _html} = open_editor(conn, read_only_editor(), page)

      # The disabled/hidden button is not the control — push the event directly,
      # as a replay or a hand-rolled client would.
      render_click(lv, "seo_suggest", %{})
      render_async(lv, 2_000)

      assert KilnCMS.StubSeoGenerator.Counting.count() == 0
    end

    test "an editor who may write the record still gets the control", %{conn: conn} do
      enable_stub()
      editor = authed_user(:editor)

      {lv, html} = open_editor(conn, editor, page(editor))
      assert html =~ "Suggest with AI"

      render_click(lv, "seo_suggest", %{})
      assert render_async(lv, 2_000) =~ "Suggestions"
    end

    # #868. A per-field grant is enforced by `Changes.EnforceFieldGrants`, which
    # is a *change* — and `Ash.can?` builds its changeset with empty input, so
    # no attribute is ever `supplied?`, no violation is added, and the record
    # -level `may_write?` gate passes. This editor could therefore spend the
    # org's LLM budget on three fields the save would then refuse one by one.
    defp title_only_editor,
      do: authed_user(:editor, %{field_grants: %{"page" => ["title"]}})

    test "the Suggest control is hidden from an editor granted only other fields",
         %{conn: conn} do
      enable_stub()
      page = page(authed_user(:admin))

      {_lv, html} = open_editor(conn, title_only_editor(), page)

      refute html =~ "Suggest with AI"
    end

    test "a forged seo_suggest from a field-granted editor bills nothing", %{conn: conn} do
      put_seo(generator: KilnCMS.StubSeoGenerator.Counting, model: "stub:stub")
      {:ok, _} = KilnCMS.StubSeoGenerator.Counting.start_link()
      KilnCMS.StubSeoGenerator.Counting.reset()

      page = page(authed_user(:admin))
      {lv, _html} = open_editor(conn, title_only_editor(), page)

      render_click(lv, "seo_suggest", %{})
      render_async(lv, 2_000)

      assert KilnCMS.StubSeoGenerator.Counting.count() == 0
    end

    # The grant covers exactly what the suggestion writes, so nothing is
    # withheld — without this the fix could be "hide it from every granted
    # editor", which is a different bug.
    test "an editor granted the SEO fields still gets the control", %{conn: conn} do
      enable_stub()

      editor =
        authed_user(:editor, %{
          field_grants: %{"page" => ["seo_title", "seo_description", "seo_keywords"]}
        })

      {_lv, html} = open_editor(conn, editor, page(authed_user(:admin)))

      assert html =~ "Suggest with AI"
    end

    # Grants bind an effective editor; admins are exempt (the policy bypass),
    # and `EnforceFieldGrants` skips them. Hiding the control from an admin who
    # happens to carry a grants entry would be the mirror-image mistake.
    test "an admin carrying a field grant is unaffected", %{conn: conn} do
      enable_stub()
      admin = authed_user(:admin, %{field_grants: %{"page" => ["title"]}})

      {_lv, html} = open_editor(conn, admin, page(admin))

      assert html =~ "Suggest with AI"
    end

    # `any?`, not `all?`: each card is accepted on its own (`seo_accept` writes
    # exactly one attribute), so an editor granted one SEO field can take that
    # card and save cleanly. Hiding the panel from them would be the same bug
    # in the opposite direction.
    test "an editor granted one of the SEO fields still gets the control", %{conn: conn} do
      enable_stub()
      editor = authed_user(:editor, %{field_grants: %{"page" => ["seo_title"]}})

      {_lv, html} = open_editor(conn, editor, page(authed_user(:admin)))

      assert html =~ "Suggest with AI"
    end

    # …and the card they may NOT write is refused at accept time, not left to
    # be rejected by the save. The panel being hidden is not the boundary: a
    # queued or replayed `seo_accept` arrives regardless.
    test "accepting a card outside the grant does not touch the form", %{conn: conn} do
      enable_stub()
      editor = authed_user(:editor, %{field_grants: %{"page" => ["seo_title"]}})

      {lv, _html} = open_editor(conn, editor, page(authed_user(:admin)))

      render_click(lv, "seo_suggest", %{})
      render_async(lv, 2_000)

      before = field_value(lv, "seo_description")
      render_click(lv, "seo_accept", %{"field" => "seo_description"})

      assert field_value(lv, "seo_description") == before
    end

    # `may_write_fields?/4` calls `ContentTypes.type_name_for/1` with a RECORD,
    # where the change calls it with a changeset. For a dynamic type those are
    # different clauses, and resolving to "entry" instead of the type's own name
    # would read as no restriction and open the gate for every dynamic type.
    test "a dynamic type resolves its own name, not \"entry\"", %{conn: conn} do
      enable_stub()
      admin = authed_user(:admin)

      definition =
        KilnCMS.CMS.create_type_definition!(
          %{name: "recipe#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: admin
        )

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          definition.name,
          %{title: "Soup", slug: "soup-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      # Granted under the DYNAMIC type's name — if the gate resolved "entry"
      # this would read as "no grant for entry" and wrongly show the control.
      editor = authed_user(:editor, %{field_grants: %{definition.name => ["title"]}})

      {:ok, _lv, html} =
        conn |> log_in(editor) |> live(~p"/editor/content/#{definition.name}/#{entry.id}")

      refute html =~ "Suggest with AI"
    end

    # The content-intelligence section is the same shape as Suggest and was
    # missing the same guard (#916): "Analyze content" is an unbounded
    # `list_tags!` plus an embedding per unapplied tag on a cold 6h cache, and
    # unlike the SEO path it has no budget bucket in front of it.
    test "the Similar content section is hidden from a read-only editor", %{conn: conn} do
      page = page(authed_user(:admin))

      {_lv, html} = open_editor(conn, read_only_editor(), page)

      refute html =~ "Similar content"
    end

    test "a forged content_intel_refresh is refused server-side", %{conn: conn} do
      page = page(authed_user(:admin))
      {lv, _html} = open_editor(conn, read_only_editor(), page)

      # Asserted on the socket assigns, not the render: the section is hidden by
      # `:if={@may_write?}` either way, so a DOM assertion here passes with the
      # handler's guard deleted. `intel_duplicates` starts `nil` and only ever
      # becomes a list once the async load has run, so it says plainly whether
      # the handler did anything.
      render_click(lv, "content_intel_refresh", %{})
      render_async(lv, 2_000)

      assert intel(lv, :intel_duplicates) == nil
      assert intel(lv, :intel_tags) == nil
    end

    test "the same event from a writable editor DOES load", %{conn: conn} do
      # The positive control. Without it, `intel_duplicates` staying nil proves
      # nothing — it would stay nil if the event name were simply wrong.
      editor = authed_user(:editor)
      {lv, _html} = open_editor(conn, editor, page(editor))

      render_click(lv, "content_intel_refresh", %{})
      render_async(lv, 2_000)

      assert is_list(intel(lv, :intel_duplicates))
      assert is_list(intel(lv, :intel_tags))
    end

    test "a forged intel_add_tag ticks nothing", %{conn: conn} do
      admin = authed_user(:admin)

      tag =
        CMS.create_tag!(
          %{name: "gated tag", slug: "gated-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      {lv, _html} = open_editor(conn, read_only_editor(), page(admin))

      # `intel_tags` is empty for this editor by construction — the only thing
      # that fills it is the refresh gated above — so `add_suggested_tag/2`
      # would no-op even without the guard. So this asserts the guard's effect
      # (the form is untouched) rather than pretending to prove the guard; the
      # guard itself is defence in depth, for the day something else fills that
      # list.
      before_params = intel(lv, :form).params
      render_click(lv, "intel_add_tag", %{"id" => tag.id})

      assert intel(lv, :form).params == before_params
    end

    # Socket assigns, for the assertions that must not depend on markup a
    # `:if={@may_write?}` has already removed.
    defp intel(lv, key), do: :sys.get_state(lv.pid).socket.assigns[key]

    test "an editor who may write the record still gets Similar content", %{conn: conn} do
      editor = authed_user(:editor)

      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "Similar content"
    end
  end

  describe "gating" do
    test "the control is absent when no generator is configured", %{conn: conn} do
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      refute html =~ "Suggest with AI"
    end

    test "the control appears once a generator is configured", %{conn: conn} do
      enable_stub()
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "Suggest with AI"
    end
  end

  describe "the egress notice" do
    test "is absent for an on-prem provider", %{conn: conn} do
      put_seo(generator: KilnCMS.StubSeoGenerator, model: "ollama:llama3.1")
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "Suggest with AI"
      refute html =~ "sent to that provider"
    end

    test "names the provider for a hosted one", %{conn: conn} do
      put_seo(generator: KilnCMS.StubSeoGenerator, model: "anthropic:claude-sonnet-5")
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "sent to that provider"
      assert html =~ "anthropic"
    end
  end

  describe "generating" do
    setup do
      enable_stub()
      :ok
    end

    test "suggestions appear after the async run completes", %{conn: conn} do
      editor = authed_user(:editor)
      {lv, _html} = open_editor(conn, editor, page(editor))

      render_click(lv, "seo_suggest", %{})
      html = render_async(lv, 2_000)

      assert html =~ "SEO: Understanding kiln firing"
      assert html =~ "Suggestions"
    end

    test "a second click while one is in flight does not start a second run", %{conn: conn} do
      # The disabled attribute is client-side only, so a fast double-click or a
      # replayed event would otherwise generate — and bill — twice.
      put_seo(generator: KilnCMS.StubSeoGenerator.Counting, model: "stub:stub")
      {:ok, _} = KilnCMS.StubSeoGenerator.Counting.start_link()
      KilnCMS.StubSeoGenerator.Counting.reset()

      editor = authed_user(:editor)
      {lv, _html} = open_editor(conn, editor, page(editor))

      render_click(lv, "seo_suggest", %{})

      # The stub holds the run open until released (#1351), so the second
      # click provably lands while the guard is active — not inside a 150ms
      # sleep raced against two LiveView round-trips. Wait for run one to
      # announce itself in flight first, so the count below can tell a
      # deduplicated second click apart from a second run that just hasn't
      # started yet.
      assert_receive {:counting_draft_started, 1}, 2_000
      render_click(lv, "seo_suggest", %{})

      KilnCMS.StubSeoGenerator.Counting.release_all()
      render_async(lv, 5_000)

      assert KilnCMS.StubSeoGenerator.Counting.count() == 1
    end

    test "a page with too little content is refused before reaching the provider",
         %{conn: conn} do
      editor = authed_user(:editor)
      thin = page(%{blocks: [%{"_type" => "heading", "text" => "Hi", "level" => 2}]}, editor)
      {lv, _html} = open_editor(conn, editor, thin)

      render_click(lv, "seo_suggest", %{})
      html = render_async(lv, 2_000)

      assert html =~ "isn&#39;t enough content yet"
      refute html =~ "SEO: Understanding"
    end
  end

  describe "failure paths clear the spinner" do
    test "a generator error flashes and leaves the fields untouched", %{conn: conn} do
      enable_stub(KilnCMS.StubSeoGenerator.Failing)
      editor = authed_user(:editor)
      {lv, _html} = open_editor(conn, editor, page(editor))

      render_click(lv, "seo_suggest", %{})
      html = render_async(lv, 2_000)

      assert html =~ "Couldn&#39;t generate suggestions"
      assert field_value(lv, "seo_title") == ""

      # Not stuck: the control is enabled again, so the author can retry. (The
      # spinner class alone is a poor probe — the save indicator uses it too.)
      button = lv |> element("button[phx-click='seo_suggest']") |> render()
      refute button =~ "disabled"
    end

    test "a generator that raises degrades without taking the editor down", %{conn: conn} do
      enable_stub(KilnCMS.StubSeoGenerator.Raising)
      editor = authed_user(:editor)
      {lv, _html} = open_editor(conn, editor, page(editor))

      render_click(lv, "seo_suggest", %{})
      html = render_async(lv, 2_000)

      assert html =~ "Couldn&#39;t generate suggestions"
      assert render(lv) =~ "SEO &amp; scheduling"
    end
  end

  describe "accepting" do
    setup do
      enable_stub()
      :ok
    end

    defp suggest(conn, editor, record) do
      {lv, _html} = open_editor(conn, editor, record)
      render_click(lv, "seo_suggest", %{})
      render_async(lv, 2_000)
      lv
    end

    test "accepting one field writes only that field", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_accept", %{"field" => "seo_title"})

      assert field_value(lv, "seo_title") == "SEO: Understanding kiln firing"
      assert field_value(lv, "seo_description") == ""
    end

    test "an accepted card stops offering itself", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      # Count the cards rather than matching on a label: "SEO title" is also
      # the permanent label of the seo_title input itself.
      before_count = render(lv) |> cards()
      html = render_click(lv, "seo_accept", %{"field" => "seo_title"})

      assert cards(html) == before_count - 1
    end

    test "dismissing leaves the field alone", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_dismiss", %{"field" => "seo_title"})
      assert field_value(lv, "seo_title") == ""
    end

    test "accept-all applies every proposal", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_accept_all", %{})

      assert field_value(lv, "seo_title") == "SEO: Understanding kiln firing"
      assert field_value(lv, "seo_description") =~ "A summary of"
      assert field_value(lv, "seo_keywords") == "stub keyphrase, second"
    end

    test "an accepted value still saves", %{conn: conn} do
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      lv |> form("#page-editor") |> render_submit()

      assert Ash.get!(CMS.Page, record.id, actor: editor).seo_title ==
               "SEO: Understanding kiln firing"
    end
  end

  describe "suggestions are discarded when the content underneath them is" do
    setup do
      enable_stub()
      :ok
    end

    test "a conflict reload drops the cards it just invalidated", %{conn: conn} do
      # "Reload and discard your unsaved changes" must discard the AI proposal
      # too — it was generated from the content being thrown away, and the
      # reload clears :conflict, which is the guard accept/2 relies on.
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      assert cards(render(lv)) > 0

      render_click(lv, "reload_conflict", %{})

      assert cards(render(lv)) == 0
      render_click(lv, "seo_accept_all", %{})
      assert field_value(lv, "seo_title") == ""
    end

    test "re-running Suggest does not resurrect the previous run's cards", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      # Hand-edit what was just accepted.
      change(lv, "seo_title", %{"seo_title" => "My own headline"})

      # Swap in the held-open stub so the second run is genuinely in flight
      # while we look: with an instant stub the new proposal lands before we
      # can observe the window this regression lived in. It stays in flight
      # until the release below (#1351).
      put_seo(generator: KilnCMS.StubSeoGenerator.Counting, model: "stub:stub")
      {:ok, _} = KilnCMS.StubSeoGenerator.Counting.start_link()
      KilnCMS.StubSeoGenerator.Counting.reset()

      render_click(lv, "seo_suggest", %{})

      # Mid-generation there is nothing to apply — previously the *old* cards
      # were still rendered here, so this click clobbered the hand edit.
      assert cards(render(lv)) == 0
      render_click(lv, "seo_accept_all", %{})
      assert field_value(lv, "seo_title") == "My own headline"

      # The run only completes once released (#1351) — until here, "mid-
      # generation" was a property of the stub's 150ms sleep outlasting the
      # two assertions above.
      KilnCMS.StubSeoGenerator.Counting.release_all()
      render_async(lv, 5_000)
      assert field_value(lv, "seo_title") == "My own headline"
    end
  end

  describe "Use all" do
    setup do
      enable_stub()
      :ok
    end

    test "leaves accepted and hand-edited fields alone", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      change(lv, "seo_title", %{"seo_title" => "My own headline"})

      render_click(lv, "seo_accept_all", %{})

      assert field_value(lv, "seo_title") == "My own headline"
      assert field_value(lv, "seo_description") =~ "A summary of"
    end

    test "skips a dismissed field", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_dismiss", %{"field" => "seo_title"})
      render_click(lv, "seo_accept_all", %{})

      assert field_value(lv, "seo_title") == ""
      assert field_value(lv, "seo_description") =~ "A summary of"
    end

    test "reports a locked field instead of letting a later flash hide it", %{conn: conn} do
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      topic = Presence.topic("page", record.id)

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        topic,
        {:cursor, %{id: "other", name: "bob", field: "seo_title"}}
      )

      html = render_click(lv, "seo_accept_all", %{})

      # The skipped field is named, and the keywords/slug message doesn't
      # overwrite it.
      assert html =~ "Another editor is editing SEO title"
      assert field_value(lv, "seo_title") == ""
      assert field_value(lv, "seo_description") =~ "A summary of"
    end
  end

  describe "the slug decision" do
    setup do
      enable_stub()
      :ok
    end

    test "accepting keywords on a never-published draft re-derives the slug", %{conn: conn} do
      # Mirrors what typing the same keywords does — there is no live URL to
      # break yet, so diverging from the typed behaviour would be surprising.
      editor = authed_user(:editor)

      draft =
        page(
          %{title: "Untitled page", slug: "untitled-#{System.unique_integer([:positive])}"},
          editor
        )

      lv = suggest(conn, editor, draft)

      render_click(lv, "seo_accept", %{"field" => "seo_keywords"})

      assert field_value(lv, "slug") == "stub-keyphrase"
    end

    test "accepting keywords on published content leaves the slug alone and says so",
         %{conn: conn} do
      # Silently moving a live URL because a model proposed a keyphrase would
      # be indefensible.
      admin = authed_user(:admin)
      record = page(%{slug: "live-url-page"}, admin)
      published = CMS.publish_page!(record, actor: admin)

      lv = suggest(conn, admin, published)
      html = render_click(lv, "seo_accept", %{"field" => "seo_keywords"})

      assert field_value(lv, "slug") == "live-url-page"
      assert field_value(lv, "seo_keywords") == "stub keyphrase, second"
      assert html =~ "slug was left unchanged"
    end
  end

  describe "write-path guards" do
    setup do
      enable_stub()
      :ok
    end

    test "a peer holding the field blocks the accept server-side", %{conn: conn} do
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      topic = Presence.topic("page", record.id)
      cursor = %{id: "other-editor", name: "bob", field: "seo_title"}
      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, cursor})
      assert render(lv) =~ "ring-warning"

      # The lock is advisory — the input goes readonly but still submits — so
      # the disabled button is not the boundary. A replayed event lands here.
      html = render_click(lv, "seo_accept", %{"field" => "seo_title"})

      assert field_value(lv, "seo_title") == ""
      # The message names the field, so a multi-field "Use all" can report
      # exactly which ones were skipped rather than a generic notice.
      assert html =~ "Another editor is editing SEO title"

      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, %{cursor | field: nil}})
      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      assert field_value(lv, "seo_title") == "SEO: Understanding kiln firing"
    end

    test "an autosave landing mid-generation doesn't strand the suggestion", %{conn: conn} do
      # The suggestion lives in its own assign, and accept re-reads the form's
      # params at accept time rather than snapshotting them when generation
      # started — so a save that rebuilds the form (bumping lock_version) in
      # between must not lose the write.
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      lv |> form("#page-editor", form: %{title: "Retitled mid-flight"}) |> render_submit()

      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      assert field_value(lv, "seo_title") == "SEO: Understanding kiln firing"

      lv |> form("#page-editor") |> render_submit()
      saved = Ash.get!(CMS.Page, record.id, actor: editor)

      assert saved.seo_title == "SEO: Understanding kiln firing"
      assert saved.title == "Retitled mid-flight"
    end
  end
end
