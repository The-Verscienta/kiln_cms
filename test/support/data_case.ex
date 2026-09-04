defmodule KilnCMS.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use KilnCMS.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias KilnCMS.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import KilnCMS.DataCase
      # `today/0` (one clock read per test) and `stable_day/1` (re-run once
      # if UTC midnight passed under the body) — the #1358 clock-edge tools.
      import KilnCMS.Test.StableDay
    end
  end

  setup tags do
    KilnCMS.DataCase.setup_sandbox(tags)
    :ok
  end

  # Every `KilnCMS.Cache` key whose entire identity is the organization — the
  # per-site *aggregate* keys (branding, code injection, the feed policy, the
  # running-experiment set, the head-generation token, the sitemap, …) as
  # opposed to the per-record ones, which also carry a type, a slug and a
  # locale.
  #
  # That distinction is the whole of it. A per-record key contains a slug the
  # writing test generated uniquely, so a stale entry is keyed by something no
  # later test asks for. An aggregate key contains *nothing but* the org id — so
  # for the one org whose id is fixed for the entire run, it is a single global
  # slot that every test in the suite shares.
  #
  # Reflected rather than listed, and that is the point rather than a flourish:
  # a hand-written list would have to be edited the day someone adds a key,
  # which is the same act of remembering that the per-module `bust_branding/1`
  # calls needed and that this mechanism exists to retire. `KilnCMS.Cache` names
  # all of them `*_key/1`; `feed_key/3`, the one key function that is not a bare
  # aggregate, is excluded by arity.
  #
  # Resolved at compile time, so it costs nothing per test — and so that adding
  # a key to `KilnCMS.Cache` recompiles this file and is covered on the day it
  # lands.
  @org_aggregate_keys for {name, 1} <- KilnCMS.Cache.__info__(:functions),
                          String.ends_with?(Atom.to_string(name), "_key"),
                          do: name

  # A rename of that convention must not quietly turn the mechanism into a no-op:
  # every test would go on passing, and the leak would come back invisibly.
  if @org_aggregate_keys == [] do
    raise "no `*_key/1` functions found on KilnCMS.Cache — the per-test cache " <>
            "isolation in KilnCMS.DataCase would silently do nothing"
  end

  @doc """
  Sets up the sandbox based on the test tags, and isolates the shared cache.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(KilnCMS.Repo, shared: not tags[:async])

    bust_default_org_aggregates()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      bust_default_org_aggregates()
    end)
  end

  @doc """
  Drop every cached aggregate belonging to the **default** organization, so a
  value resolved inside one test's sandbox cannot be read by another's.

  `KilnCMS.Cache` is a process-global Cachex living outside the SQL sandbox, and
  its entries carry a TTL of minutes. A test that seeds a `SiteBranding` row for
  the default org and then resolves it caches the *branded* struct; the row is
  rolled back when the test ends and the cache entry is not, so a later test
  reading that site's branding is served a site name that no longer exists in
  any database. That is not hypothetical — it produced two confirmed load-flaky
  failures (`KilnCMSWeb.ManifestControllerTest` reading `"Poisoned Editor"`,
  `KilnCMSWeb.BrandTokensTest` reading `"Wordmark Co"` from `KilnCMS.PushTest`).

  Both ends, deliberately:

    * on **entry**, so a test is not at the mercy of what ran before it —
      including the boot-time resolves and the tests that use a bare
      `ExUnit.Case` and never reach this function;
    * on **exit**, so the poison never outlives the transaction that produced
      it in the first place. Only a sandboxed test can write the rows behind
      one of these values, so cleaning up here covers every *producer*, which in
      turn protects victims that are not `DataCase` tests at all.

  Scoped to the default org rather than clearing the cache wholesale. Every
  other org in the suite is seeded per test with a fresh UUID, so its keys are
  unique and can never be read by a later test — and a blanket
  `Cachex.clear/1` would instead reach *into* concurrently running async tests
  and drop entries they are still asserting on. The tests that pin caching
  behaviour itself (`KilnCMS.BrandingTest`'s read-path cases, `KilnCMS.CacheTest`)
  use seeded orgs or keys of their own for exactly that reason, so nothing here
  touches them.

  `KilnCMS.Cache.Hosts` is deliberately left alone. It has the same
  outlives-the-transaction property, but not the same collision: it is keyed by
  *host*, and the hosts the suite invents are built from per-test unique slugs,
  while the one fixed host resolves to the default org, which is permanent. It
  is also the cache that must **not** be cleared indiscriminately — an async
  test doing exactly that is what made
  `KilnCMSWeb.ArtifactControllerResilienceTest` flaky (#1124).
  """
  @spec bust_default_org_aggregates() :: :ok
  def bust_default_org_aggregates do
    cache = KilnCMS.Cache.cache_name()
    org_id = KilnCMS.Accounts.default_org_id()

    Enum.each(@org_aggregate_keys, fn name ->
      Cachex.del(cache, apply(KilnCMS.Cache, name, [org_id]))
    end)
  end

  @doc """
  The `KilnCMS.Cache` key-building functions `bust_default_org_aggregates/0`
  covers, as `{function_name, key}` pairs. Exposed so the mechanism's own test
  can assert on what it actually reached rather than restating the list.
  """
  @spec org_aggregate_keys(Ash.UUID.t()) :: [{atom(), String.t()}]
  def org_aggregate_keys(org_id) do
    Enum.map(@org_aggregate_keys, &{&1, apply(KilnCMS.Cache, &1, [org_id])})
  end

  @doc """
  Drain **every** configured Oban queue until no job runs, aggregating the
  per-queue results. Jobs are split across workload queues (firing/search/mail/
  …), and a job in one queue can enqueue into another, so draining a single
  queue is no longer sufficient — this loops over all queues until a full pass
  runs nothing. Returns the summed `%{success:, failure:, …}` map.
  """
  def drain_oban(acc \\ %{}) do
    queues =
      :kiln_cms |> Application.fetch_env!(Oban) |> Keyword.fetch!(:queues) |> Keyword.keys()

    pass =
      Enum.reduce(queues, %{}, fn queue, totals ->
        queue
        |> then(&Oban.drain_queue(queue: &1, with_recursion: true))
        |> Map.merge(totals, fn _k, v1, v2 -> v1 + v2 end)
      end)

    acc = Map.merge(acc, pass, fn _k, v1, v2 -> v1 + v2 end)

    if pass |> Map.values() |> Enum.sum() > 0, do: drain_oban(acc), else: acc
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
