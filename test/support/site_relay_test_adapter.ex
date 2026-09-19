defmodule KilnCMS.SiteRelayTestAdapter do
  @moduledoc """
  The test stand-in for a site's own SMTP relay (#1322, `KilnCMS.Mail.SiteRelay`).

  Like `Swoosh.Adapters.Test` it delivers nothing and messages the test process
  (and its `$callers`, so a LiveView's `start_async` send reaches the test) — but
  it also carries the **config** it was handed, because the connection is the
  thing under test: which host, which port, which credentials, how TLS is
  verified. Receive it as `{:site_relay_email, email, config}`.
  """
  use Swoosh.Adapter

  @impl true
  def deliver(email, config) do
    for pid <- Enum.uniq([self() | List.wrap(Process.get(:"$callers"))]) do
      send(pid, {:site_relay_email, email, config})
    end

    {:ok, %{}}
  end
end
