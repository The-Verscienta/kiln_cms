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

if KilnCMS.Config.StrictTestFlag.strict?(System.get_env("KILN_STRICT_TEST")) do
  ExUnit.start(include: [strict_tenancy: true], exclude: [:test])
else
  ExUnit.start(exclude: [strict_tenancy: true])
end

Ecto.Adapters.SQL.Sandbox.mode(KilnCMS.Repo, :manual)
