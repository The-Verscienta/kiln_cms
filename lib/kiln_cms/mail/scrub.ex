defmodule KilnCMS.Mail.Scrub do
  @moduledoc """
  Removes sign-in links that releases before 1.0 left in `oban_jobs` (#1843).

  Two things, both only on the `mail` and `newsletter` queues — no other
  queue's rows are read or written:

    * **Job errors.** An adapter that crashed (the stock local adapter in a
      release with no mail server configured) had its whole exit recorded as
      the job's error, and that quotes the rendered `%Swoosh.Email{}`: the
      password reset link, the magic link, the account or newsletter
      confirmation link. Every stored error that quotes an email or holds a URL
      is replaced by `KilnCMS.Mail.display_error/1`'s safe first line.
    * **Finished jobs' messages.** A completed, cancelled or discarded job no
      longer needs its subject and body, and drops them, as
      `KilnCMS.Mail.forget_body/1` now does when a job finishes. A job still
      waiting to be delivered keeps its message, so it can still go out.

  Idempotent: what it writes holds no URL and no email, so a second run finds
  nothing. Runs once on upgrade, from the
  `20261001200000_scrub_mail_job_secrets` data migration; `mix
  kiln.mail.scrub` (or `KilnCMS.Release.scrub_mail_jobs/0` in a release) runs
  it again, for instance after restoring a backup taken before the upgrade.
  """
  import Ecto.Query

  alias KilnCMS.Mail

  @queues ~w(mail newsletter)
  @finished ~w(completed cancelled discarded)
  @batch 500

  # An error worth rewriting: one that quotes a rendered email or holds a URL.
  @unsafe ~r/%Swoosh\.Email\{|html_body|text_body|\b[a-z][a-z0-9+.\-]*:\/\/\S/i

  @typedoc "How many rows each step changed."
  @type result :: %{bodies_dropped: non_neg_integer(), errors_redacted: non_neg_integer()}

  @doc "Scrub every mail and newsletter job through `repo`; see the moduledoc."
  @spec run(Ecto.Repo.t()) :: result()
  def run(repo \\ KilnCMS.Repo) do
    %{bodies_dropped: drop_finished_bodies(repo), errors_redacted: redact_errors(repo, 0, 0)}
  end

  defp drop_finished_bodies(repo) do
    keys = Mail.body_keys()

    {count, _rows} =
      from(j in Oban.Job,
        where:
          j.queue in ^@queues and j.state in ^@finished and
            fragment("jsonb_exists_any(?, ?::text[])", j.args, ^keys),
        update: [set: [args: fragment("? - ?::text[]", j.args, ^keys)]]
      )
      |> repo.update_all([])

    count
  end

  # Keyset pages by id, so a large table is never loaded whole.
  defp redact_errors(repo, after_id, count) do
    jobs =
      from(j in Oban.Job,
        where:
          j.queue in ^@queues and j.id > ^after_id and
            fragment("cardinality(?) > 0", j.errors),
        order_by: [asc: j.id],
        limit: @batch,
        select: %{id: j.id, errors: j.errors}
      )
      |> repo.all()

    count =
      Enum.reduce(jobs, count, fn %{id: id, errors: errors}, count ->
        case redact(errors) do
          ^errors ->
            count

          redacted ->
            repo.update_all(from(j in Oban.Job, where: j.id == ^id), set: [errors: redacted])
            count + 1
        end
      end)

    if length(jobs) == @batch,
      do: redact_errors(repo, List.last(jobs).id, count),
      else: count
  end

  @doc false
  # One job's `errors`, each unsafe entry's text replaced. Public for the test.
  @spec redact([map()]) :: [map()]
  def redact(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{"error" => error} = entry when is_binary(error) ->
        if Regex.match?(@unsafe, error),
          do: Map.put(entry, "error", Mail.display_error(error)),
          else: entry

      entry ->
        entry
    end)
  end
end
