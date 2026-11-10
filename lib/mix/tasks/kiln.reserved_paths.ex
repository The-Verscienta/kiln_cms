defmodule Mix.Tasks.Kiln.ReservedPaths do
  @shortdoc "List stored records whose slug or path alias a reserved URL shadows"

  @moduledoc """
  List the stored records whose public URL a router-owned path shadows
  (#2374) — a page slugged `access-denied` from before that segment was
  reserved (#2143), or a path alias starting with a reserved segment.

  ```
  mix kiln.reserved_paths
  ```

  Report only: each record needs a new slug or alias, which is the operator's
  decision. Exits non-zero while anything is listed, so it can gate an upgrade
  script. See `KilnCMS.CMS.ReservedPathAudit`.

  In a release (no Mix): `bin/kiln_cms eval 'KilnCMS.Release.reserved_paths()'`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {_opts, _positional} = OptionParser.parse!(argv, strict: [])

    case KilnCMS.CMS.ReservedPathAudit.run_and_report(fn line -> Mix.shell().info(line) end) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
