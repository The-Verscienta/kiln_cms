defmodule KilnCMS.Backups.Destination.Sftp.HostKeyAlert do
  @moduledoc """
  What a changed SFTP host key raises (#2222, ADR 0079): an instance
  security event, `backup_destination_host_key_mismatch`, and the platform
  security alert `backup_host_key_changed` to every platform admin, since a
  key that changed can mean someone is between Kiln and the server.

  At most once per destination per hour, across the cluster: the first call
  to see a mismatch claims it (`KilnCMS.Accounts.ThrottleStore.hit/5` with a
  limit of one, the claim-first shape of `KilnCMS.Security.ScannerGuard`),
  so a step that retries, or a retention pass on another node, doesn't
  write the log full. The alert's own window
  (`KilnCMS.Security.AlertGate`) keeps it to one per 15 minutes on top.

  Best-effort: the destination fails permanently whatever happens here, and
  a failure to record is logged, never raised into the call.

  Unlike every other instance event this one has no person behind it: it is
  the server's act, so it has no actor and no address.
  """

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Backups
  alias KilnCMS.Backups.Redact
  alias KilnCMS.Repo
  alias KilnCMS.Security.{AlertGate, Alerts, Recorder}

  @bucket "backup_host_key_mismatch"
  @every :timer.hours(1)

  @doc "The platform alert kind a changed host key raises."
  @spec kind() :: :backup_host_key_changed
  def kind, do: :backup_host_key_changed

  @doc """
  Records that destination `id`, of `kind`, was offered `offered` while
  trusting `trusted` (fingerprints). `:ok` whether it wrote, was already
  claimed this hour, or failed (logged).
  """
  @spec mismatch(String.t() | nil, String.t(), String.t(), String.t()) :: :ok
  def mismatch(nil, _kind, _offered, _trusted), do: :ok

  def mismatch(id, kind, offered, trusted) when is_binary(id) do
    case ThrottleStore.hit(@bucket, id, @every, 1) do
      {:allow, 1} -> record(id, kind, offered, trusted)
      _claimed -> :ok
    end
  rescue
    error -> failed(error)
  catch
    :exit, reason -> failed(reason)
  end

  defp record(id, kind, offered, trusted) do
    metadata = %{
      "name" => name(id),
      "kind" => kind,
      "offered_fingerprint" => offered,
      "trusted_fingerprint" => trusted
    }

    result =
      Repo.transaction(fn ->
        case Recorder.record(:backup_destination_host_key_mismatch,
               scope: :instance,
               user: nil,
               target_type: "backup_destination",
               target_id: id,
               metadata: metadata
             ) do
          {:ok, event} ->
            alert(metadata["name"])
            event

          {:error, error} ->
            Repo.rollback(error)

          :skipped ->
            Repo.rollback(:skipped)
        end
      end)

    case result do
      {:ok, _event} -> :ok
      {:error, error} -> failed(error)
    end
  end

  # In the event's transaction, as `KilnCMS.Security.Changes.RaiseAlert`
  # claims one: a rolled-back event leaves no alert. The event lives in the
  # instance log, which an alert's delivery doesn't read, so none is named;
  # the destination's name rides on the claim instead, and the alert links
  # to the instance log.
  defp alert(name) do
    if Alerts.enabled?() do
      AlertGate.claim("platform", kind(), :platform, Accounts.default_org_id(), nil,
        details: if(is_binary(name), do: %{"destination" => Redact.text(name)}, else: %{})
      )
    end

    :ok
  end

  # The name the admin gave it, read as the pipeline's own actor.
  defp name(id) do
    case Backups.get_backup_destination(id, actor: Backups.system(), authorize_with: :error) do
      {:ok, %{name: name}} -> name
      _gone_or_refused -> nil
    end
  end

  defp failed(error) do
    Logger.error(
      "Backups: an SFTP host key mismatch was not recorded (#{inspect(error_kind(error))})"
    )

    :ok
  end

  defp error_kind(%{__struct__: module}), do: module
  defp error_kind(other), do: other
end
