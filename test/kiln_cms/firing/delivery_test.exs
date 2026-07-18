defmodule KilnCMS.Firing.DeliveryTest do
  @moduledoc """
  "Stays up when the database doesn't" delivery (#341).

  The outage is simulated by running delivery in a **bare spawned process**: in
  the async sandbox that process is not allowed on the connection, so any
  database touch raises — exactly as a real Postgres outage would. A warm read
  therefore proves it never reached the DB.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Firing.Delivery

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "del-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp fired_page do
    actor = admin()
    slug = "del-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Resilient",
          slug: slug,
          blocks: [%{type: :heading, content: "Up", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    drain_oban()
    {slug, page.id}
  end

  # Run `fun` in a bare process with no sandbox allowance (a simulated outage),
  # returning its result or {:raised, module} if it raised.
  defp without_db(fun) do
    parent = self()

    spawn(fn ->
      result =
        try do
          {:ok_result, fun.()}
        rescue
          e -> {:raised, e.__struct__}
        end

      send(parent, {:without_db, result})
    end)

    receive do
      {:without_db, {:ok_result, value}} -> value
      {:without_db, {:raised, mod}} -> {:raised, mod}
    after
      2000 -> flunk("timed out waiting for the no-DB task")
    end
  end

  describe "db_unavailable?/1" do
    test "classifies connection/ownership/postgrex errors as unavailable" do
      assert Delivery.db_unavailable?(%DBConnection.ConnectionError{})
      assert Delivery.db_unavailable?(%DBConnection.OwnershipError{})
      assert Delivery.db_unavailable?(%Postgrex.Error{})
      # Ash wraps DB failures in an errors list — recurse into it.
      assert Delivery.db_unavailable?(%{errors: [%DBConnection.ConnectionError{}]})
    end

    test "does not swallow ordinary bugs" do
      refute Delivery.db_unavailable?(%RuntimeError{message: "boom"})
      refute Delivery.db_unavailable?(%KeyError{})
      refute Delivery.db_unavailable?(:oops)
    end
  end

  describe "warm reads are database-free (survive an outage)" do
    test "a cached record resolves with no DB access" do
      {slug, _id} = fired_page()
      # Warm the resolution cache from a process that has the DB.
      assert {:ok, _record} = Delivery.published(:page, slug, "en")

      # Now the DB is "down" (bare process): the warm slug still resolves.
      assert %{slug: ^slug} = without_db(fn -> unwrap(Delivery.published(:page, slug, "en")) end)
    end

    test "a cached artifact body reads with no DB access" do
      {slug, id} = fired_page()
      # Firing warmed the body cache; make one resolution to be safe.
      assert {:ok, _} = Delivery.published(:page, slug, "en")

      assert %{"type" => "page"} =
               without_db(fn -> unwrap(Delivery.read_artifact(:page, id, :json)) end)
    end
  end

  describe "cold reads during an outage degrade gracefully" do
    test "an uncached slug returns :unavailable instead of crashing" do
      missing = "del-cold-#{System.unique_integer([:positive])}"
      assert :unavailable = without_db(fn -> Delivery.published(:page, missing, "en") end)
    end

    test "an uncached artifact returns :unavailable instead of crashing" do
      id = Ash.UUID.generate()
      assert :unavailable = without_db(fn -> Delivery.read_artifact(:page, id, :json) end)
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(other), do: other
end
