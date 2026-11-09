defmodule KilnCMS.Security.Posture.Checks.HumanVerification do
  @moduledoc """
  `core.human_verification` (#2252): whether sign-in and registration can ask
  for a human-verification challenge (`KilnCMS.Challenge`, #2249). Reads
  `KilnCMS.Challenge.config/0`, the configuration the gate itself uses: a
  usable provider with a mode that is not off passes; a usable provider with
  both sign-in and registration `:off`, no provider, an unusable one (an
  unknown id, a missing key), or the kill switch (`KILN_CHALLENGE_DISABLED`)
  warns.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Challenge
  alias KilnCMS.Security.Posture

  @impl Kiln.Security.Check
  def id, do: "core.human_verification"

  @impl Kiln.Security.Check
  def title, do: gettext("Human verification")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "A challenge on suspicious sign-ins and registrations slows down password guessing and fake sign-ups."
      )

  @impl Kiln.Security.Check
  def scope, do: :deployment

  @impl Kiln.Security.Check
  def run(_context) do
    config = Challenge.config()
    settings = Application.get_env(:kiln_cms, Challenge, [])
    opts = [docs_url: Posture.docs_url("human-verification")]

    cond do
      Challenge.enabled?(config) ->
        pass(
          gettext("Suspicious sign-ins and registrations are asked to prove they're human."),
          Keyword.put(opts, :facts, %{
            provider: config.descriptor.id,
            sign_in: Atom.to_string(config.sign_in),
            registration: Atom.to_string(config.registration)
          })
        )

      # Usable, but both modes are `:off`: nothing ever asks for a challenge.
      config.provider != nil ->
        warn(
          gettext(
            "A human-verification provider is set up, but switched off for both sign-in and registration."
          ),
          Keyword.put(opts, :facts, %{
            provider: config.descriptor.id,
            sign_in: Atom.to_string(config.sign_in),
            registration: Atom.to_string(config.registration)
          })
        )

      settings[:disabled] == true ->
        warn(
          gettext("Human verification is turned off (KILN_CHALLENGE_DISABLED)."),
          Keyword.put(opts, :facts, %{provider: nil, kill_switch: true})
        )

      settings[:provider] not in [nil, ""] and is_nil(config.provider) ->
        warn(
          gettext(
            "A human-verification provider is named but can't be used (check its id and keys)."
          ),
          Keyword.put(opts, :facts, %{provider: nil, kill_switch: false})
        )

      true ->
        warn(
          gettext("No human-verification provider is set up (CHALLENGE_PROVIDER)."),
          Keyword.put(opts, :facts, %{provider: nil, kill_switch: false})
        )
    end
  end
end
