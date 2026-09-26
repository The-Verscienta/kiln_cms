defmodule KilnCMS.Media.StagedUploadCleanup do
  @moduledoc """
  Deletes a direct upload's staging object once its token has expired
  (`KilnCMS.Media.DirectUpload`).

  Queued when the upload URL is issued, scheduled past the token's lifetime.
  A completed upload already deleted its staging object, and a private delete
  of a missing key succeeds, so the job does not need to know which case it is
  in. What it exists for is the upload that is PUT and never completed —
  otherwise an unsniffed file that nothing references would sit in the
  private bucket indefinitely, billed and invisible.

  A lifecycle rule on the bucket's `direct-uploads/` prefix is a sensible
  backstop for a job lost with its node (docs/media-pipeline.md), but this
  is the mechanism, not the rule.
  """
  use Oban.Worker, queue: :media, max_attempts: 5

  require Logger

  @doc """
  Queue the delete of `key` to run `in_seconds` from now, in the store it was
  staged into: the operator's (`profile_id` nil) or the site `org_id`'s own
  (#1559).
  """
  @spec schedule(String.t(), pos_integer(), Ash.UUID.t() | nil, Ash.UUID.t() | nil) :: :ok
  def schedule(key, in_seconds, org_id \\ nil, profile_id \\ nil) do
    args = %{key: key, org_id: org_id, profile_id: profile_id}

    case args |> new(schedule_in: in_seconds) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Direct upload #{key}: staging cleanup was not queued (#{inspect(reason)}); " <>
            "an uncompleted upload will stay in the private bucket."
        )

        :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"key" => "direct-uploads/" <> _ = key} = args}) do
    case KilnCMS.Storage.delete_private(key, store(args)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Only ever the staging prefix: a job argument is data in a table, and a job
  # that could be pointed at any private key would be a delete primitive for
  # gated documents.
  def perform(%Oban.Job{args: args}) do
    Logger.error("StagedUploadCleanup refused a non-staging key: #{inspect(args)}")
    {:cancel, :not_a_staging_key}
  end

  # Jobs queued before #1559 carry no profile: the operator's store. A site
  # profile is read tenant-scoped to the job's own site, so a job row pointed
  # at another site's profile finds nothing and deletes nothing there.
  defp store(%{"profile_id" => profile_id, "org_id" => org_id})
       when is_binary(profile_id) and is_binary(org_id),
       do: %{storage_profile_id: profile_id, org_id: org_id}

  defp store(_args), do: nil
end
