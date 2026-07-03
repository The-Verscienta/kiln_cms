defmodule KilnCMS.Repo.Migrations.AddCollabDocStates do
  @moduledoc """
  Durability for the collab CRDT prototype: each open document's authoritative
  Yjs state, persisted by `KilnCMS.Collab.Crdt.DocServer` (checkpoints while
  dirty + on shutdown) and restored when a document is next opened — so a
  deploy or restart mid-session doesn't reset live collaborative docs.

  One row per document topic; `state` is the compacted Yjs binary. Rows unused
  for 30 days are pruned opportunistically on restore.
  """
  use Ecto.Migration

  def change do
    create table(:collab_doc_states, primary_key: false) do
      add :doc_key, :text, primary_key: true
      add :state, :binary, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # The prune scans by age.
    create index(:collab_doc_states, [:updated_at])
  end
end
