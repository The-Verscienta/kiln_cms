defmodule KilnCMSWeb.EditorTagWindowTest do
  @moduledoc """
  The tag picker's mount-time window (#1149): the vocabulary is capped at mount,
  so the filter box round-trips to the server to reach a tag past the window,
  and an attached tag from outside it still renders a checkbox.

  `async: false`, and lifted out of `KilnCMSWeb.EditorLiveTest` to be it. The
  cap is `config :kiln_cms, :editor, max_tags:`, read at mount, and application
  env is VM-global — setting it to 3 from an async test capped every *other*
  editor that mounted while this one ran. Nothing else mounts the editor with
  more than three tags today, so nothing broke; that is an invariant no test
  states and none would notice losing. A sync module runs after the async ones,
  with nothing left to leak into.
  """
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Tag

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp authed_user(role) do
    email = "editor-#{uniq()}@example.com"

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

  # The tag names the picker actually rendered, read out of the `#tag-picker`
  # fieldset.
  #
  # Asserting on the whole document instead is what made this test flaky: the
  # names here are three characters long, all four of them are hex, and any of
  # the UUIDs and slugs elsewhere on an editor page contains such a run often
  # enough that `refute html =~ "aaa"` failed at random under load. Reading the
  # picker's own controls also says what the test means — "the window holds
  # these tags" — rather than "this string is nowhere on the page".
  defp picker_tags(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("#tag-picker [data-tag-item]")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  test "the tag picker loads a capped window and filters the full vocabulary", %{conn: conn} do
    previous = Application.get_env(:kiln_cms, :editor, [])
    Application.put_env(:kiln_cms, :editor, Keyword.put(previous, :max_tags, 3))
    on_exit(fn -> Application.put_env(:kiln_cms, :editor, previous) end)

    editor = authed_user(:editor)
    # Alphabetical: aaa, bbb, ccc fill the window; zzz is past it.
    for name <- ~w(aaa bbb ccc) do
      Ash.Seed.seed!(Tag, %{name: name, slug: "t-#{uniq()}-#{name}"})
    end

    zzz = Ash.Seed.seed!(Tag, %{name: "zzz", slug: "t-#{uniq()}-zzz"})

    post = CMS.create_post!(%{title: "T", slug: "p-#{uniq()}", tag_ids: [zzz.id]}, actor: editor)

    {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/editor/posts/#{post.id}")

    assert html =~ "Showing the first 3 tags"
    # The window, plus the attached tag from past it (the union), so detach
    # stays possible.
    assert picker_tags(html) == ~w(aaa bbb ccc zzz)
    assert html =~ ~s(value="#{zzz.id}")

    html = render_hook(lv, "filter_tags", %{"q" => "zzz"})
    refute html =~ "Showing the first"
    assert picker_tags(html) == ["zzz"]
  end
end
