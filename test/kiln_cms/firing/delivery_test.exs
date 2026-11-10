defmodule KilnCMS.Firing.DeliveryTest do
  @moduledoc """
  "Stays up when the database doesn't" delivery (#341).

  The outage is simulated by running delivery in a **bare spawned process**: in
  the async sandbox that process is not allowed on the connection, so any
  database touch raises — exactly as a real Postgres outage would. A warm read
  therefore proves it never reached the DB.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.TypedFixtures

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
          blocks:
            typed_blocks([%{type: :heading, content: "Up", data: %{"level" => 1}, order: 0}])
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
    test "classifies connection/ownership errors (raw and Ash-wrapped) as unavailable" do
      assert Delivery.db_unavailable?(%DBConnection.ConnectionError{})
      assert Delivery.db_unavailable?(%DBConnection.OwnershipError{})
      # Ash wraps DB failures in an errors list and stringifies the exception.
      assert Delivery.db_unavailable?(%{errors: [%DBConnection.ConnectionError{}]})
      assert Delivery.db_unavailable?(%{error: "** (DBConnection.ConnectionError) …"})
    end

    test "does not treat a plain Postgrex.Error (a real SQL bug) as an outage" do
      # A constraint violation / bad type is a defect to surface, not a transient
      # outage — so it must NOT be classified as :unavailable.
      refute Delivery.db_unavailable?(%Postgrex.Error{})

      refute Delivery.db_unavailable?(%{
               error: "** (Postgrex.Error) ERROR 42703 undefined_column"
             })
    end

    test "does not swallow ordinary bugs" do
      refute Delivery.db_unavailable?(%RuntimeError{message: "boom"})
      refute Delivery.db_unavailable?(%KeyError{})
      refute Delivery.db_unavailable?(:oops)
    end
  end

  describe "warm reads are database-free (survive an outage)" do
    test "a cached record resolves with no DB access" do
      org = KilnCMS.Accounts.default_org_id()
      {slug, _id} = fired_page()
      # Warm the resolution cache from a process that has the DB.
      assert {:ok, _record} = Delivery.published(org, :page, slug, "en")

      # Now the DB is "down" (bare process): the warm slug still resolves.
      assert %{slug: ^slug} =
               without_db(fn -> unwrap(Delivery.published(org, :page, slug, "en")) end)
    end

    test "a cached artifact body reads with no DB access" do
      org = KilnCMS.Accounts.default_org_id()
      {slug, id} = fired_page()
      # Firing warmed the body cache. Said here, so a cold cache fails on this
      # line rather than as an `:unavailable` below (#2504).
      assert {:ok, _} = KilnCMS.Firing.Cache.get(org, :page, id, :json)
      # A request resolves the slug before it reads the body.
      assert {:ok, _} = Delivery.published(org, :page, slug, "en")

      # Warm it once more through the read under test, with the DB, right
      # before the outage: the body read below must be this one's cache entry.
      # The cache is node-wide; `KilnCMS.AsyncGlobalStateTest` keeps the calls
      # that clear it out of async modules.
      assert {:ok, %{"type" => "page"}} = Delivery.read_artifact(org, :page, id, :json)

      assert %{"type" => "page"} =
               without_db(fn -> unwrap(Delivery.read_artifact(org, :page, id, :json)) end)
    end

    # The cache above is node-wide, so this module (async) is only safe while
    # nothing an async test does clears it. A form write used to (#2504: the
    # body read above came back `:unavailable` in a full run); since #2501 it
    # drops only its site's delivery payloads.
    test "a form write leaves a cached artifact body in place" do
      org = KilnCMS.Accounts.default_org_id()
      {_slug, id} = fired_page()
      assert {:ok, _} = Delivery.read_artifact(org, :page, id, :json)

      CMS.create_form!(%{name: "Contact", slug: "del-form-#{System.unique_integer([:positive])}"},
        actor: admin(),
        tenant: org
      )

      assert {:ok, %{"type" => "page"}} = KilnCMS.Firing.Cache.get(org, :page, id, :json)
    end
  end

  describe "cold reads during an outage degrade gracefully" do
    test "an uncached slug returns :unavailable instead of crashing" do
      org = KilnCMS.Accounts.default_org_id()
      missing = "del-cold-#{System.unique_integer([:positive])}"
      assert :unavailable = without_db(fn -> Delivery.published(org, :page, missing, "en") end)
    end

    test "an uncached artifact returns :unavailable instead of crashing" do
      org = KilnCMS.Accounts.default_org_id()
      id = Ash.UUID.generate()
      assert :unavailable = without_db(fn -> Delivery.read_artifact(org, :page, id, :json) end)
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(other), do: other
end
