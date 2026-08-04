defmodule KilnCMS.Repo.Migrations.FixCommentsAuthorFk do
  @moduledoc """
  Adds the foreign-key constraints `Comment`'s `belongs_to :author`/
  `:resolved_by` (#404) should have gotten in the original `add_comments`
  migration — those relationships were added to the resource after that
  migration had already been generated and run, so `author_id`/
  `resolved_by_id` existed as plain columns with nothing enforcing they
  actually name a `users` row.
  """
  use Ecto.Migration

  def up do
    alter table(:comments) do
      modify :author_id,
             references(:users,
               column: :id,
               name: "comments_author_id_fkey",
               type: :uuid,
               prefix: "public"
             )

      modify :resolved_by_id,
             references(:users,
               column: :id,
               name: "comments_resolved_by_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    create index(:comments, [:org_id, :author_id])
    create index(:comments, [:org_id, :resolved_by_id])
  end

  def down do
    drop_if_exists index(:comments, [:org_id, :resolved_by_id])
    drop_if_exists index(:comments, [:org_id, :author_id])

    drop constraint(:comments, "comments_author_id_fkey")
    drop constraint(:comments, "comments_resolved_by_id_fkey")

    alter table(:comments) do
      modify :resolved_by_id, :uuid
      modify :author_id, :uuid
    end
  end
end
