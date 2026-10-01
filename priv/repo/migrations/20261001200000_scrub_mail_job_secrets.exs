defmodule KilnCMS.Repo.Migrations.ScrubMailJobSecrets do
  @moduledoc """
  Data migration (#1843): strips the sign-in links releases before 1.0 left in
  `oban_jobs` — adapter-crash errors that quoted the rendered email, and the
  subject and body of finished mail jobs. Touches the `mail` and `newsletter`
  queues only. See `KilnCMS.Mail.Scrub`, which `mix kiln.mail.scrub` also
  runs.

  Hand-written *data* migration — Ash owns the schema, but a scrub can't be
  generated. Expand-safe: no schema change, and a release before 1.0 reads
  neither a finished job's body nor more of an error than it shows. A job
  still waiting to be delivered keeps its message. The table is small (the
  Pruner keeps a week), so it runs here rather than as a job.

  Irreversible by nature; `down/0` does nothing.
  """
  use Ecto.Migration

  def up do
    KilnCMS.Mail.Scrub.run(repo())
  end

  def down, do: :ok
end
