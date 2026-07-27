defmodule KilnCMSWeb.AutosaveRichTextReproTest do
  @moduledoc """
  Repro for prose loss on autosave: a rich_text body pushed by the TipTap hook
  must survive the debounced draft autosave (which submits
  `AshPhoenix.Form.params(form)` without re-injecting `rich_bodies`).
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import KilnCMS.TipTapFixtures

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "rt-autosave-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  test "a pushed rich_text body survives the draft autosave", %{conn: conn} do
    admin = authed_admin()

    page =
      CMS.create_page!(
        %{
          title: "Autosave repro",
          slug: "autosave-repro-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "rich_text", "legacy_html" => ""}]
        },
        actor: admin
      )

    [%Ash.Union{value: existing}] = page.blocks

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    doc = doc([para("typed then autosaved")])
    render_hook(lv, "rich_text_body", %{"id" => existing.id, "idx" => "0", "doc" => doc})

    # Fire the debounced autosave timer.
    send(lv.pid, :autosave)
    _ = render(lv)

    assert [%Ash.Union{value: block}] = CMS.get_page!(page.id, authorize?: false).blocks

    assert [%{"children" => [%{"text" => "typed then autosaved"}]}] = block.body,
           "autosave lost the pushed body: #{inspect(block, pretty: true)}"

    # And an explicit save afterwards (the DOM posts only legacy_html) must not
    # wipe it either.
    lv |> form("#page-editor") |> render_submit()

    assert [%Ash.Union{value: after_save}] = CMS.get_page!(page.id, authorize?: false).blocks

    assert [%{"children" => [%{"text" => "typed then autosaved"}]}] = after_save.body,
           "explicit save after autosave wiped the body: #{inspect(after_save, pretty: true)}"
  end
end
