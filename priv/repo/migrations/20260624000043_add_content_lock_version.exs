defmodule KilnCMS.Repo.Migrations.AddContentLockVersion do
  @moduledoc """
  Adds the optimistic-concurrency `lock_version` counter to pages/posts.
  (The `published_version_id` column an earlier hand migration already added is
  intentionally not re-added here.)
  """

  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :lock_version, :bigint, null: false, default: 1
    end

    alter table(:pages) do
      add :lock_version, :bigint, null: false, default: 1
    end
  end

  def down do
    alter table(:pages) do
      remove :lock_version
    end

    alter table(:posts) do
      remove :lock_version
    end
  end
end
