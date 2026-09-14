defmodule KilnCMS.Config.Host do
  @moduledoc """
  The canonical public host, normalized from `PHX_HOST` — one reader, one
  normalization (#1322).

  `config/runtime.exs` derived this inline while it was one file, and two
  unrelated blocks read the resulting variable: the endpoint block (the
  `url: [host: ...]` Phoenix generates absolute URLs from, the `check_origin`
  allowlist, and `:tenant_base_host`) and the mailer block (the SMTP `HELO`
  name, when `MAIL_HELO_HOST` is unset). Splitting that file into per-concern
  fragments put those two blocks in different files, and a local variable does
  not cross a fragment boundary — so the choice was to compute it twice
  or to state it once. This is the same argument `KilnCMS.Config.OriginList`
  makes for `EMBED_ORIGINS`/`CORS_ORIGINS`: two hand-rolled copies of one rule
  do not stay identical.

  ## Why normalizing is not cosmetic

  `PHX_HOST` is meant to be a bare host (`cms.example.com`), and is easy to
  misconfigure as a full URL. Phoenix uses the configured host **as-is** — it is
  not re-parsed — both for generating absolute URLs and for validating the
  LiveView/channel socket's `Origin` header, so a `https://` prefix that reaches
  the endpoint config silently breaks both at once. A trailing slash does the
  same. Stripping them here means a deployment that sets
  `PHX_HOST=https://cms.example.com/` behaves as though it had set the bare
  host, rather than failing in two places that look unrelated.

      # PHX_HOST=https://cms.example.com/
      KilnCMS.Config.Host.canonical()
      #=> "cms.example.com"

  Deliberately not an `iex>` doctest: the only way to write one is to
  `System.put_env("PHX_HOST", ...)`, and this VM's `PHX_HOST` is read by the
  `config/runtime.exs` evaluations in `test/config/runtime_env_flags_test.exs`.
  A doctest that set it would change what those assert, from a file that never
  mentions them. `KilnCMS.Config.HostTest` covers the cases instead, restoring
  the variable as it goes.

  The `"example.com"` fallback is Phoenix's generated default and is kept
  deliberately: it is an obviously-wrong host, which is what an operator who
  never set `PHX_HOST` should see in a generated URL.
  """

  @default "example.com"

  @doc """
  The canonical host: `PHX_HOST` with any scheme prefix and trailing slash
  stripped, or `"example.com"` when it is unset.

  Read at each call rather than memoized — `config/runtime.exs` evaluates once
  per boot, and a cached value would be wrong for the test harness that
  evaluates the file repeatedly with different environments.
  """
  @spec canonical() :: String.t()
  def canonical do
    (System.get_env("PHX_HOST") || @default)
    |> String.replace_leading("https://", "")
    |> String.replace_leading("http://", "")
    |> String.trim_trailing("/")
  end
end
