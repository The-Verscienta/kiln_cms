defmodule KilnCMS.Test.StubDNS do
  @moduledoc """
  Offline DNS resolver for the test suite (config/test.exs points
  `KilnCMS.Mail.DnsCheck` here): every lookup comes back empty, so DNS checks
  are deterministic "record absent" results with no network traffic. Tests
  that need richer answers pass their own `dns:` fixture explicitly.

  TXT answers can be planted per name with `put_txt/2` — for callers that read
  the configured resolver rather than taking a `dns:` option, such as a site's
  single sign-on domain check (`KilnCMS.Accounts.SiteSso.DomainCheck`, #1561).
  Keyed on the queried name in `:persistent_term`, so it is visible from every
  process (a LiveView, a controller) and async-safe as long as each test plants
  a name of its own; `delete_txt/1` removes it.
  """
  @behaviour KilnCMS.Mail.DnsCheck.DNS

  @doc "Answer `records` for TXT lookups of `name` from now on."
  def put_txt(name, records) when is_binary(name) and is_list(records),
    do: :persistent_term.put({__MODULE__, :txt, name}, records)

  @doc "Stop answering for `name`."
  def delete_txt(name) when is_binary(name), do: :persistent_term.erase({__MODULE__, :txt, name})

  @impl true
  def txt(name), do: :persistent_term.get({__MODULE__, :txt, name}, [])

  @impl true
  def mx(_name), do: []

  @impl true
  def ptr(_address), do: {:error, :nxdomain}

  @impl true
  def addresses(_name), do: []
end

defmodule KilnCMS.Test.StubTCP do
  @moduledoc """
  Offline TCP seam for the port-25 preflight in tests: always refused, so the
  preflight deterministically reports a blocked port without touching the
  network.
  """
  @behaviour KilnCMS.Mail.DnsCheck.TCP

  @impl true
  def banner(_host, _port, _timeout), do: {:error, :econnrefused}
end
