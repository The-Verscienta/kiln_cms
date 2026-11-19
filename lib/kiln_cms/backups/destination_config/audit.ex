defmodule KilnCMS.Backups.DestinationConfig.Audit do
  @moduledoc """
  The instance security log entries of a `KilnCMS.Backups.DestinationConfig`
  create, update, destroy, Test (#2220) and adopted backup directories: their target, metadata and, for a
  Test, who pressed it. Each type's keys are in
  `KilnCMS.Security.InstanceEvent`'s allowlist.

  **Never a setting's value or a secret.** A change names the fields that
  changed (`"settings"`, not what they hold) and whether new secrets were
  given (`secrets_changed`); the name and kind identify the destination. A
  path or remote name could say more about the instance's storage than the
  log's readers need, and a secret must never leave the vault column.
  """

  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups.DestinationConfig.Changes.StoreSecrets

  @compared [:name, :enabled, :position, :settings, :prune]

  @doc false
  def target(record, _changeset), do: {"backup_destination", record.id}

  @doc false
  def created(record, changeset) do
    %{
      "name" => record.name,
      "kind" => record.kind,
      "enabled" => record.enabled,
      "prune" => record.prune,
      "secrets_changed" => secrets_changed?(changeset)
    }
  end

  @doc false
  def changed(record, changeset) do
    %{
      "changed" => record |> changed_fields(changeset) |> Enum.join(","),
      "name" => record.name,
      "kind" => record.kind,
      "enabled" => record.enabled,
      "prune" => record.prune,
      "secrets_changed" => secrets_changed?(changeset)
    }
  end

  @doc false
  def changed?(record, changeset), do: changed_fields(record, changeset) != []

  @doc false
  # The backup-directory ids adopted (or bound afresh) and no longer adopted
  # (`Changes.Adopt`), comma-joined, or "none".
  def adoptions(record, changeset) do
    changes = adoption_changes(changeset)

    %{
      "name" => record.name,
      "kind" => record.kind,
      "adopted" => joined(changes.adopted),
      "removed" => joined(changes.removed)
    }
  end

  @doc false
  def adoptions_changed?(_record, changeset) do
    changes = adoption_changes(changeset)
    changes.adopted != [] or changes.removed != []
  end

  defp adoption_changes(changeset),
    do: changeset.context[:adoption_changes] || %{adopted: [], removed: []}

  defp joined([]), do: "none"
  defp joined(ids), do: Enum.join(ids, ",")

  @doc false
  def deleted(record, _changeset) do
    %{"name" => record.name, "kind" => record.kind, "enabled" => record.enabled}
  end

  @doc false
  def tested(record, _changeset) do
    %{
      "name" => record.name,
      "kind" => record.kind,
      "ok" => record.last_test_ok,
      "node" => record.last_test_node
    }
  end

  @doc false
  # The platform admin `KilnCMS.Backups.test_destination/2` read the row as;
  # the write itself is the system actor's.
  def tested_by(_record, changeset) do
    case changeset.context[:tested_by] do
      %User{} = user -> user
      _other -> nil
    end
  end

  defp changed_fields(record, changeset) do
    before = changeset.data

    fields =
      for field <- @compared,
          Map.get(record, field) != Map.get(before, field),
          do: Atom.to_string(field)

    if secrets_changed?(changeset), do: fields ++ ["secrets"], else: fields
  end

  defp secrets_changed?(changeset), do: StoreSecrets.given(changeset) != %{}
end
