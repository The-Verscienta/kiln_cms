defmodule KilnCMS.ChallengeFixtures do
  @moduledoc """
  Test scaffolding for human verification (#2249).

  No provider is configured in `config/test.exs`, so nothing is ever required.
  `enable!/1` turns it on for one test with `KilnCMS.ChallengeFake`, sets a
  secret, and restores everything on exit. Tests that use it are
  `async: false`: the configuration lives in application env and the secret in
  the OS environment, both node-wide.
  """

  @secret_var "KILN_TEST_CHALLENGE_SECRET"

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

  @doc "The OS variable `enable!/1` keeps the secret in."
  @spec secret_var() :: String.t()
  def secret_var, do: @secret_var
end
