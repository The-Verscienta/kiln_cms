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

  # Every assertion below is downstream of collaboration being ON, and the flag
  # is `Application.get_env(:kiln_cms, :collab_prototype)` — **VM-global**, set
  # true by `config/test.exs` and re-read on every editor mount. An `async: true`
  # neighbour that flips it off turns `collab_active?/1` false here, the
  # co-editor never stands down, and the failure lands on `"Synced live"` with
  # nothing pointing at the cause.
  #
  # That is not hypothetical: it is what #1067 was filed as (a presence race,
  # 1 failure in 3 full-suite runs, never in isolation) and PR #1090 found and
  # fixed — by making `KilnCMSWeb.CollabSavedRefreshTest`, the only test that
  # turns the flag off, `async: false`. Nothing stops the next one, so this
  # check stands in front of the assertions and says which class of failure it
  # is. Cheap, and it fails on the right line.
  setup do
    assert KilnCMS.Collab.Crdt.enabled?(),
           """
           :collab_prototype is off, so every collaboration assertion in this file
           would fail for a reason that has nothing to do with what it tests.

           config/test.exs sets it true at boot, and the flag is VM-global — so a
           concurrent `async: true` test flipped it and did not put it back, or
           put it back after this one had already mounted. Find the test that
           writes `:collab_prototype` and make its module `async: false`, as
           KilnCMSWeb.CollabSavedRefreshTest and KilnCMSWeb.CollabChannelTest are
           (#1067, PR #1090).
           """

    :ok
  end

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
  #
  # Deadline-based (#1349). This helper's budget was already raised once
  # chasing a flake (#1095: 40 tries → 60, matching the sibling
  # `CollabSavedRefreshTest`) — the exact way a `tries` count decays that
  # ConnCase.eventually/4's docstring post-mortems. A deadline ends the
  # ratchet: generous when saturated, free when the condition already holds.
  defp await(lv, fun) do
    KilnCMS.Test.Eventually.eventually(
      fn ->
        html = render(lv)
        fun.(html) && html
      end,
      message: fn -> "condition never held; last render:\n#{render(lv)}" end
    )
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

    # The persister's autosave works as always. Done FIRST and confirmed
    # landed (#1095): a negative assertion that only checks "still Original"
    # passes for the wrong reason if it merely hasn't happened *yet*, and
    # can't tell "correctly refused to write" apart from "hasn't tried". A
    # confirmed prior write it must NOT clobber is a stronger anchor than the
    # seed value, and rules out both sessions silently failing to save at all.
    lv_low |> form("#page-editor", form: %{title: "From low"}) |> render_change()
    send(lv_low.pid, :autosave)
    await(lv_low, &(&1 =~ "Saved"))
    assert CMS.get_page!(page.id, actor: low).title == "From low"

    # The non-persister's edit does NOT autosave — indicator says synced, and
    # the persister's write above survives untouched.
    #
    # `await/2`, not a bare `render/1`. Presence is eventually consistent: the
    # `await` above proves two editors were present at *some* instant, and
    # nothing holds them there across the edit. Sampling one render makes a diff
    # in flight decide the test; polling tolerates it and still fails, with the
    # same message, when the co-editor genuinely autosaved.
    lv_high |> form("#page-editor", form: %{title: "From high"}) |> render_change()
    send(lv_high.pid, :autosave)
    await(lv_high, &(&1 =~ "Synced live"))
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
    await(lv_high, &(&1 =~ "Synced live"))

    # …but when they leave, the survivor is elected and saves them.
    GenServer.stop(lv_low.pid)
    await(lv_high, &(not (&1 =~ "2 editing")))
    send(lv_high.pid, :autosave)
    await(lv_high, &(&1 =~ "Saved"))
    assert CMS.get_page!(page.id, actor: high).title == "Now mine"
  end
end
