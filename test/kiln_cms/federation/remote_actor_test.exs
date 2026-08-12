defmodule KilnCMS.Federation.RemoteActorTest do
  @moduledoc """
  Pins the two cache invariants the controller tests only prove behaviourally
  (#966, #1163): `expire:` really sets a TTL, and the configured cap really
  evicts. Both fail silently if broken — `Cachex` ignores unknown options
  rather than raising on `ttl:` instead of `expire:`, and an unenforced cap
  would just look like a bigger table.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Federation.RemoteActor
  alias KilnCMS.Keys

  require Cachex.Spec

  @remote_actor "https://remote.example/users/ttlcheck"

  setup do
    Cachex.clear(RemoteActor.cache_name())
    :ok
  end

  defp stub_actor(id \\ @remote_actor) do
    test_pid = self()
    {:ok, key} = Keys.rsa_private_key(Keys.generate_rsa_pem())

    document = %{
      "id" => id,
      "inbox" => id <> "/inbox",
      "publicKey" => %{
        "id" => id <> "#main-key",
        "owner" => id,
        "publicKeyPem" => Keys.rsa_public_key_pem(key)
      }
    }

    Req.Test.stub(KilnCMS.Federation, fn conn ->
      send(test_pid, :actor_fetched)

      conn
      |> Plug.Conn.put_resp_content_type("application/activity+json")
      |> Plug.Conn.send_resp(200, Jason.encode!(document))
    end)
  end

  # Polls instead of a fixed sleep: `Cachex.Limit.Evented`'s hook defaults to
  # `async?: true` (Cachex.Hook), so a write's eviction has not necessarily
  # landed by the time `Cachex.put/3` returns.
  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition was not met within the deadline")

      true ->
        Process.sleep(10)
        wait_until(fun, deadline)
    end
  end

  describe "expire: actually sets a TTL" do
    test "a cached fetch carries a positive TTL, not an immortal entry" do
      stub_actor()
      assert {:ok, _actor} = RemoteActor.fetch(@remote_actor)
      assert_received :actor_fetched

      # `Cachex` silently ignores unknown options — passing `ttl:` instead of
      # `expire:` would compile, run, and leave this `nil` (immortal) forever.
      assert {:ok, ttl} = Cachex.ttl(RemoteActor.cache_name(), @remote_actor)
      assert is_integer(ttl) and ttl > 0
      assert ttl <= :timer.minutes(10)
    end

    test "a fragment is stripped before the cache key, so both share the TTL'd entry" do
      stub_actor()
      assert {:ok, _actor} = RemoteActor.fetch(@remote_actor <> "#main-key")
      assert_received :actor_fetched

      assert {:ok, ttl} = Cachex.ttl(RemoteActor.cache_name(), @remote_actor)
      assert is_integer(ttl) and ttl > 0
    end
  end

  describe "a failed fetch is not committed" do
    test "no entry, immortal or otherwise, is left behind" do
      Req.Test.stub(KilnCMS.Federation, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, _reason} = RemoteActor.fetch(@remote_actor)
      assert {:ok, false} = Cachex.exists?(RemoteActor.cache_name(), @remote_actor)
    end
  end

  describe "the cap really evicts" do
    test "the running instance is configured with the module's documented cap" do
      assert {:ok, cache} = Cachex.inspect(RemoteActor.cache_name(), :cache)
      hooks = Cachex.Spec.cache(cache, :hooks)
      all_hooks = Cachex.Spec.hooks(hooks, :pre) ++ Cachex.Spec.hooks(hooks, :post)

      assert evented =
               Enum.find(all_hooks, &(Cachex.Spec.hook(&1, :module) == Cachex.Limit.Evented))

      assert Cachex.Spec.hook(evented, :args) == {5_000, [reclaim: 0.1]}
    end

    # Filling the live 5,000-entry instance to prove this would be slow (and
    # would leak entries across async tests sharing it), so this builds an
    # isolated instance from the identical hook shape, sized small.
    test "Cachex.Limit.Evented bounds a cache built from the same shape" do
      name = :"remote_actor_cache_eviction_test_#{System.unique_integer([:positive])}"
      max = 10

      start_supervised!(
        Supervisor.child_spec(
          {Cachex,
           name: name,
           hooks: [
             Cachex.Spec.hook(module: Cachex.Limit.Evented, args: {max, [reclaim: 0.1]})
           ]},
          id: name
        )
      )

      for n <- 1..(max * 5) do
        Cachex.put!(name, n, :value)
      end

      wait_until(fn -> Cachex.size!(name) <= max end)
    end
  end
end
