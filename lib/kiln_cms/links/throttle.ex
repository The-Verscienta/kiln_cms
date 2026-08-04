defmodule KilnCMS.Links.Throttle do
  @moduledoc """
  Per-domain pacing for the external link checker (#474).

  A sweep over a real site produces a list of URLs that is *not* evenly spread:
  a documentation site links the same host eighty times, and checking those back
  to back is indistinguishable, from the far end, from a small denial of
  service. Kiln identifies itself in the user-agent
  (`KilnCMS.Links.External`), which is worth nothing if the traffic behind that
  name is what gets it blocked.

  So the bucket key is the **host**, not the org and not the job: the thing
  being protected is somebody else's server, and it does not care which of our
  tenants is pointing at it. One org's enormous sweep therefore slows down
  another org's checks against the same host, which is the correct trade — the
  alternative is N tenants each politely rate-limiting themselves into a
  collective hammering.

  Same Hammer/ETS idiom as `KilnCMSWeb.RateLimit`, `KilnCMS.Mail.RelayAlert` and
  `KilnCMS.LLM.Budget`.

  ## This is not a retry mechanism

  `check/1` reports `{:error, {:rate_limited, ms}}` and does nothing about it.
  The caller that can actually wait is the Oban worker, which snoozes for `ms`
  and lets the slot go to another host — sleeping inside the worker would hold
  a `:link_check` slot open doing nothing, and with one slot per concurrent
  check that is how a single busy domain stalls the whole queue.
  """
  use Hammer, backend: :ets

  # One request per host every two seconds — slow enough that a sweep is
  # background noise on the far end, fast enough that a few hundred links
  # against one host still finish inside a nightly window.
  @default_limit {1, 2_000}

  @doc """
  Whether a request to `host` may go out now, or how long to wait.

  A blank or missing host is allowed through: it cannot be paced, and refusing
  it here would silently drop links rather than let the checker judge them.
  """
  @spec check(String.t() | nil) :: :ok | {:error, {:rate_limited, non_neg_integer()}}
  def check(host) when is_binary(host) and host != "" do
    {count, window_ms} = limit()

    case hit("linkcheck:#{String.downcase(host)}", window_ms, count) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  def check(_host), do: :ok

  @doc "The configured `{count, window_ms}` per host."
  @spec limit() :: {pos_integer(), pos_integer()}
  def limit do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:per_host, @default_limit)
  end
end
