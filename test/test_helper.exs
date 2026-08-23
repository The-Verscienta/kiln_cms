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

# A/V metadata stripping (#820), on the same reasoning again: the claim is that
# an uploaded MP4 comes back with no GPS and no device model, and only ffmpeg's
# actual output shows that. `ffprobe` is needed to *read* the result back, so
# both binaries gate this tag even though `strip_metadata/2` itself needs only
# ffmpeg.
#
# This one is worth the extra sentence: the first cut of #820 wrapped these in
# `if AVProcessor.available?() do :ok else … end`, which made the whole feature
# a green no-op on every machine that HAD ffmpeg — the exact shape the pg_dump
# comment above warns about, and it went in anyway.
ffmpeg_exclusion =
  if KilnCMS.AVProcessor.available?() do
    []
  else
    IO.puts(
      :stderr,
      "note: excluding :ffmpeg tests — needs ffmpeg and ffprobe on PATH " <>
        "(A/V uploads are stored unstripped without ffmpeg)"
    )

    [:ffmpeg]
  end

# The mirror image: the tests that pin what happens WITHOUT ffmpeg can only run
# where there is none. Between the two tags, one of the pair always runs, and
# neither ever passes by asserting nothing.
#
# Gated on ffmpeg ALONE, not `available?/0`. `strip_metadata/2` branches on
# ffmpeg only, so on a host carrying ffmpeg but no ffprobe these tests would
# otherwise run and fail: the strip actually shells out and reports "could not
# remux" rather than the "no ffmpeg" answer they assert.
no_ffmpeg_exclusion =
  if System.find_executable("ffmpeg"), do: [:no_ffmpeg], else: []

# The embedding-threshold calibration (#1086). Excluded unconditionally rather
# than gated on a capability, unlike everything above: it downloads a model from
# Hugging Face and spends minutes compiling and running it, which is not a thing
# to do on every `mix test` or on every CI run.
#
# Nothing is left unasserted by excluding it. It is the *generator* of
# `KilnCMS.TagSuggestionCorpus`'s recorded distances, and the assertions that
# pin the shipped ceiling against those numbers run always, in the same file.
# Re-measure with:
#
#     mix test --include calibration test/kiln_cms/search/tag_suggestion_calibration_test.exs
calibration_exclusion = [:calibration]

# Tests that take an ACCESS EXCLUSIVE lock on a table the whole suite shares —
# today, the one that drops `pages.search_vector` to prove a half-migrated
# content type can no longer take the site's whole search down (#295).
#
# The lock is held until the sandbox transaction rolls back, and while it is
# pending EVERY other connection's query on that table queues behind it: one
# such test overlapping anything else touching `pages` stalls the pool and
# hangs the run. `async: false` is not enough, because processes outliving an
# earlier async test still hold connections of their own.
#
# So they run in their own pass, alone, and CI runs that pass explicitly:
#
#     mix test --only table_lock
table_lock_exclusion = [:table_lock]

if KilnCMS.Config.StrictTestFlag.strict?(System.get_env("KILN_STRICT_TEST")) do
  ExUnit.start(include: [strict_tenancy: true], exclude: [:test])
else
  ExUnit.start(
    exclude:
      [strict_tenancy: true] ++
        pg_tools_exclusion ++
        qpdf_exclusion ++
        ffmpeg_exclusion ++
        no_ffmpeg_exclusion ++ calibration_exclusion ++ table_lock_exclusion
  )
end

Ecto.Adapters.SQL.Sandbox.mode(KilnCMS.Repo, :manual)
