# Strict tenancy (#419) is a COMPILE-TIME switch. The strict CI leg
# (KILN_STRICT_TEST=true, or 1/yes/on) compiles fail-closed and runs ONLY the
# @moduletag :strict_tenancy smoke suite — the main suite predates strict and
# calls interfaces tenant-less, so it only runs against the fail-open build.
#
# Parsed by the same standalone snippet config/test.exs uses (#646) — this
# `require_file` is idempotent, so it's safe whether or not that one already
# ran in this VM. Duplicating the *raw* `== "1"` comparison here (rather than
# sharing it) is exactly how this var ended up with two independent readings
# that could silently disagree.
Code.require_file(Path.expand("../config/strict_test_flag.exs", __DIR__))

# In-app backups (#484) really shell out to pg_dump/pg_restore — a mocked
# backup proves nothing, since the whole premise is that the file it writes is
# one `scripts/restore.sh` can restore. Where the client tools are missing (or
# older than the server, which makes pg_dump refuse outright) those tests are
# EXCLUDED rather than wrapped in a conditional: an excluded test is reported
# in the run summary, whereas `if tools_available? do … end` turns a machine
# with no pg_dump into a green run that asserted nothing.
pg_tools_exclusion =
  if KilnCMS.Backups.availability() == :ok do
    []
  else
    IO.puts(
      :stderr,
      "note: excluding :pg_tools tests — pg_dump/pg_restore unavailable " <>
        "(#{inspect(KilnCMS.Backups.availability())})"
    )

    [:pg_tools]
  end

# PDF metadata stripping (#807) really shells out to qpdf, for the same reason
# the backup tests really shell out to pg_dump: the claim under test is that
# an uploaded PDF comes back with no `/Info` and no XMP, and only qpdf's actual
# output can show that. Excluded rather than conditionally skipped, on the
# reasoning above — and note `available?/0` checks the *capability*, so a host
# carrying qpdf older than 11.10 excludes these too rather than failing them.
qpdf_exclusion =
  if KilnCMS.DocumentProcessor.available?() do
    []
  else
    IO.puts(
      :stderr,
      "note: excluding :qpdf tests — no qpdf with --remove-info/--remove-metadata " <>
        "(needs qpdf >= 11.10; PDF uploads are refused without it)"
    )

    [:qpdf]
  end

if KilnCMS.Config.StrictTestFlag.strict?(System.get_env("KILN_STRICT_TEST")) do
  ExUnit.start(include: [strict_tenancy: true], exclude: [:test])
else
  ExUnit.start(exclude: [strict_tenancy: true] ++ pg_tools_exclusion ++ qpdf_exclusion)
end

Ecto.Adapters.SQL.Sandbox.mode(KilnCMS.Repo, :manual)
