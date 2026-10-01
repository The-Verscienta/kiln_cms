defmodule Mix.Tasks.Kiln.Mail.Scrub do
  @shortdoc "Strip sign-in links from stored mail job errors and finished mail jobs"

  @moduledoc """
  Remove the sign-in links that releases before 1.0 left in `oban_jobs`
  (#1843): adapter-crash errors that quoted the rendered email, and the
  subject and body of finished mail and newsletter jobs.

      mix kiln.mail.scrub

  The upgrade to 1.0 runs this once, as a data migration. Run it again after
  restoring a backup taken before the upgrade. Idempotent, and it touches the
  `mail` and `newsletter` queues only. See `KilnCMS.Mail.Scrub`.

  In a release (no Mix): `bin/kiln_cms eval 'KilnCMS.Release.scrub_mail_jobs()'`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    %{bodies_dropped: bodies, errors_redacted: errors} = KilnCMS.Mail.Scrub.run()

    Mix.shell().info(
      "Mail jobs scrubbed: #{errors} with errors redacted, #{bodies} finished jobs' messages dropped."
    )
  end
end
