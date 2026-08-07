defmodule KilnCMSWeb.ContentEditorAssistTest do
  @moduledoc """
  Block-level AI assist in the content editor (#60): the per-block panel, async
  generation, and the guards that stop generated prose reaching a block by any
  route other than a human clicking.

  The single most important assertion in here is that accepting a suggestion
  never writes the block server-side — it leaves as a `push_event` for TipTap
  to apply. A server write would force the document back into an editor mounted
  under `phx-update="ignore"`, discarding the author's cursor and undo stack
  and desynchronizing collaborators.

  Swaps global app env to select a stub generator, so `async: false`.
  **No test here makes a network call** — the shipped ReqLLM adapter is never
  selected.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, grants \\ %{}) do
    email = "assist-#{System.unique_integer([:positive])}@example.com"

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

  defp put_assist(overrides) do
    previous = Application.get_env(:kiln_cms, KilnCMS.Assist, [])
    Application.put_env(:kiln_cms, KilnCMS.Assist, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Assist, previous) end)
  end

  defp enable_stub(generator \\ KilnCMS.StubAssistGenerator),
    do: put_assist(generator: generator, model: "stub:stub")

  # Two rich-text blocks, deliberately. With one, every "different block" test
  # resolves to the same id and the cross-block guards are never exercised.
  defp prose_blocks do
    [
      %{"_type" => "rich_text", "body" => paragraphs("Step")},
      %{"_type" => "rich_text", "body" => paragraphs("Note")}
    ]
  end

  defp paragraphs(prefix) do
    for i <- 1..4 do
      %{
        "_type" => "block",
        "style" => "normal",
        "children" => [
          %{
            "text" =>
              "#{prefix} #{i} is simple. Load the shelves with care. " <>
                "Set the ramp rate low for the first hour."
          }
        ]
      }
    end
  end

  defp page(actor, attrs \\ %{}) do
    CMS.create_page!(
      Map.merge(
        %{
          title: "Understanding kiln firing",
          slug: "assist-#{System.unique_integer([:positive])}",
          blocks: prose_blocks()
        },
        attrs
      ),
      actor: actor
    )
  end

  # The stable id the panel and the push_event are both keyed on.
  defp block_id(page, index \\ 0),
    do: page.blocks |> Enum.at(index) |> Map.fetch!(:value) |> Map.fetch!(:id)

  defp open_panel(lv, page, index \\ 0) do
    render_click(lv, "assist_open", %{"bid" => block_id(page, index)})
  end

  describe "gating" do
    test "the control is absent when no generator is configured", %{conn: conn} do
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      refute html =~ "AI assist"
    end

    test "the control appears once a generator is configured", %{conn: conn} do
      enable_stub()
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "AI assist"
    end

    test "SEO drafting alone does not render the block control", %{conn: conn} do
      previous = Application.get_env(:kiln_cms, KilnCMS.Seo, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Seo,
        Keyword.merge(previous, generator: KilnCMS.StubSeoGenerator, model: "stub:stub")
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Seo, previous) end)

      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "Suggest with AI"
      refute html =~ "AI assist"
    end

    test "a pushed run event is refused when the feature is off", %{conn: conn} do
      # "Not rendered" is a client-side fact. These are plain pushed events, so
      # a stale tab or a crafted push must not reach a provider.
      editor = authed_user(:editor)
      target = page(editor)
      {lv, _html} = open_editor(conn, editor, target)

      html = render_click(lv, "assist_run", %{"bid" => block_id(target)})

      refute html =~ "Suggestion"
      assert render_async(lv, 2_000) =~ "Understanding kiln firing"
    end

    test "a read-only editor cannot spend LLM budget via a forged assist_run (#550)", %{
      conn: conn
    } do
      # Same write-authorization boundary as SEO suggest: block assist also bills
      # an org run, so read access must not be enough to trigger it. The counting
      # stub proves the handler refused, independent of what rendered.
      put_assist(generator: KilnCMS.StubAssistGenerator.Counting, model: "stub:stub")
      {:ok, _} = KilnCMS.StubAssistGenerator.Counting.start_link()
      KilnCMS.StubAssistGenerator.Counting.reset()

      # An editor scoped to author only "post" reads pages but cannot autosave one.
      reader = authed_user(:editor, %{editable_types: ["post"], readable_types: []})
      target = page(authed_user(:admin))
      {lv, html} = open_editor(conn, reader, target)

      refute html =~ "AI assist"

      render_click(lv, "assist_run", %{"bid" => block_id(target)})
      render_async(lv, 2_000)

      assert KilnCMS.StubAssistGenerator.Counting.count() == 0
    end
  end

  describe "the egress notice" do
    setup do
      editor = authed_user(:editor)
      %{editor: editor, page: page(editor)}
    end

    test "is absent for an on-prem provider", ctx do
      put_assist(generator: KilnCMS.StubAssistGenerator, model: "ollama:llama3.1")
      {lv, _html} = open_editor(ctx.conn, ctx.editor, ctx.page)

      refute open_panel(lv, ctx.page) =~ "sent to that provider"
    end

    test "names the provider for a hosted one", ctx do
      put_assist(generator: KilnCMS.StubAssistGenerator, model: "anthropic:claude-sonnet-5")
      {lv, _html} = open_editor(ctx.conn, ctx.editor, ctx.page)

      html = open_panel(lv, ctx.page)
      assert html =~ "sent to that provider"
      assert html =~ "anthropic"
    end
  end

  describe "generating" do
    setup %{conn: conn} do
      enable_stub()
      editor = authed_user(:editor)
      target = page(editor)
      {lv, _html} = open_editor(conn, editor, target)
      %{lv: lv, page: target, editor: editor}
    end

    test "the panel opens on the clicked block and offers the action list", ctx do
      html = open_panel(ctx.lv, ctx.page)

      assert html =~ "Summarize"
      assert html =~ "Improve"
      assert html =~ "Generate"
    end

    test "a suggestion appears after the async run completes", ctx do
      open_panel(ctx.lv, ctx.page)
      render_click(ctx.lv, "assist_run", %{"bid" => block_id(ctx.page)})
      html = render_async(ctx.lv, 2_000)

      assert html =~ "Suggestion"
      # The stub echoes the request, so this also proves the block's own text
      # and the record's locale reached the generator.
      assert html =~ "Generated for rewrite in en"
      assert html =~ "Step 1 is simple"
    end

    test "the selected action drives the request", ctx do
      open_panel(ctx.lv, ctx.page)
      render_click(ctx.lv, "assist_action", %{"action" => "summarize"})
      render_click(ctx.lv, "assist_run", %{"bid" => block_id(ctx.page)})

      assert render_async(ctx.lv, 2_000) =~ "Generated for summarize"
    end

    test "an unknown action id is ignored rather than selected", ctx do
      open_panel(ctx.lv, ctx.page)
      render_click(ctx.lv, "assist_action", %{"action" => "exfiltrate"})
      render_click(ctx.lv, "assist_run", %{"bid" => block_id(ctx.page)})

      # Still the default action, not a request built from the pushed string.
      assert render_async(ctx.lv, 2_000) =~ "Generated for rewrite"
    end

    test "the typed instruction travels with the request", ctx do
      open_panel(ctx.lv, ctx.page)
      render_change(ctx.lv, "assist_instruction", %{"assist_instruction" => "Mention cone ten"})
      render_click(ctx.lv, "assist_run", %{"bid" => block_id(ctx.page)})

      assert render_async(ctx.lv, 2_000) =~ "Mention cone ten"
    end

    test "draft on an empty instruction reports why instead of calling out", ctx do
      open_panel(ctx.lv, ctx.page)
      render_click(ctx.lv, "assist_action", %{"action" => "draft"})
      render_click(ctx.lv, "assist_run", %{"bid" => block_id(ctx.page)})

      assert render_async(ctx.lv, 2_000) =~ "Describe what this section should say"
    end

    test "opening a different block drops the previous block's suggestion", ctx do
      open_panel(ctx.lv, ctx.page, 0)
      render_click(ctx.lv, "assist_run", %{"bid" => block_id(ctx.page, 0)})
      assert render_async(ctx.lv, 2_000) =~ "Suggestion"

      # A genuinely different block: the prose describes content it doesn't
      # contain, and its Insert button would land it in the wrong place.
      refute open_panel(ctx.lv, ctx.page, 1) =~ "Generated for rewrite"
    end

    test "a run against a non-rich-text block is refused", ctx do
      # Only rich text renders a panel and mounts a hook to deliver to. Without
      # the type check an image block's id bought a billed generation over its
      # caption and then pushed the result at a hook that doesn't exist.
      editor = ctx.editor

      target =
        page(editor, %{
          blocks: [%{"_type" => "image", "url" => "https://example.com/a.png", "alt" => "A"}]
        })

      {lv, _html} = open_editor(ctx.conn, editor, target)
      open_panel(lv, target)
      render_click(lv, "assist_run", %{"bid" => block_id(target)})

      refute render_async(lv, 2_000) =~ "Suggestion"
    end

    test "events missing their params are ignored, not fatal", ctx do
      # A pushed event without its key would otherwise raise
      # FunctionClauseError and take the author's unsaved work with the view.
      for event <- ~w(assist_open assist_run assist_action) do
        assert render_click(ctx.lv, event, %{}) =~ "AI assist"
      end
    end

    test "an oversized instruction is clamped by the server, not just by maxlength", ctx do
      open_panel(ctx.lv, ctx.page)

      render_change(ctx.lv, "assist_instruction", %{
        "assist_instruction" => String.duplicate("x", 50_000)
      })

      render_click(ctx.lv, "assist_run", %{"bid" => block_id(ctx.page)})
      html = render_async(ctx.lv, 2_000)

      # The stub echoes the instruction it received; the panel must not be
      # holding — or re-rendering — 50 KB of it.
      refute html =~ String.duplicate("x", KilnCMS.Assist.max_instruction_chars() + 1)
    end

    test "a run for a block whose panel is not open is refused", ctx do
      # No open_panel/2 first: the id has to match the panel the author is
      # looking at, or a replayed event could generate against another block.
      render_click(ctx.lv, "assist_run", %{"bid" => block_id(ctx.page)})

      refute render_async(ctx.lv, 2_000) =~ "Suggestion"
    end
  end

  describe "accepting" do
    setup %{conn: conn} do
      enable_stub()
      editor = authed_user(:editor)
      target = page(editor)
      {lv, _html} = open_editor(conn, editor, target)
      open_panel(lv, target)
      render_click(lv, "assist_run", %{"bid" => block_id(target)})
      render_async(lv, 2_000)
      %{lv: lv, page: target, editor: editor}
    end

    test "insert pushes the prose to the block's editor instead of writing it", ctx do
      render_click(ctx.lv, "assist_apply", %{"mode" => "insert"})

      assert_push_event(ctx.lv, "assist:apply", payload)
      assert payload.block_id == block_id(ctx.page)
      assert payload.mode == "insert"
      assert [_ | _] = payload.paragraphs
      # Plain strings on the wire, never markup: the browser inserts them as
      # TipTap text nodes.
      assert Enum.all?(payload.paragraphs, &is_binary/1)

      # And the record itself is untouched until a normal save.
      reloaded = Ash.get!(KilnCMS.CMS.Page, ctx.page.id, actor: ctx.editor)
      refute inspect(reloaded.blocks) =~ "Generated for rewrite"
    end

    test "replace pushes the same payload with the replace mode", ctx do
      render_click(ctx.lv, "assist_apply", %{"mode" => "replace"})

      assert_push_event(ctx.lv, "assist:apply", payload)
      assert payload.mode == "replace"
    end

    test "an unrecognized mode is ignored rather than crashing the editor", ctx do
      # The guarded clause matches insert/replace only. Without the catch-all
      # behind it a crafted push raises FunctionClauseError, which takes the
      # LiveView — and the author's unsaved work — down with it.
      html = render_click(ctx.lv, "assist_apply", %{"mode" => "delete_everything"})

      assert html =~ "Insert at cursor"
      refute_push_event(ctx.lv, "assist:apply", _payload)
    end

    test "applying closes the panel so the same prose can't be inserted twice", ctx do
      html = render_click(ctx.lv, "assist_apply", %{"mode" => "insert"})

      refute html =~ "Insert at cursor"
    end

    test "a conflict reload drops the suggestion it just invalidated", ctx do
      # The reload gives every rich-text block a new element id, so a card left
      # on screen targets a hook that no longer exists and Insert silently does
      # nothing. Same reasoning as the SEO twin in content_editor_suggest_test.
      assert render(ctx.lv) =~ "Insert at cursor"

      html = render_click(ctx.lv, "reload_conflict", %{})

      refute html =~ "Insert at cursor"
      refute_push_event(ctx.lv, "assist:apply", _payload)
    end

    test "dismissing drops the suggestion but leaves the panel open", ctx do
      html = render_click(ctx.lv, "assist_dismiss", %{})

      refute html =~ "Insert at cursor"
      assert html =~ "Generate"
    end
  end

  describe "failure paths" do
    setup %{conn: conn} do
      editor = authed_user(:editor)
      target = page(editor)
      %{conn: conn, editor: editor, page: target}
    end

    test "a failing generator flashes rather than leaving the button spinning", ctx do
      enable_stub(KilnCMS.StubAssistGenerator.Failing)
      {lv, _html} = open_editor(ctx.conn, ctx.editor, ctx.page)
      open_panel(lv, ctx.page)
      render_click(lv, "assist_run", %{"bid" => block_id(ctx.page)})

      assert render_async(lv, 2_000) =~ "Couldn&#39;t generate text"
    end

    test "a second click while one is in flight does not start a second run", ctx do
      # The disabled attribute is client-side only, so a fast double-click or a
      # replayed event would otherwise generate — and bill — twice.
      put_assist(generator: KilnCMS.StubAssistGenerator.Counting, model: "stub:stub")
      {:ok, _} = KilnCMS.StubAssistGenerator.Counting.start_link()
      KilnCMS.StubAssistGenerator.Counting.reset()

      {lv, _html} = open_editor(ctx.conn, ctx.editor, ctx.page)
      open_panel(lv, ctx.page)
      render_click(lv, "assist_run", %{"bid" => block_id(ctx.page)})
      render_click(lv, "assist_run", %{"bid" => block_id(ctx.page)})
      render_async(lv, 2000)

      assert KilnCMS.StubAssistGenerator.Counting.count() == 1
    end
  end
end
