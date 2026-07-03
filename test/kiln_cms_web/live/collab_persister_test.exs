defmodule KilnCMSWeb.CollabPersisterTest do
  @moduledoc """
  Under active collaboration only ONE editor persists (the lowest user id —
  the same deterministic election the advisory field locks use): concurrent
  autosaves would race the optimistic lock even though CRDT content has
  converged. The others show a "synced" indicator, and take over persistence
  if the persister leaves.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "cp-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "cp-#{System.unique_integer([:positive])}"

  # Poll a LiveView's render until `fun.(html)` holds (presence diffs arrive
  # asynchronously; never assert on a fixed sleep).
  defp await(lv, fun, tries \\ 40) do
    html = render(lv)

    cond do
      fun.(html) ->
        html

      tries == 0 ->
        flunk("condition never held; last render:\n#{html}")

      true ->
        Process.sleep(25)
        await(lv, fun, tries - 1)
    end
  end

  defp two_editors do
    a = authed_user(:editor)
    b = authed_user(:editor)
    low = Enum.min_by([a, b], & &1.id)
    high = Enum.max_by([a, b], & &1.id)
    {low, high}
  end

  test "only the elected persister autosaves; the co-editor shows synced", %{conn: conn} do
    {low, high} = two_editors()
    page = CMS.create_page!(%{title: "Original", slug: slug()}, actor: low)

    {:ok, lv_low, _} = conn |> log_in(low) |> live(~p"/editor/pages/#{page.id}")
    {:ok, lv_high, _} = build_conn() |> log_in(high) |> live(~p"/editor/pages/#{page.id}")

    # Both sessions see each other before we assert election behavior.
    await(lv_low, &(&1 =~ "2 editing"))
    await(lv_high, &(&1 =~ "2 editing"))

    # The non-persister's edit does NOT autosave — indicator says synced.
    lv_high |> form("#page-editor", form: %{title: "From high"}) |> render_change()
    send(lv_high.pid, :autosave)
    assert render(lv_high) =~ "Synced live"
    assert CMS.get_page!(page.id, actor: low).title == "Original"

    # The persister's autosave works as always.
    lv_low |> form("#page-editor", form: %{title: "From low"}) |> render_change()
    send(lv_low.pid, :autosave)
    await(lv_low, &(&1 =~ "Saved"))
    assert CMS.get_page!(page.id, actor: low).title == "From low"
  end

  test "a lone editor autosaves exactly as before", %{conn: conn} do
    editor = authed_user(:editor)
    page = CMS.create_page!(%{title: "Solo", slug: slug()}, actor: editor)

    {:ok, lv, _} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")

    lv |> form("#page-editor", form: %{title: "Solo saved"}) |> render_change()
    send(lv.pid, :autosave)
    await(lv, &(&1 =~ "Saved"))
    assert CMS.get_page!(page.id, actor: editor).title == "Solo saved"
  end

  test "the co-editor takes over persistence when the persister leaves", %{conn: conn} do
    {low, high} = two_editors()
    page = CMS.create_page!(%{title: "Handoff", slug: slug()}, actor: low)

    {:ok, lv_low, _} = conn |> log_in(low) |> live(~p"/editor/pages/#{page.id}")
    {:ok, lv_high, _} = build_conn() |> log_in(high) |> live(~p"/editor/pages/#{page.id}")
    await(lv_high, &(&1 =~ "2 editing"))

    # Pending edits are only "synced" while the persister is around…
    lv_high |> form("#page-editor", form: %{title: "Now mine"}) |> render_change()
    assert render(lv_high) =~ "Synced live"

    # …but when they leave, the survivor is elected and saves them.
    GenServer.stop(lv_low.pid)
    await(lv_high, &(not (&1 =~ "2 editing")))
    send(lv_high.pid, :autosave)
    await(lv_high, &(&1 =~ "Saved"))
    assert CMS.get_page!(page.id, actor: high).title == "Now mine"
  end
end
