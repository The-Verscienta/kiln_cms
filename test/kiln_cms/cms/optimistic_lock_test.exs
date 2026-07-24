defmodule KilnCMS.CMS.OptimisticLockTest do
  @moduledoc """
  Content `:update` uses optimistic concurrency (`lock_version`): an update only
  applies if the in-memory version still matches the row, so two editors saving
  the same draft can't silently clobber each other — the loser gets a
  `StaleRecord` error.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "lock-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "lock-#{System.unique_integer([:positive])}"

  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(_other), do: false

  test "updates increment the version" do
    admin = admin()
    page = CMS.create_page!(%{title: "Orig", slug: slug()}, actor: admin)
    assert page.lock_version == 1

    page = CMS.update_page!(page, %{title: "Once"}, actor: admin)
    assert page.lock_version == 2

    page = CMS.update_page!(page, %{title: "Twice"}, actor: admin)
    assert page.lock_version == 3
  end

  test "a stale update (concurrent edit) is rejected with StaleRecord" do
    admin = admin()
    page = CMS.create_page!(%{title: "Orig", slug: slug()}, actor: admin)

    # Editor A saves first, from the loaded v1 record.
    assert {:ok, _} = CMS.update_page(page, %{title: "A wins"}, actor: admin)

    # Editor B still holds the v1 record → its save conflicts.
    assert {:error, error} = CMS.update_page(page, %{title: "B loses"}, actor: admin)
    assert stale?(error)

    # The first edit survived; it wasn't clobbered.
    assert CMS.get_page!(page.id, actor: admin).title == "A wins"
  end

  # T3.3: a stateless (headless) writer loads the row fresh on every request, so
  # the built-in optimistic_lock always matches and never fires. `expected_version`
  # lets such a client opt into conflict detection by echoing the version it read.
  test "expected_version rejects a stale headless update, accepts a matching one" do
    admin = admin()
    page = CMS.create_page!(%{title: "Orig", slug: slug()}, actor: admin)

    # Someone else saves → the row is now version 2.
    {:ok, _} = CMS.update_page(page, %{title: "Elsewhere"}, actor: admin)
    fresh = CMS.get_page!(page.id, actor: admin)
    assert fresh.lock_version == 2

    # A client that based its edit on version 1 is rejected, even loading fresh.
    assert {:error, error} =
             CMS.update_page(fresh, %{title: "Stale write", expected_version: 1}, actor: admin)

    refute stale?(error)
    assert CMS.get_page!(page.id, actor: admin).title == "Elsewhere"

    # Echoing the current version succeeds.
    assert {:ok, _} =
             CMS.update_page(fresh, %{title: "Fresh write", expected_version: 2}, actor: admin)

    # Omitting the argument preserves the previous last-writer-wins behavior.
    latest = CMS.get_page!(page.id, actor: admin)
    assert {:ok, updated} = CMS.update_page(latest, %{title: "No version"}, actor: admin)
    assert updated.title == "No version"
  end

  test "reloading clears the conflict" do
    admin = admin()
    page = CMS.create_page!(%{title: "Orig", slug: slug()}, actor: admin)
    {:ok, _} = CMS.update_page(page, %{title: "A"}, actor: admin)

    # Re-fetch (as the UI's "reload" does) and the next update succeeds.
    fresh = CMS.get_page!(page.id, actor: admin)
    assert {:ok, updated} = CMS.update_page(fresh, %{title: "B"}, actor: admin)
    assert updated.title == "B"
  end
end
