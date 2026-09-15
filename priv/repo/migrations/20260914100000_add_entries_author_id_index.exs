defmodule KilnCMS.Repo.Migrations.AddEntriesAuthorIdIndex do
  @moduledoc """
  The `author_id` reverse lookup on `entries`, which `pages` and `posts` already
  have (`AddHotPathIndexes`). That migration predates the `entries` table by a
  few hours, so the generic table for admin-defined types never got the index.

  `KilnCMS.Accounts.AccountRemoval` filters every content type by author when
  counting and dispositioning a departing account's documents; without this,
  each dynamic type's page of that sweep is a sequential scan of every entry of
  every dynamic type.
  """
  use Ecto.Migration

  def change do
    create index(:entries, [:author_id], name: "entries_author_id_index")
  end
end
