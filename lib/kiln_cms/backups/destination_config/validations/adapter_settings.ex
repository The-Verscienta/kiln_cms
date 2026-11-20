defmodule KilnCMS.Backups.DestinationConfig.Validations.AdapterSettings do
  @moduledoc """
  Whether a `KilnCMS.Backups.DestinationConfig` may be saved as it stands
  (#2220), checked in this order, the first refusal winning:

    1. its `kind` is an installed adapter (`KilnCMS.Backups.Destination.adapter/1`);
    2. `settings` holds only the adapter's declared non-secret fields, each
       of its declared type: never a secret field, and never anything else
       (the env destination's `"remote"` included, which only
       `BACKUP_RCLONE_REMOTE` may set);
    3. the `:secrets` argument names only the adapter's `:secret` fields,
       each a string;
    4. on update, where it writes is unchanged (critic change 2): moving a
       destination is adding a new one;
    5. the stored secrets can be decrypted, unless new ones replace them;
    6. every required field is there, secrets included;
    7. at most `DestinationConfig.max_enabled/0` destinations are enabled
       (decision E8), counted again under a lock inside the transaction
       (`Changes.EnabledCap`, #2952);
    8. on create, it neither is, contains nor sits inside the env remote or
       another destination (`Destination.overlap?/2`);
    9. the adapter's own `validate/1` accepts it, run through
       `Destination.call/4` (bounded, isolated, its error scrubbed of the
       secrets);
   10. for an S3 destination (#2221), its endpoint resolves only to
       addresses it may reach (`KilnCMS.Backups.Destination.S3.Endpoint.pin/2`),
       and for an SFTP destination (#2222) its host does
       (`KilnCMS.Backups.Destination.Sftp.Target.pin/2`): `validate/1` stays
       offline, as the contract asks, so the DNS check is the core's, here,
       and again before every call.

  Before any of them, an SFTP destination is refused as enabled while no
  host key is trusted for it (#2222, ADR 0079): it is saved disabled, and
  enabled once a platform admin has confirmed the server's key.

  An update that changes neither the settings nor the secrets, and does not
  enable the destination, is not checked: a destination whose plugin was
  removed can still be renamed, reordered or disabled.

  The other rows are read as the `:backups` system actor with
  `authorize_with: :error`, so a refused or failed read refuses the save
  rather than passing the cap or the overlap check on an empty list.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Destination, DestinationConfig}
  alias KilnCMS.Backups.Destination.{S3, Sftp}
  alias KilnCMS.Backups.DestinationConfig.Changes.{EnabledCap, StoreSecrets}
  alias KilnCMS.Backups.DestinationConfig.Fields

  # A Save waits for the adapter's `validate/1` this long at most.
  @validate_timeout :timer.seconds(30)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if checked?(changeset), do: check(changeset), else: :ok
  end

  defp checked?(%{action_type: :create}), do: true

  defp checked?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :settings) or
      StoreSecrets.given(changeset) != %{} or enabling?(changeset)
  end

  defp enabling?(changeset), do: EnabledCap.enabling?(changeset)

  defp check(changeset) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)
    settings = Ash.Changeset.get_attribute(changeset, :settings) || %{}

    with {:ok, module} <- installed(kind),
         :ok <- host_key_first(changeset, kind),
         {:ok, fields} <- fields(module),
         :ok <- known_settings(settings, fields),
         :ok <- known_secrets(changeset, fields),
         config = %Config{id: changeset.data.id, kind: kind, settings: settings},
         :ok <- same_location(changeset, config),
         {:ok, config} <- with_secrets(changeset, config),
         :ok <- required(config, fields),
         :ok <- cap(changeset),
         :ok <- no_overlap(changeset, config),
         :ok <- adapter_valid(config) do
      reachable(config)
    end
  end

  # Refused before anything is contacted: enabling is what sends backups.
  defp host_key_first(changeset, "sftp") do
    enabled? = Ash.Changeset.get_attribute(changeset, :enabled) == true
    trusted? = is_map(Ash.Changeset.get_attribute(changeset, :host_key))

    if enabled? and not trusted?,
      do:
        error(
          :enabled,
          dgettext_noop(
            "errors",
            "an SFTP destination stays disabled until its host key is confirmed"
          ),
          []
        ),
      else: :ok
  end

  defp host_key_first(_changeset, _kind), do: :ok

  defp installed(kind) do
    case Destination.adapter(kind) do
      {:ok, module} ->
        {:ok, module}

      {:error, :not_installed} ->
        error(
          :kind,
          dgettext_noop(
            "errors",
            "no installed backup destination has this kind (was its plugin removed?)"
          ),
          []
        )
    end
  end

  defp fields(module) do
    case Fields.of(module) do
      {:ok, fields} -> {:ok, fields}
      {:error, message} -> error(:kind, message, [])
    end
  end

  defp known_settings(settings, fields) when is_map(settings) do
    types = Map.new(Fields.settings(fields), &{&1.name, &1.type})
    secret = Fields.secret_names(fields)

    Enum.find_value(settings, :ok, fn {name, value} ->
      name = to_string(name)

      cond do
        name in secret ->
          error(:settings, dgettext_noop("errors", "%{name} is a secret and can't be a setting"),
            name: name
          )

        not Map.has_key?(types, name) ->
          error(:settings, dgettext_noop("errors", "%{name} is not a setting of this kind"),
            name: name
          )

        not typed?(value, Map.fetch!(types, name)) ->
          error(:settings, dgettext_noop("errors", "%{name} has the wrong type"), name: name)

        true ->
          nil
      end
    end)
  end

  defp known_settings(_settings, _fields),
    do: error(:settings, dgettext_noop("errors", "must be a map of fields"), [])

  defp typed?(value, :string), do: is_binary(value)
  defp typed?(value, :boolean), do: is_boolean(value)
  defp typed?(value, :integer), do: is_integer(value)

  defp known_secrets(changeset, fields) do
    secret = Fields.secret_names(fields)

    case Ash.Changeset.get_argument(changeset, :secrets) do
      nil ->
        :ok

      secrets when is_map(secrets) ->
        Enum.find_value(secrets, :ok, &secret_refusal(&1, secret))

      _other ->
        error(:secrets, dgettext_noop("errors", "must be a map of fields"), [])
    end
  end

  defp secret_refusal({name, value}, secret) do
    name = to_string(name)

    cond do
      name not in secret ->
        error(:secrets, dgettext_noop("errors", "%{name} is not a secret of this kind"),
          name: name
        )

      not (is_binary(value) or is_nil(value)) ->
        error(:secrets, dgettext_noop("errors", "%{name} must be text"), name: name)

      true ->
        nil
    end
  end

  # Kiln's own adapters know where they write; a plugin's settings mean
  # nothing here (`:unknown`), so its location can't be pinned.
  defp same_location(%{action_type: :update} = changeset, config) do
    before = %Config{kind: changeset.data.kind, settings: changeset.data.settings || %{}}

    if Destination.location(before) == Destination.location(config),
      do: :ok,
      else:
        error(
          :settings,
          dgettext_noop(
            "errors",
            "where a destination writes can't be changed; add a new destination instead"
          ),
          []
        )
  end

  defp same_location(_create, _config), do: :ok

  # The secrets as they will be stored: `Changes.StoreSecrets` ran first.
  defp with_secrets(changeset, config) do
    case changeset
         |> Ash.Changeset.get_attribute(:secrets_encrypted)
         |> DestinationConfig.decrypt_secrets() do
      {:ok, secrets} ->
        {:ok, %{config | secrets: secrets}}

      {:error, :undecryptable} ->
        error(
          :secrets,
          dgettext_noop(
            "errors",
            "the stored credentials can't be decrypted (was SECRET_KEY_BASE changed?); enter them again"
          ),
          []
        )
    end
  end

  defp required(config, fields) do
    Enum.find_value(fields, :ok, fn
      %{required?: true, type: :secret, name: name} ->
        if blank?(Map.get(config.secrets, name)),
          do: error(:secrets, dgettext_noop("errors", "%{name} is required"), name: name)

      %{required?: true, name: name} ->
        if blank?(Map.get(config.settings, name)),
          do: error(:settings, dgettext_noop("errors", "%{name} is required"), name: name)

      _optional ->
        nil
    end)
  end

  defp blank?(value), do: value in [nil, ""]

  # Counted again inside the transaction, under a lock (`Changes.EnabledCap`):
  # this early count spares an over-the-cap save the adapter's `validate/1`.
  defp cap(changeset), do: EnabledCap.check(changeset)

  defp no_overlap(%{action_type: :create}, config) do
    case Destination.location(config) do
      :unknown ->
        :ok

      location ->
        with {:ok, taken} <- taken_locations(), do: clear_of(location, taken)
    end
  end

  defp no_overlap(_update, _config), do: :ok

  defp clear_of(location, taken) do
    if Enum.any?(taken, &Destination.overlap?(location, &1)),
      do:
        error(
          :settings,
          dgettext_noop(
            "errors",
            "this is, contains or is inside another destination; choose a place of its own"
          ),
          []
        ),
      else: :ok
  end

  # Where the env remote and every stored destination write. Settings are
  # enough for `Destination.location/1`: no secret is decrypted here.
  defp taken_locations do
    case Backups.list_backup_destinations(actor: Backups.system(), authorize_with: :error) do
      {:ok, rows} ->
        stored =
          Enum.map(rows, &Destination.location(%Config{kind: &1.kind, settings: &1.settings}))

        {:ok, env_location() ++ stored}

      {:error, _error} ->
        unreadable()
    end
  end

  defp env_location do
    with %{} = entry <- Destination.env_destination(),
         {:ok, config} <- Destination.resolve(entry) do
      [Destination.location(config)]
    else
      _ -> []
    end
  end

  defp adapter_valid(config) do
    case Destination.call(config, :validate, [], timeout: @validate_timeout) do
      :ok -> :ok
      {:error, reason} -> error(:settings, Destination.format_reason(reason), [])
      _other -> :ok
    end
  end

  defp reachable(%Config{kind: "s3", settings: settings}) do
    with {:ok, endpoint} <- S3.Endpoint.parse(settings),
         {:ok, _address} <- S3.Endpoint.pin(endpoint) do
      :ok
    else
      {:error, reason} -> error(:settings, Destination.format_reason(reason), [])
    end
  end

  defp reachable(%Config{kind: "sftp", settings: settings}) do
    with {:ok, target} <- Sftp.Target.parse(settings),
         {:ok, _address} <- Sftp.Target.pin(target) do
      :ok
    else
      {:error, reason} -> error(:settings, Destination.format_reason(reason), [])
    end
  end

  defp reachable(_config), do: :ok

  defp unreadable do
    error(
      :settings,
      dgettext_noop("errors", "the other backup destinations couldn't be read; try again"),
      []
    )
  end

  defp error(field, message, vars),
    do: {:error, InvalidAttribute.exception(field: field, message: message, vars: vars)}
end
