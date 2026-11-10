defmodule KilnCMS.Test.PublicAddress do
  @moduledoc """
  Public client addresses no other test in the run has used (#2254).

  Delivery and crawler-verification tests charge VM-global state per address:
  the Hammer `:delivery` counter (a 20-day window), the verification cache and
  the in-flight table. An address built from `System.unique_integer/1` modulo
  a /16 wraps once the VM has handed out 65,536 integers, which a full CI shard
  can do, and a wrapped address inherits whatever an earlier test charged.

  This draws from one per-VM counter (`:atomics`, created by `start/0` from
  `test_helper.exs`) that never wraps in a run, mapped into ranges that stay
  clear of the fixed addresses tests plant by hand (`66.249.0.0/16`):

    * `v4/0` — `66.0.0.0`–`66.123.255.255`, one address per call;
    * `v4_own_24/0` — `66.248.0.0/16`, each call in a /24 the previous 255
      calls did not use. Fixed /16 on purpose: prefix-cap tests need several
      /24s inside one /16. These addresses only meet the verifier, under a
      per-test `rate_scope`, so a /24 reused much later is harmless;
    * `v6/0` — inside `2001:4860:4801::/48`, each call in a /64 of its own.
  """

  @key {__MODULE__, :counter}

  @doc "Creates the counter. Called once from `test_helper.exs`."
  def start do
    :persistent_term.put(@key, :atomics.new(1, signed: false))
    :ok
  end

  @doc "A public IPv4 address no earlier call returned."
  def v4 do
    n = next()
    {66, rem(div(n, 65_536), 124), rem(div(n, 256), 256), rem(n, 256)}
  end

  @doc "A public IPv4 address in `66.248.0.0/16`, in a /24 the previous 255 calls did not use."
  def v4_own_24 do
    n = next()
    {66, 248, rem(n, 256), 200}
  end

  @doc "A public IPv6 address in a /64 no earlier call used."
  def v6 do
    n = next()
    {0x2001, 0x4860, 0x4801, rem(n, 0x10000), 0, 0, 0, rem(div(n, 0x10000), 0x10000) + 1}
  end

  defp next, do: :atomics.add_get(:persistent_term.get(@key), 1, 1)
end
