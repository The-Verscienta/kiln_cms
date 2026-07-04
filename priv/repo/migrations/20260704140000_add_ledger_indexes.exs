defmodule KilnCMS.Repo.Migrations.AddLedgerIndexes do
  @moduledoc """
  Indexes for two append-only ledgers whose reads/prunes were seq-scanning
  (July 2026 consolidation audit):

    * `webhook_deliveries.inserted_at` — the nightly retention prune
      (`inserted_at <= ago(30, :day)`) and the admin "recent deliveries" read
      (`sort inserted_at desc limit 25`) both scan it;
    * `form_submissions (form_id, inserted_at desc)` — the per-form
      submissions viewer (`recent_for_form`: filter form_id, sort
      inserted_at desc) and the `submission_count` aggregate. Postgres does
      not index foreign keys automatically.
  """
  use Ecto.Migration

  def change do
    create index(:webhook_deliveries, [:inserted_at])
    create index(:form_submissions, [:form_id, "inserted_at DESC"])
  end
end
