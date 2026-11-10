defmodule KilnCMS.CrawlerVerification.Resolver do
  @moduledoc """
  The DNS seam crawler verification (#2254) asks through.
  `KilnCMS.CrawlerVerification.InetResolver` is the real one; the test suite
  configures `KilnCMS.Test.StubCrawlerResolver`.

  Both callbacks keep "there is no such record" apart from "the resolver could
  not answer": the first is a proven failure that may be cached for an hour,
  the second must never be.

    * `{:ok, names}` / `{:ok, addresses}`: the answer, which may be empty (the
      name exists but has no record of that type)
    * `{:error, :nxdomain}`: the name does not exist
    * `{:error, reason}`: anything else (`:timeout`, `:servfail`, `:refused`,
      a socket error). Never read as "no record".

  Options every call receives:

    * `:timeout`: the milliseconds left before the lookup's deadline. The
      call must return within it.
    * `:query_timeout_ms`: how long to wait for one nameserver's answer to one
      attempt.
  """

  @type opts :: [timeout: non_neg_integer(), query_timeout_ms: pos_integer()]

  @doc "The PTR names of `ip`, as the resolver returned them (not normalized)."
  @callback ptr(ip :: :inet.ip_address(), opts()) ::
              {:ok, [String.t() | charlist()]} | {:error, :nxdomain | term()}

  @doc "The `family` addresses (A for `:inet`, AAAA for `:inet6`) of `host`."
  @callback addresses(host :: String.t(), family :: :inet | :inet6, opts()) ::
              {:ok, [:inet.ip_address()]} | {:error, :nxdomain | term()}
end
