defmodule KilnCMS.FederationFixtures do
  @moduledoc """
  Test scaffolding for ActivityPub federation (#491).

  Federation is off in `config/test.exs`, matching production — and matching it
  for a reason beyond fidelity: with the deployment switch on, every publish in
  the entire suite enqueues an announcement job, which is a side effect landing
  on tests that have nothing to do with federation.

  So a federation test turns the deployment switch on for its own duration,
  through `enable_deployment!/0`.
  """

  @doc """
  Turn the deployment-wide switch on for this test only, restoring it on exit.
  """
  @spec enable_deployment!() :: :ok
  def enable_deployment! do
    original = Application.get_env(:kiln_cms, KilnCMS.Federation, [])
    Application.put_env(:kiln_cms, KilnCMS.Federation, Keyword.put(original, :enabled, true))

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Federation, original)
    end)

    :ok
  end

  @doc "Enable federation for `org_id`, minting its actor identity."
  @spec enable_site!(Ash.UUID.t(), keyword()) :: struct()
  def enable_site!(org_id, opts \\ []) do
    Ash.create!(
      KilnCMS.Federation.SiteFederation,
      %{
        origin: Keyword.get(opts, :origin, "https://kiln.example"),
        username: Keyword.get(opts, :username, "kiln")
      },
      action: :enable,
      authorize?: false,
      tenant: org_id
    )
  end
end
