defmodule Mix.Tasks.Kiln.Vapid.Gen do
  @shortdoc "Generate a VAPID key pair for web push notifications"

  @moduledoc """
  Generates the P-256 key pair Web Push identifies this deployment with (#628),
  and prints it as the environment variables `config/runtime.exs` reads.

      mix kiln.vapid.gen

  The output format is the one `npx web-push generate-vapid-keys` produces —
  base64url, unpadded, an uncompressed 65-byte point and a 32-byte scalar — so
  a deployment that already has a pair from that tool can keep it. This task
  exists so a deployment does not need Node on the path to turn push on.

  ## Rotating is not free

  A browser stores the public key inside the subscription it creates, and a
  push service checks the JWT signature against *that* key. Change the pair and
  every existing subscription stops accepting messages — the push service
  answers `403`, and `KilnCMS.Push` prunes the row, so a reviewer silently stops
  getting notifications until they re-enable them in `/editor/settings`.

  So: generate once per deployment, keep the private key with the rest of the
  secrets, and rotate only for the reason you would rotate any signing key.

  ## The private key is a secret

  It is printed to stdout because that is the only way to hand it to you, but
  it belongs in the secret store, not in shell history or a committed `.env`.
  Anyone holding it can push a notification to every subscriber of this
  deployment.
  """

  use Mix.Task

  alias KilnCMS.Push.Vapid

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    {public, private} = Vapid.generate()

    Mix.shell().info("""

    VAPID key pair generated. Set these on the deployment:

      KILN_VAPID_PUBLIC_KEY=#{public}
      KILN_VAPID_PRIVATE_KEY=#{private}
      KILN_VAPID_SUBJECT=mailto:you@example.com

    KILN_VAPID_SUBJECT must be a contactable mailto: or https: URL — RFC 8292
    asks for one so a push service operator can reach whoever is sending. It
    defaults to this deployment's public base URL if you leave it unset.

    Keep the private key with your other secrets. Rotating the pair invalidates
    every existing subscription: reviewers stop receiving notifications until
    they re-enable them in /editor/settings.
    """)
  end
end
