defmodule Mix.Tasks.Kiln.Provenance.Coverage do
  @shortdoc "Share of published artifacts carrying a verifiable provenance manifest"
  @moduledoc """
  Prints the number provenance-on-by-default has to move (#1929): of the
  published documents' fired artifacts, how many carry a stored manifest this
  instance can verify.

      mix kiln.provenance.coverage
      mix kiln.provenance.coverage --org <org-id>

  On a release, the same numbers over rpc:

      /app/bin/kiln_cms rpc "IO.inspect(KilnCMS.Provenance.coverage())"

  Artifacts fired before 1.7, or while no signing key resolved, are unsigned
  until they are fired again: `mix kiln.refire_all` signs them all. The same
  numbers are emitted every five minutes as `kiln_cms.provenance.coverage.*`
  telemetry.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: [org: :string])

    %{total: total, signed: signed, verifiable: verifiable, share: share} =
      KilnCMS.Provenance.coverage(opts[:org])

    Mix.shell().info("""
    Published artifacts: #{total}
    Signed:              #{signed}
    Verifiable:          #{verifiable}
    Share verifiable:    #{:erlang.float_to_binary(share * 100, decimals: 1)}%\
    """)
  end
end
