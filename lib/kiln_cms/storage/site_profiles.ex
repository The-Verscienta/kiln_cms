defmodule KilnCMS.Storage.SiteProfiles do
  @moduledoc """
  Which object store a file goes to, or lives in (#1559): a site's own
  (`KilnCMS.CMS.StorageProfile`, set at `/editor/site-storage`) or the
  operator's (`S3_*`, or the Local adapter — `KilnCMS.Storage.adapter/0`).

  Two questions, answered differently on purpose:

    * **Where does a new upload go?** `for_upload/1` — the site's current
      setting. The profile id it returns is recorded on the media row.
    * **Where is this file?** `for_item/1` — the profile the *row* names,
      whatever the site has set since. `nil` on the row is the operator's
      storage, which is every row from before this existed: no backfill.

  ## Precedence (new uploads)

    * The site has a `SiteStorage` row and it is switched on — **the site's
      store**, reached with a config built from its profile alone (below).
    * No row, or the row is switched off — **the operator's storage**, exactly
      as before this existed. That is the site's own choice.

  ## Fail direction

  The row exists but can't be used: the read failed (the pool timed out, or
  the table does not exist yet mid-deploy), the secret can't be decrypted
  (`SECRET_KEY_BASE` was rotated, see `docs/secrets-rotation.md`), or the
  endpoint now resolves somewhere it may not. **All of these refuse** —
  `{:error, reason}`, and the upload fails with a message that says so. They
  never fall back to the operator's storage.

  Falling back looks safe, and it isn't. A site that set its own bucket chose
  where its files live — for jurisdiction, for billing, for who can read them.
  Writing them to the operator's bucket instead puts the site's data on
  infrastructure it chose not to use, and the row would then record the
  operator's store, so the file would stay there even after the site's bucket
  came back. An upload that fails can be retried; a file in the wrong bucket
  has already leaked.

  Reading an item whose profile can't be resolved fails the same way (a 404 or
  a retried job), for the same reason: the operator's bucket does not have the
  file, and asking it would only turn an error into a wrong answer.

  ## No operator key reaches a site's store

  `ExAws.request/2` merges its overrides over the app's `:ex_aws` config, so a
  site config handed to it would inherit whatever the site's config does not
  set: the operator's `security_token`, its endpoint host, or — for a key that
  is merely `nil` — its instance-role credentials. The operator's signed
  request would then go to a host a tenant chose. So `config/1` builds the
  whole map itself, from ExAws's static S3 defaults plus the profile, and
  `KilnCMS.Storage.S3` hands it to `ExAws.Operation.perform/2` directly. Nothing
  here reads `Application.get_env(:ex_aws, …)`.

  ## SSRF

  The endpoint is checked when it is saved (`Validations.StorageEndpoint`) and
  again here, every time a profile is resolved, because DNS can change in
  between. It is resolved once and every request of that operation connects to
  that address (`KilnCMS.Storage.S3.ReqClient`, via `KilnCMS.SafeFetch`'s
  pinning), with SNI and certificate verification pointed back at the name, and
  redirects are not followed.

  `allow_private_hosts: true` (`config :kiln_cms, KilnCMS.Storage.SiteProfiles`)
  lifts the address check for development against a MinIO on localhost. Don't
  set it on a deployment whose site admins you don't trust with your network.
  An operator's own internal store belongs in `S3_ENDPOINT_HOST`, which is not
  checked.
  """

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Storage.Profile
  alias KilnCMS.Webhooks.SafeUrl

  @type error :: :unavailable | :credentials_unreadable | {:host_refused, String.t()}

  @doc """
  Where a new upload for the site `org_id` goes: `{:ok, nil}` for the
  operator's storage, `{:ok, profile}` for the site's own, or `{:error, reason}`
  when the site's own is set but can't be used — see the moduledoc for why that
  refuses the upload.
  """
  @spec for_upload(Ash.UUID.t() | nil) :: {:ok, Profile.t() | nil} | {:error, error()}
  def for_upload(nil), do: {:ok, nil}

  def for_upload(org_id) when is_binary(org_id) do
    case read_settings(org_id) do
      {:ok, nil} -> {:ok, nil}
      {:ok, %{enabled: false}} -> {:ok, nil}
      # Switched on with nothing to switch to cannot be saved; a row in that
      # state was written some other way, and is not a reason to guess.
      {:ok, %{profile_id: nil}} -> refuse(org_id, :unavailable)
      {:ok, %{profile_id: id}} -> org_id |> fetch(id) |> refused(org_id)
      :error -> refuse(org_id, :unavailable)
    end
  end

  # Says which way it failed: refused, not "using the operator's storage".
  defp refused({:ok, _profile} = ok, _org_id), do: ok
  defp refused({:error, reason}, org_id), do: refuse(org_id, reason)

  defp refuse(org_id, reason) do
    Logger.warning(
      "Refusing uploads for site #{org_id}: its own object storage is set but #{describe_error(reason)}"
    )

    {:error, reason}
  end

  @doc """
  Where the file of `item` (anything with `:org_id` and `:storage_profile_id`,
  normally a `MediaItem`) lives: `{:ok, nil}` for the operator's storage,
  `{:ok, profile}`, or `{:error, reason}`.
  """
  @spec for_item(map()) :: {:ok, Profile.t() | nil} | {:error, error()}
  def for_item(%{storage_profile_id: nil}), do: {:ok, nil}

  def for_item(%{storage_profile_id: id, org_id: org_id})
      when is_binary(id) and is_binary(org_id),
      do: fetch(org_id, id)

  # A row read without the column (a narrow `select`) can't say where its file
  # is. Guessing "the operator's" would be the silent wrong answer the
  # moduledoc refuses.
  def for_item(_item), do: {:error, :unavailable}

  @doc "The profile `id` of the site `org_id`, resolved. Tenant-scoped: another site's id is not found."
  @spec fetch(Ash.UUID.t(), Ash.UUID.t()) :: {:ok, Profile.t()} | {:error, error()}
  def fetch(org_id, id) when is_binary(org_id) and is_binary(id) do
    # `authorize?: false` — a system read, and the bypass is safe here: uploads
    # and background jobs resolve storage for an item whose own read was
    # already authorized (or that a worker owns), the read is tenant-scoped to
    # that item's site, and the row never leaves this module except as that
    # site's own connection config.
    case CMS.get_storage_profile(id, tenant: org_id, authorize?: false) do
      {:ok, row} ->
        build(row)

      {:error, error} ->
        unreadable(org_id, "storage profile #{id}: #{message(error)}")
        {:error, :unavailable}
    end
  rescue
    error ->
      unreadable(org_id, Exception.message(error))
      {:error, :unavailable}
  end

  @doc """
  A `StorageProfile` row as a usable `KilnCMS.Storage.Profile`: its secret
  decrypted and its endpoint re-checked and pinned.
  """
  @spec build(CMS.StorageProfile.t()) :: {:ok, Profile.t()} | {:error, error()}
  def build(row) do
    with {:ok, secret} <- secret(row),
         {:ok, endpoint} <- endpoint(row) do
      {:ok,
       %Profile{
         id: row.id,
         org_id: row.org_id,
         bucket: row.bucket,
         private_bucket: row.private_bucket,
         public_base_url: String.trim_trailing(row.public_base_url, "/"),
         config: config(row, secret, endpoint)
       }}
    end
  end

  @doc """
  Whether the stored secret decrypts — for the settings page, which has to say
  when it needs re-entering (the row itself still looks fine).
  """
  @spec secret_readable?(CMS.StorageProfile.t()) :: boolean()
  def secret_readable?(%{secret_access_key_encrypted: encrypted}),
    do: is_binary(encrypted) and match?({:ok, _}, Vault.decrypt(encrypted))

  @doc "A sentence fragment for an `error()`, for logs, upload errors and the settings page."
  @spec describe_error(error()) :: String.t()
  def describe_error(:unavailable), do: "its storage settings could not be read"

  def describe_error(:credentials_unreadable),
    do:
      "its storage secret could not be decrypted (was SECRET_KEY_BASE rotated?) and must be re-entered"

  def describe_error({:host_refused, message}), do: "its storage endpoint was refused: #{message}"

  @doc """
  Writes, reads back and deletes a small test object in the profile's bucket,
  and in its private bucket when it has one — the settings page's "Test"
  button, so a typo in a bucket name or a key without write access shows up
  before the first real upload fails.

  `:ok`, or `{:error, {step, detail}}` where `step` is `:write`, `:read`,
  `:delete` (or `:private_write`, …) and `detail` a short description.
  """
  @spec probe(Profile.t()) :: :ok | {:error, {atom(), String.t()}}
  def probe(%Profile{} = profile) do
    with :ok <- probe_bucket(profile, :public) do
      if profile.private_bucket, do: probe_bucket(profile, :private), else: :ok
    end
  end

  # `tmp` is built here from System.tmp_dir! + a UUID, never user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp probe_bucket(profile, which) do
    key = "kiln-probe/#{Ecto.UUID.generate()}.txt"
    body = "Kiln storage test #{key}"
    tmp = Path.join(System.tmp_dir!(), "kiln-probe-#{Ecto.UUID.generate()}")
    File.write!(tmp, body)
    {store, fetch, delete} = probe_ops(which)

    try do
      with {:write, {:ok, ^key}} <- {:write, store.(key, tmp, profile)},
           {:read, {:ok, ^body}} <- {:read, fetch.(key, profile)},
           {:delete, :ok} <- {:delete, delete.(key, profile)} do
        :ok
      else
        {step, result} -> {:error, {probe_step(step, which), probe_detail(result)}}
      end
    after
      File.rm(tmp)
    end
  end

  defp probe_ops(:public),
    do: {&KilnCMS.Storage.S3.store/3, &KilnCMS.Storage.S3.fetch/2, &KilnCMS.Storage.S3.delete/2}

  defp probe_ops(:private),
    do:
      {&KilnCMS.Storage.S3.store_private/3, &KilnCMS.Storage.S3.fetch_private/2,
       &KilnCMS.Storage.S3.delete_private/2}

  defp probe_step(step, :public), do: step
  defp probe_step(:write, :private), do: :private_write
  defp probe_step(:read, :private), do: :private_read
  defp probe_step(:delete, :private), do: :private_delete

  # The status, never the body: an error body from a store a tenant chose is
  # not something to render back into a page.
  defp probe_detail({:ok, _other}), do: "the file read back was not the file written"
  defp probe_detail({:error, {:http_error, status, _response}}), do: "HTTP #{status}"
  defp probe_detail({:error, reason}) when is_exception(reason), do: Exception.message(reason)
  defp probe_detail({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp probe_detail(_other), do: "no answer"

  @csp_ttl :timer.minutes(5)

  @doc """
  The origins (`https://host[:port]`) the site `org_id`'s own stores serve
  files from — every profile it has had, not just the current one, because
  items uploaded before a move still point at the old bucket's URLs. Added to
  the site's `img-src` and `media-src` by `KilnCMSWeb.Plugs.SiteStorageCsp`;
  without it a browser would refuse to render the site's own images.

  Cached per site (busted when a profile is saved). A read that fails answers
  `[]` for that request — the stock policy, which blocks the site's images
  rather than widening anything — and is not cached.
  """
  @spec csp_origins(Ash.UUID.t() | nil) :: [String.t()]
  def csp_origins(nil), do: []

  def csp_origins(org_id) when is_binary(org_id) do
    KilnCMS.Cache.fetch(KilnCMS.Cache.site_storage_hosts_key(org_id), @csp_ttl, fn ->
      read_origins(org_id)
    end) || []
  end

  # `authorize?: false` — a system read, and the bypass is safe here: it runs
  # for every page of the site, anonymous visitors included, and what leaves
  # this function is only the public origins the site's files are already
  # served from (they are in every `<img src>`), tenant-scoped to that site.
  defp read_origins(org_id) do
    case CMS.list_storage_profiles(tenant: org_id, authorize?: false) do
      {:ok, rows} ->
        rows |> Enum.map(&origin(&1.public_base_url)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      {:error, error} ->
        unreadable(org_id, message(error))
        nil
    end
  rescue
    error ->
      unreadable(org_id, Exception.message(error))
      nil
  end

  # Only a plain DNS name makes it into a policy header: a URI host may carry
  # `;` (a sub-delim), and a `;` in a CSP source list starts a new directive.
  defp origin(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port}} when scheme in ["https", "http"] ->
        if csp_host?(host), do: origin(scheme, host, port)

      _invalid ->
        nil
    end
  end

  defp origin(_url), do: nil

  defp origin(scheme, host, port) do
    default = if scheme == "https", do: 443, else: 80
    if port in [nil, default], do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
  end

  @doc false
  # Whether `host` is a bare DNS name — the only shape of public base URL host
  # that is saved (`Validations.StorageEndpoint`) or put in a CSP header.
  @spec csp_host?(term()) :: boolean()
  def csp_host?(host) when is_binary(host),
    do:
      Regex.match?(~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/i, host)

  def csp_host?(_host), do: false

  @doc false
  # See the moduledoc's SSRF section.
  @spec allow_private_hosts?() :: boolean()
  def allow_private_hosts?,
    do: Application.get_env(:kiln_cms, __MODULE__, [])[:allow_private_hosts] == true

  @doc """
  The host a profile with this `endpoint` (or none, for AWS) and `region`
  connects to, as `{scheme, host, port}` — `:error` when there is none (a
  blank endpoint with a region AWS doesn't have).
  """
  @spec target(String.t() | nil, String.t()) ::
          {:ok, {String.t(), String.t(), pos_integer()}} | :error
  def target(endpoint, region) when endpoint in [nil, ""] do
    case ExAws.Config.Defaults.host(:s3, region) do
      host when is_binary(host) -> {:ok, {"https://", host, 443}}
      _none -> :error
    end
  end

  def target(endpoint, _region) do
    case URI.new(endpoint) do
      {:ok, %URI{scheme: scheme, host: host, port: port}} when is_binary(host) and host != "" ->
        {:ok, {"#{scheme}://", host, port}}

      _invalid ->
        :error
    end
  end

  # The site's `SiteStorage` row, `nil` when it has none, `:error` when it could
  # not be read.
  #
  # `authorize?: false` — a system read, and the bypass is safe here: an upload
  # asks where the site's files go on the uploader's behalf (their create is
  # authorized on its own), the read is tenant-scoped to that one site, and the
  # row never leaves this module except as that site's own profile.
  defp read_settings(org_id) do
    case CMS.list_site_storage(tenant: org_id, authorize?: false) do
      {:ok, [row | _rest]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> unreadable(org_id, message(error))
    end
  rescue
    error -> unreadable(org_id, Exception.message(error))
  end

  defp unreadable(org_id, detail) do
    Logger.error("Storage settings for site #{org_id} could not be read: #{detail}")
    :error
  end

  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)

  defp secret(%{secret_access_key_encrypted: encrypted}) when is_binary(encrypted) do
    case Vault.decrypt(encrypted) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> {:error, :credentials_unreadable}
    end
  end

  defp secret(_row), do: {:error, :credentials_unreadable}

  defp endpoint(row) do
    case target(row.endpoint, row.region) do
      {:ok, {scheme, host, port}} ->
        with {:ok, pinned} <- pin(host), do: {:ok, {scheme, host, port, pinned}}

      :error ->
        {:error, {:host_refused, "no endpoint for region #{row.region}"}}
    end
  end

  defp pin(host) do
    if allow_private_hosts?() do
      {:ok, nil}
    else
      case SafeUrl.resolve_host_pinned(host) do
        {:ok, address} -> {:ok, address}
        {:error, message} -> {:error, {:host_refused, message}}
      end
    end
  end

  # The complete ExAws config for this profile. Built from ExAws's static S3
  # defaults, never from `Application.get_env(:ex_aws, …)`; every credential
  # key is set here (the token explicitly to nil), so nothing that ExAws would
  # otherwise resolve at request time — an env var, an instance role — can
  # stand in for a value the profile does not have. See the moduledoc.
  defp config(row, secret, {scheme, host, port, pinned}) do
    :s3
    |> ExAws.Config.Defaults.get(row.region)
    |> Map.merge(%{
      access_key_id: row.access_key_id,
      secret_access_key: secret,
      security_token: nil,
      region: row.region,
      scheme: scheme,
      host: host,
      port: port,
      http_client: KilnCMS.Storage.S3.ReqClient,
      http_opts: [site_storage: true, pinned_address: pinned],
      # A site's store answering 5xx is retried a little, not the ten times
      # ExAws defaults to: an upload is waiting on it.
      retries: [max_attempts: 3, base_backoff_in_ms: 100, max_backoff_in_ms: 2_000]
    })
  end
end
