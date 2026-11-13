defmodule KilnCMS.Accounts.ApiKeyReuse do
  @moduledoc """
  Reuse detection for self-rotating `:draft_write` keys — the refresh-token
  rule applied to API keys.

  Rotation revokes the presenting key, so after it the only holder who should
  ever present that secret again is nobody. If it **is** presented to the
  rotation endpoint, two parties held it: the service and someone who stole it.
  Whichever rotated first now holds the lineage's live key, and Kiln cannot tell
  which one that is. So the live key of the lineage is revoked as well, and the
  platform admins are mailed. The lineage is dead; a person re-mints.

  Only the rotation endpoint calls this (`KilnCMSWeb.ApiKeyRotationController`),
  not every API route: a service with several workers will have requests in
  flight on the old key while one of them rotates, and those 401s are expected,
  not evidence of theft.

  A presentation within 120 seconds of the rotation is not treated as
  reuse either: that is a retry after a lost response, or two workers rotating
  at once. It still fails (the key is revoked), it just does not burn the
  lineage. A thief who waits that long gains nothing from the grace: they get a
  401 like anyone else.

  The presented secret must **verify** against the revoked row before anything
  happens — knowing a key id is not enough to kill a lineage.

  ## The alert (#2245)

  A detected reuse is a security event, `:api_key_reuse_detected`, and the
  event raises the platform's `api_key_abuse` alert: bell and email to every
  platform admin, which no setting mutes. The event is recorded in the key
  **owner's** site when the owner has exactly one active membership, else in
  the default org — never in the site the request's Host names, which the
  presenter chooses.

  The alert is required (`alert_required: true`): when it cannot be claimed
  the event is not written, and so when the event is not written — refused,
  skipped, or raised — the platform admins get the plain email this module
  sent before alerts existed. A reuse is never left unannounced.
  """
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKey
  alias KilnCMS.Mail
  alias KilnCMS.Security.ApiKeyTrip
  alias KilnCMS.Security.Recorder

  @grace_seconds 120

  @doc "Seconds after a rotation during which re-presenting the old key is not reuse."
  @spec grace_seconds() :: pos_integer()
  def grace_seconds, do: @grace_seconds

  @doc """
  Check a `kiln_…` secret that failed authentication. If it is a genuine,
  rotated-away key presented after the grace period and its lineage still has a
  live key, revoke that key, alert the platform admins and return
  `:reuse_detected`. Otherwise `:ok` — in particular, once a lineage is dead,
  presenting its old keys again alarms nobody, so the alert cannot be replayed
  into a stream of mail.

  `context` is the request's `KilnCMS.Security.Recorder.context/1`: the
  address the reuse came from, for the event. Never raises.
  """
  @spec check(String.t(), map()) :: :ok | :reuse_detected
  def check(plaintext, context \\ %{})

  def check(plaintext, context) when is_binary(plaintext) do
    with {:ok, key_id, token} <- decode(plaintext),
         # authorize?: false — pre-auth lookup of a refused key, no actor exists; the secret is verified next
         {:ok, %ApiKey{} = key} <-
           Accounts.get_api_key(key_id, authorize?: false, load: [:rotated_to, :user]),
         true <- Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), key.api_key_hash),
         %ApiKey{} = successor <- key.rotated_to,
         false <- within_grace?(successor) do
      burn_lineage(key, context || %{})
    else
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning("API key reuse check failed: #{Exception.message(error)}")
      :ok
  end

  def check(_plaintext, _context), do: :ok

  @doc """
  Decode a `kiln_…` secret into `{:ok, key_id, token}`, or `:error`: the
  `kiln_<base62(32 random bytes <> 16-byte id)>_<base62(crc32)>` shape
  `AshAuthentication.Strategy.ApiKey.GenerateApiKey` mints, whose hash is
  `sha256(token)`. Mirrors the strategy's own decoder. Decoding proves
  nothing: the token must still be compared with the key's hash.
  """
  @spec decode(String.t()) :: {:ok, Ash.UUID.t(), binary()} | :error
  def decode(plaintext) when is_binary(plaintext) do
    with [_prefix, middle, crc] <- String.split(plaintext, "_", parts: 3),
         true <- byte_size(middle) <= 65 and byte_size(crc) <= 6,
         {:ok, <<_random::binary-size(32), id::binary-size(16)>> = token} <-
           AshAuthentication.Base.bindecode62(middle),
         true <- AshAuthentication.Base.encode62(:erlang.crc32(token)) == crc,
         {:ok, key_id} <- Ecto.UUID.load(id) do
      {:ok, key_id, token}
    else
      _ -> :error
    end
  end

  def decode(_plaintext), do: :error

  defp within_grace?(successor) do
    DateTime.diff(DateTime.utc_now(), successor.created_at, :second) < @grace_seconds
  end

  defp burn_lineage(key, context) do
    lineage_id = key.lineage_id || key.id

    revoked =
      lineage_id
      # authorize?: false — reuse proven by a verified secret, no actor exists to authorize
      |> Accounts.list_live_api_keys_in_lineage!(authorize?: false)
      |> Enum.map(fn live ->
        # authorize?: false — revoking only narrows access, triggered by verified reuse
        {:ok, _} = Accounts.revoke_api_key(live, authorize?: false)
        live.id
      end)

    if revoked == [] do
      # Already burned (or ended by an admin): nothing to revoke, and a repeat
      # alarm would only be a way to mail every admin on demand.
      Logger.info(
        "Rotated-away API key #{key.id} presented again; lineage #{lineage_id} has no live key."
      )

      :ok
    else
      report_reuse(key, lineage_id, revoked, context)
    end
  end

  defp report_reuse(key, lineage_id, revoked, context) do
    Logger.warning(
      "Rotated-away API key #{key.id} (user #{key.user_id}) was presented again: " <>
        "two parties held it. Revoked the live key(s) of lineage #{lineage_id}: " <>
        "#{inspect(revoked)}. Alerting platform admins."
    )

    :telemetry.execute([:kiln_cms, :api_key, :reuse_detected], %{count: 1}, %{
      key_id: key.id,
      lineage_id: lineage_id,
      user_id: key.user_id,
      revoked_ids: revoked
    })

    case record_reuse(key, revoked, context) do
      {:ok, _event} ->
        :ok

      other ->
        Logger.error(
          "API key reuse event for key #{key.id} not recorded (#{describe(other)}); " <>
            "mailing the platform admins directly."
        )

        alert_admins(key)
    end

    :reuse_detected
  end

  # The event, and with it the required `api_key_abuse` alert. Rescued here
  # rather than by `check/2`'s blanket rescue, so that a failure still falls
  # back to the mail.
  defp record_reuse(key, revoked, context) do
    Recorder.record(:api_key_reuse_detected,
      tenant: ApiKeyTrip.owner_org_id(key),
      user: nil,
      target_type: "api_key",
      target_id: key.id,
      metadata: %{"name" => key.name, "revoked" => length(revoked)},
      request: context[Recorder.context_key()],
      alert_required: true
    )
  rescue
    error -> {:error, error}
  end

  defp describe({:error, %{__exception__: true} = error}), do: inspect(error.__struct__)
  defp describe(other), do: inspect(other)

  defp alert_admins(key) do
    site = KilnCMS.Branding.for_org(nil).site_name
    url = url(~p"/editor/api-keys")
    owner = if match?(%{email: _}, key.user), do: to_string(key.user.email), else: key.user_id

    for admin <- Accounts.Scoping.platform_admins() do
      new()
      |> from(Application.fetch_env!(:kiln_cms, :email_from))
      |> to(to_string(admin.email))
      |> subject("A drafts-only API key on #{site} was used after it was rotated")
      |> html_body("""
      <p>The drafts-only API key <strong>#{escape(key.name)}</strong>
      (acting as #{escape(owner)}) was presented
      for rotation after it had already been rotated. Two parties held the same secret.</p>
      <p>Kiln has revoked every key in that rotation chain, so the service using it has
      stopped authenticating. Find out where the key leaked, then mint a new one:</p>
      <p><a href="#{url}">#{url}</a></p>
      """)
      |> Mail.enqueue!()
    end

    :ok
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
