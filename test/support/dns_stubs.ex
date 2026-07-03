defmodule KilnCMS.Test.StubDNS do
  @moduledoc """
  Offline DNS resolver for the test suite (config/test.exs points
  `KilnCMS.Mail.DnsCheck` here): every lookup comes back empty, so DNS checks
  are deterministic "record absent" results with no network traffic. Tests
  that need richer answers pass their own `dns:` fixture explicitly.
  """
  @behaviour KilnCMS.Mail.DnsCheck.DNS

  @impl true
  def txt(_name), do: []

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
