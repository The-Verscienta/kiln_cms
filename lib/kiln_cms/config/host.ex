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

  ## The platform fallback (#1529)

  When `PHX_HOST` is unset (or blank), the host a one-click deploy platform
  hands the container is used instead, so a fresh deploy's editor connects
  before anyone has thought about hostnames:

  | Platform | Variable | Host |
  |----------|----------|------|
  | Render | `RENDER_EXTERNAL_HOSTNAME` | as given |
  | Railway | `RAILWAY_PUBLIC_DOMAIN` | as given |
  | Fly.io | `FLY_APP_NAME` | `<name>.fly.dev` |

  These are the platform's *default* hostname. An operator who adds a custom
  domain sets `PHX_HOST` to it, which wins. DigitalOcean App Platform needs no
  entry: its template binds `PHX_HOST` to `${APP_DOMAIN}` directly.

  The `"example.com"` fallback is Phoenix's generated default and is kept
  deliberately: it is an obviously-wrong host, which is what an operator who
  never set `PHX_HOST` should see in a generated URL.
  """

  @default "example.com"

  # In order: the first one set wins. Each maps the variable's value to a host.
  @platform_hosts [
    {"RENDER_EXTERNAL_HOSTNAME", &Function.identity/1},
    {"RAILWAY_PUBLIC_DOMAIN", &Function.identity/1},
    {"FLY_APP_NAME", &__MODULE__.fly_host/1}
  ]

  @doc """
  The canonical host: `PHX_HOST` with any scheme prefix and trailing slash
  stripped; when it is unset or blank, the platform's default hostname (see
  the moduledoc); otherwise `"example.com"`.

  Read at each call rather than memoized — `config/runtime.exs` evaluates once
  per boot, and a cached value would be wrong for the test harness that
  evaluates the file repeatedly with different environments.
  """
  @spec canonical() :: String.t()
  def canonical do
    (present("PHX_HOST") || platform_host() || @default)
    |> String.replace_leading("https://", "")
    |> String.replace_leading("http://", "")
    |> String.trim_trailing("/")
  end

  @doc false
  # Public only so the `@platform_hosts` capture can name it.
  def fly_host(app_name), do: app_name <> ".fly.dev"

  defp platform_host do
    Enum.find_value(@platform_hosts, fn {var, to_host} ->
      if value = present(var), do: to_host.(value)
    end)
  end

  # Blank counts as unset — the convention every other variable follows. A
  # `PHX_HOST=` line would otherwise put an empty host in the endpoint config.
  defp present(var) do
    case System.get_env(var) do
      nil -> nil
      raw -> if String.trim(raw) == "", do: nil, else: String.trim(raw)
    end
  end
end
