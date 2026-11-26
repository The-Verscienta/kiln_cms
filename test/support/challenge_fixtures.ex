defmodule KilnCMS.ChallengeFixtures do
  @moduledoc """
  Test scaffolding for human verification (#2249).

  No provider is configured in `config/test.exs`, so nothing is ever required.
  `enable!/1` turns it on for one test with `KilnCMS.ChallengeFake`, sets a
  secret, and restores everything on exit. Tests that use it are
  `async: false`: the configuration lives in application env and the secret in
  the OS environment, both node-wide.

  A test that spends an axis's free attempts and then expects a challenge also
  calls `pin_windows!/1` (#2649): see there for why.
  """

  alias KilnCMS.Test.BudgetWindow

  @secret_var "KILN_TEST_CHALLENGE_SECRET"

  # The `ThrottleStore` window behind each axis of `KilnCMS.Challenge.Gate`:
  # the application env module and key that set its length. `:account` is
  # also the sign-in pause's window, and `:mail` (not a gate axis) is
  # `AccountThrottle`'s per-address mail budget window, which the sign-in
  # unlock tests pin too (#2937).
  @windows %{
    account: {KilnCMS.Accounts.AccountThrottle, :window},
    mail: {KilnCMS.Accounts.AccountThrottle, :mail_window},
    ip: {KilnCMS.Challenge, :ip_window},
    registration: {KilnCMS.Challenge, :registration_window}
  }

  @doc """
  Turn challenges on for this test. `opts` are merged into
  `KilnCMS.Challenge`'s config over these defaults: provider `"fake"`, a site
  key, `sign_in: :adaptive`, `registration: :adaptive`, `api_sign_in: false`.
  Verification calls are reported to the calling process (`KilnCMS.ChallengeFake`).
  """
  @spec enable!(keyword()) :: :ok
  def enable!(opts \\ []) do
    original = Application.get_env(:kiln_cms, KilnCMS.Challenge, [])
    original_fake = Application.get_env(:kiln_cms, KilnCMS.ChallengeFake, [])
    original_secret = System.get_env(@secret_var)

    System.put_env(@secret_var, "test-secret")

    # The outage flag is node-wide too: start each test without one. So is
    # the memoised provider.
    KilnCMS.Challenge.clear_outage()
    KilnCMS.Challenge.reset_cache()

    Application.put_env(
      :kiln_cms,
      KilnCMS.Challenge,
      original
      |> Keyword.merge(
        provider: "fake",
        site_key: "test-site-key",
        secret_key: {:env, %{"var" => @secret_var}},
        sign_in: :adaptive,
        registration: :adaptive,
        api_sign_in: false
      )
      |> Keyword.merge(opts)
    )

    Application.put_env(:kiln_cms, KilnCMS.ChallengeFake, notify: self())

    ExUnit.Callbacks.on_exit(fn ->
      KilnCMS.Challenge.clear_outage()
      KilnCMS.Challenge.reset_cache()
      Application.put_env(:kiln_cms, KilnCMS.Challenge, original)
      Application.put_env(:kiln_cms, KilnCMS.ChallengeFake, original_fake)

      if original_secret,
        do: System.put_env(@secret_var, original_secret),
        else: System.delete_env(@secret_var)
    end)

    :ok
  end

  @doc """
  Pin the `ThrottleStore` window behind each of `axes` (`:account`, `:mail`,
  `:ip`, `:registration`) so that no window boundary falls inside this test,
  and restore the configuration on exit.

  Each axis counts its free attempts in a fixed window aligned to the epoch by
  the database clock: the account axis in `AccountThrottle`'s (15 minutes),
  the address axis in `ip_window` (15 minutes), registrations in
  `registration_window` (an hour). A test that spends an axis and then expects
  a challenge fails whenever a quarter hour falls between the spending and the
  gate: the gate's charge lands in a new, empty window, so it is free, and the
  gate answers `:ok` without asking anyone (#2649, which CI hit 4 ms after
  17:30).

  The same holds for a pause: a test that spends the sign-in budget and then
  asks for an unlock mail is mailed nothing when a quarter hour falls between,
  as the account is no longer paused in the new window (#2937). A test that
  asserts on the unlock mail budget pins `:mail` for the same reason (an hour,
  `mail_window`).

  The length is `KilnCMS.Test.BudgetWindow.fresh_window_ms/2` (about 20 days)
  computed from the database's `clock_timestamp()`, the clock
  `ThrottleStore` indexes windows by, so a lag between this node's clock and
  Postgres cannot put a boundary inside the test either. The window number
  stays the same for the rest of the test however long it runs.

  Opt-in, rather than one suite-wide setting in `test_helper.exs`: the rest of
  the suite keeps the realistic windows of `config/test.exs`, and the tests
  that depend on a window not rolling say so where they do.

  The pin merges into whatever is configured (the test budgets of
  `config/test.exs`, and whatever `enable!/1` set), so it may run before or
  after `enable!/1`: `enable!/1` merges its own options over the current
  configuration too, and each restores what it found, in reverse order. Call it
  from the same `setup` as `enable!/1`, or before a test spends anything. A
  window length passed to `enable!/1` after this wins over the pin.
  """
  @spec pin_windows!([:account | :mail | :ip | :registration]) :: :ok
  def pin_windows!(axes) when is_list(axes) and axes != [] do
    window = BudgetWindow.fresh_window_ms(0, db_now_ms())

    axes
    |> Enum.map(&Map.fetch!(@windows, &1))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {module, keys} ->
      original = Application.get_env(:kiln_cms, module, [])
      pinned = Enum.reduce(keys, original, &Keyword.put(&2, &1, window))
      Application.put_env(:kiln_cms, module, pinned)
      ExUnit.Callbacks.on_exit(fn -> Application.put_env(:kiln_cms, module, original) end)
    end)
  end

  # Now, in milliseconds, by the clock `ThrottleStore` computes window indexes
  # with. `clock_timestamp()`, not `now()`: the sandbox holds a transaction
  # open, and `now()` is that transaction's start.
  defp db_now_ms do
    %{rows: [[now]]} =
      KilnCMS.Repo.query!("SELECT (extract(epoch FROM clock_timestamp()) * 1000)::bigint")

    now
  end

  @doc "The OS variable `enable!/1` keeps the secret in."
  @spec secret_var() :: String.t()
  def secret_var, do: @secret_var
end
