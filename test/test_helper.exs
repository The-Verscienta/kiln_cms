# Strict tenancy (#419) is a COMPILE-TIME switch. The strict CI leg
# (KILN_STRICT_TEST=1) compiles fail-closed and runs ONLY the
# @moduletag :strict_tenancy smoke suite — the main suite predates strict and
# calls interfaces tenant-less, so it only runs against the fail-open build.
if System.get_env("KILN_STRICT_TEST") == "1" do
  ExUnit.start(include: [strict_tenancy: true], exclude: [:test])
else
  ExUnit.start(exclude: [strict_tenancy: true])
end

Ecto.Adapters.SQL.Sandbox.mode(KilnCMS.Repo, :manual)
