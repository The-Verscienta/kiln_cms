defmodule Mix.Tasks.Kiln.Federation do
  @shortdoc "Turn a site's ActivityPub actor on or off, and show its handle"
  @moduledoc """
  Manage a site's fediverse identity (#491).

      mix kiln.federation status  [--org-id UUID]
      mix kiln.federation enable  [--org-id UUID] [--username NAME] [--origin URL]
      mix kiln.federation disable [--org-id UUID]
      mix kiln.federation rekey   [--org-id UUID]

  Phase 1 has no admin screen — follower management and the settings UI are
  phase 2 — so this is how an operator turns federation on. It is deliberately
  a task rather than a checkbox for now: enabling federation mints a permanent
  actor identity, and doing that from a CLI where the resulting handle is
  printed and can be copied is clearer than a toggle whose consequences are
  invisible.

  `enable` needs `KILN_FEDERATION_ENABLED=true` to have any effect: the site row
  is only half the gate, and a site enabled under a deployment that forbids
  federation still 404s. The task says so rather than letting an operator
  believe they are federating when they are not.

  ## The origin is permanent

  `--origin` defaults to the site's configured base URL and is captured **once**.
  An actor id is its permanent name in the fediverse — remote servers store it,
  deduplicate on it, and deliver to it — so re-enabling never changes it. Moving
  a federating site to a new domain is a migration, not a settings edit.

  ## Re-keying (#1487)

  `rekey` replaces the actor's signing keypair and keeps everything else: the
  handle, the actor id and the `keyId`. Followers are sent an actor `Update`
  carrying the new public key. Servers that process actor updates switch
  straight away. Others keep the old key until a delivery fails to verify and
  they re-fetch the actor, and some may never do so. Re-key when the key is
  unreadable (`status` says so) or has leaked, not as routine hygiene.
  """
  use Mix.Task

  alias KilnCMS.Federation
  alias KilnCMS.Federation.Actor
  alias KilnCMS.Federation.SiteFederation

  @requirements ["app.start"]

  @switches [org_id: :string, username: :string, origin: :string]

  @impl Mix.Task
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    org_id = opts[:org_id] || KilnCMS.Accounts.default_org_id()

    case positional do
      ["status"] ->
        status(org_id)

      ["enable"] ->
        enable(org_id, opts)

      ["disable"] ->
        disable(org_id)

      ["rekey"] ->
        rekey(org_id)

      _other ->
        Mix.raise("Usage: mix kiln.federation status|enable|disable|rekey [--org-id UUID]")
    end
  end

  defp status(org_id) do
    Mix.shell().info(deployment_line())

    case settings(org_id) do
      nil ->
        Mix.shell().info("Site:       not configured (never enabled)")

      settings ->
        identity = identity_or_nil(settings)

        Mix.shell().info("Site:       #{if settings.enabled, do: "enabled", else: "disabled"}")

        if identity do
          Mix.shell().info("Handle:     #{identity.handle}")
          Mix.shell().info("Actor:      #{identity.actor_id}")
          Mix.shell().info("Followers:  #{follower_count(org_id)}")
          Mix.shell().info("Key:        #{key_line(settings)}")
        end
    end
  end

  defp enable(org_id, opts) do
    origin = opts[:origin] || KilnCMSWeb.Tenant.base_url(org_id)
    username = opts[:username] || default_username(org_id)

    settings =
      Ash.create!(
        SiteFederation,
        %{origin: origin, username: username},
        action: :enable,
        authorize?: false,
        tenant: org_id
      )

    identity = Actor.identity(settings)

    Mix.shell().info("Federation enabled for this site.")
    Mix.shell().info("Handle: #{identity.handle}")
    Mix.shell().info("Actor:  #{identity.actor_id}")

    unless Federation.enabled?() do
      Mix.shell().info("")

      Mix.shell().error(
        "KILN_FEDERATION_ENABLED is not set, so every federation route still " <>
          "404s. Set it and restart before announcing this handle."
      )
    end
  end

  defp disable(org_id) do
    case settings(org_id) do
      nil ->
        Mix.shell().info("Federation was never enabled for this site; nothing to do.")

      settings ->
        Ash.update!(settings, %{}, action: :disable, authorize?: false, tenant: org_id)

        # The identity survives on purpose — see the resource's moduledoc.
        Mix.shell().info(
          "Federation disabled. The actor identity is kept, so re-enabling " <>
            "restores the same handle and key for existing followers."
        )
    end
  end

  defp rekey(org_id) do
    case settings(org_id) do
      nil ->
        Mix.raise("Federation was never enabled for this site; there is no key to replace.")

      settings ->
        # `authorize?: false`: an operator at a shell on the host is the
        # deployment's own authority, above any org role — the same bypass
        # `enable` and `disable` take.
        case Ash.update(settings, %{}, action: :rekey, authorize?: false, tenant: org_id) do
          {:ok, _settings} ->
            Mix.shell().info(
              "Re-keyed. The handle, actor id and keyId are unchanged; the signing key is new."
            )

            Mix.shell().info(
              "An actor Update is queued for #{follower_count(org_id)} follower(s). Some " <>
                "remote servers may keep the old key until a delivery fails and they " <>
                "re-fetch the actor."
            )

          {:error, error} ->
            Mix.raise("Could not re-key: #{Exception.message(error)}")
        end
    end
  end

  # A key the vault cannot open is the one federation fault nothing else shows:
  # the site looks enabled and every delivery quietly fails.
  defp key_line(settings) do
    if SiteFederation.private_key_pem(settings),
      do: "readable",
      else: "UNREADABLE — deliveries fail. See docs/secrets-rotation.md, or re-key"
  end

  defp deployment_line do
    if Federation.enabled?(),
      do: "Deployment: enabled (KILN_FEDERATION_ENABLED)",
      else: "Deployment: DISABLED — every federation route 404s"
  end

  defp settings(org_id) do
    case Ash.read(SiteFederation, authorize?: false, tenant: org_id) do
      {:ok, [settings]} -> settings
      _other -> nil
    end
  end

  defp identity_or_nil(%{origin: origin, username: username} = settings)
       when is_binary(origin) and is_binary(username),
       do: Actor.identity(settings)

  defp identity_or_nil(_settings), do: nil

  defp follower_count(org_id) do
    Ash.count!(KilnCMS.Federation.Follower, authorize?: false, tenant: org_id)
  end

  # The org's slug is the natural handle — it is already the subdomain label,
  # so `@acme@acme.example.com` reads the way an operator expects.
  defp default_username(org_id) do
    case KilnCMS.Accounts.get_organization(org_id, authorize?: false) do
      {:ok, %{slug: slug}} when is_binary(slug) -> slug
      _other -> "site"
    end
  end
end
