defmodule KilnCMSWeb.ContentEditorMentionTest do
  @moduledoc """
  The composer's `@` autocomplete.

  `KilnCMS.CMS.MentionsTest` proves the matching rule; this proves the editor
  is wired to it — that the dropdown opens on the handle being typed and not on
  one finished three sentences ago, that picking rewrites the draft the Send
  button will actually post, and that a comment sent this way carries a handle
  `Mentions.resolve/2` resolves.

  Every test creates its teammates **before** opening the editor: the roster is
  read once at mount, deliberately (a keystroke costs no query), so someone
  invited mid-session isn't suggestible until the editor is reloaded.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Mentions

  @password "password123456"

  defp authed_user(role, name) do
    email = "mention-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role,
      name: name
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

  defp page(actor) do
    CMS.create_page!(
      %{
        title: "Mentions spec",
        slug: "mentions-#{System.unique_integer([:positive])}",
        blocks: [%{"_type" => "quote", "text" => "First block"}]
      },
      actor: actor
    )
  end

  defp block_id(page), do: page.blocks |> hd() |> Map.fetch!(:value) |> Map.fetch!(:id)

  defp write(lv, body), do: render_change(lv, "comment_draft", %{"comment_body" => body})

  # A distinctive surname per call, so a test's own people are the only ones
  # its assertions can match.
  defp surname, do: "Q#{System.unique_integer([:positive])}"

  defp handle_for(family), do: "alice#{String.downcase(family)}"

  # Mount with the composer open on the block, after the roster exists.
  defp open_composer(conn, editor) do
    target = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{target.id}")
    render_click(lv, "comment_open", %{"bid" => block_id(target)})
    {lv, target}
  end

  setup do
    %{editor: authed_user(:editor, "Opener #{surname()}")}
  end

  describe "the dropdown" do
    setup do
      family = surname()
      %{family: family, alice: authed_user(:editor, "Alice #{family}")}
    end

    # The shortest handle that names her alone — she is the only Alice here, so
    # `@alice` is offered rather than the full `@alice<surname>`. The longer
    # form is what ambiguity forces, not the default.
    test "suggests a teammate once an @ is being typed, under the shortest handle", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)
      html = write(lv, "Can you look at this @alice")

      assert html =~ "Alice #{ctx.family}"
      assert html =~ "@alice<"
      refute html =~ "@#{handle_for(ctx.family)}"
    end

    test "a bare @ offers the roster — pressing @ is a request to see who's here", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)
      assert write(lv, "@") =~ "Alice #{ctx.family}"
    end

    test "matches case-insensitively and through the separators a name might use", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)

      for typed <- ["@ALICE", "@Alice-#{ctx.family}", "@alice_#{String.downcase(ctx.family)}"] do
        assert write(lv, "Hey #{typed}") =~ "Alice #{ctx.family}"
      end
    end

    test "stays closed when there is no @ being typed", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)
      refute write(lv, "Just plain prose about alice") =~ "Alice #{ctx.family}"
    end

    # The dropdown follows the handle under the cursor, not every handle in the
    # body — reopening over a mention finished three sentences ago would fight
    # the person typing.
    test "closes once the author moves past the mention", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)

      assert write(lv, "@alice") =~ "Alice #{ctx.family}"

      refute write(lv, "@#{handle_for(ctx.family)} please check this") =~ "Alice #{ctx.family}"
    end

    test "an email address in the body does not open it", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)
      refute write(lv, "mail alice@#{String.downcase(ctx.family)}") =~ "Alice #{ctx.family}"
    end

    test "closes when the panel does", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)

      assert write(lv, "@alice") =~ "Alice #{ctx.family}"
      refute render_click(lv, "comment_close", %{}) =~ "Alice #{ctx.family}"
    end
  end

  describe "ambiguity" do
    setup do
      one = surname()
      two = surname()

      %{
        one: one,
        two: two,
        alice_one: authed_user(:editor, "Alice #{one}"),
        alice_two: authed_user(:editor, "Alice #{two}")
      }
    end

    test "two Alices are both offered, each under a handle that resolves", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)
      html = write(lv, "@alice")

      assert html =~ "Alice #{ctx.one}"
      assert html =~ "Alice #{ctx.two}"
      assert html =~ "@#{handle_for(ctx.one)}"

      # And the offer is honest: that handle names exactly that person.
      assert [%{id: id}] =
               Mentions.resolve("@#{handle_for(ctx.one)}", [ctx.alice_one, ctx.alice_two])

      assert id == ctx.alice_one.id
    end

    # `@alice` is what was typed and what neither Alice can be reached by;
    # offering it would be offering a mention that notifies nobody.
    test "the bare ambiguous handle is never the one offered", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)
      html = write(lv, "@alice")

      assert html =~ "@#{handle_for(ctx.one)}"
      assert html =~ "@#{handle_for(ctx.two)}"
      refute html =~ ~s(>@alice</span>)
    end
  end

  describe "picking one" do
    setup do
      family = surname()
      %{family: family, alice: authed_user(:editor, "Alice #{family}")}
    end

    test "replaces the partial handle and leaves the author mid-sentence", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)
      handle = handle_for(ctx.family)

      write(lv, "Can you check @ali")
      html = render_click(lv, "mention_pick", %{"handle" => handle})

      assert html =~ "Can you check @#{handle} "
      # Picking closes the dropdown; nothing is left hovering over the composer.
      refute html =~ "Alice #{ctx.family}</span>"
    end

    test "the comment that gets sent carries the handle, and it resolves", ctx do
      {lv, target} = open_composer(ctx.conn, ctx.editor)
      handle = handle_for(ctx.family)

      write(lv, "Over to you @ali")
      render_click(lv, "mention_pick", %{"handle" => handle})
      render_click(lv, "comment_add", %{"bid" => block_id(target)})

      assert [comment] = CMS.list_comments_for!("page", target.id, actor: ctx.editor)
      # The composer's trailing space is gone: Ash trims a string attribute on
      # the way in, which is why the assertion is on the stored body rather
      # than on what was typed.
      assert comment.body == "Over to you @#{handle}"
      assert [%{id: id}] = Mentions.resolve(comment.body, [ctx.alice])
      assert id == ctx.alice.id
    end

    test "picking with no draft at all is ignored, not fatal", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)
      assert render_click(lv, "mention_pick", %{"handle" => "someone"}) =~ "Mentions spec"
    end

    test "a pick with no handle is ignored", ctx do
      {lv, _page} = open_composer(ctx.conn, ctx.editor)
      assert render_click(lv, "mention_pick", %{}) =~ "Mentions spec"
    end
  end
end
