defmodule KilnCMS.Test.StubCrawlerResolver do
  @moduledoc """
  Offline DNS for crawler verification (#2254); `config/test.exs` makes it the
  resolver. Every address has no PTR record and every name does not exist
  (`{:error, :nxdomain}`) unless a test plants an answer.

  Answers live in a public ETS table that a process started by
  `test_helper.exs` owns, so they are visible from the lookup tasks and from
  every test. Keyed by the address or name asked about, so tests stay
  independent as long as each plants addresses and names of its own.

  An answer is one of:

    * a list: the PTR names, or the addresses (only those of the family asked
      for are returned, as DNS would)
    * `{:error, reason}`: `:nxdomain`, `:servfail`, `:timeout`, …
    * `{:block, pid}` / `{:block, pid, answer}`: send `pid`
      `{#{inspect(__MODULE__)}, :blocked, self(), callers, kind, key}` and wait
      for `release/1`, then answer `answer` (default NXDOMAIN). `callers` is the
      blocked process's `$callers`, whose head is the lookup task.

  Every call is counted: `calls/2`, `calls/3`.
  """
  @behaviour KilnCMS.CrawlerVerification.Resolver

  @table __MODULE__

  @doc "Creates the table, owned by a process that never exits. Idempotent."
  def start do
    if :ets.whereis(@table) == :undefined do
      parent = self()

      pid =
        spawn(fn ->
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
          send(parent, {__MODULE__, :ready})
          Process.sleep(:infinity)
        end)

      receive do
        {__MODULE__, :ready} -> {:ok, pid}
      after
        5_000 -> raise "#{inspect(__MODULE__)} table did not start"
      end
    else
      :ok
    end
  end

  @doc "Answer PTR queries for `ip` with `answer`."
  def put_ptr(ip, answer), do: :ets.insert(@table, {{:ptr, ip}, answer})

  @doc "Answer A/AAAA queries for `host` with `answer`."
  def put_addresses(host, answer), do: :ets.insert(@table, {{:addresses, host}, answer})

  @doc "Forgets the PTR answer planted for `ip` and the count of its queries."
  def reset(ip) do
    :ets.delete(@table, {:ptr, ip})
    :ets.delete(@table, {:calls, :ptr, ip})
    :ok
  end

  @doc "Lets a blocked call (the `pid` in its `:blocked` message) answer."
  def release(pid), do: send(pid, {__MODULE__, :release})

  @doc "How many PTR (`:ptr`, ip) or forward (`:addresses`, host) queries were made."
  def calls(:ptr, ip), do: count({:calls, :ptr, ip})

  def calls(:addresses, host),
    do: calls(:addresses, host, :inet) + calls(:addresses, host, :inet6)

  @doc "How many forward queries of `family` were made for `host`."
  def calls(:addresses, host, family), do: count({:calls, :addresses, host, family})

  @impl true
  def ptr(ip, _opts) do
    bump({:calls, :ptr, ip})
    answer(:ptr, ip, lookup({:ptr, ip}), & &1)
  end

  @impl true
  def addresses(host, family, _opts) do
    bump({:calls, :addresses, host, family})
    answer(:addresses, host, lookup({:addresses, host}), &of_family(&1, family))
  end

  defp answer(kind, key, {:block, pid}, shape), do: answer(kind, key, {:block, pid, nil}, shape)

  defp answer(kind, key, {:block, pid, then}, shape) do
    send(pid, {__MODULE__, :blocked, self(), Process.get(:"$callers", []), kind, key})

    receive do
      {__MODULE__, :release} -> answer(kind, key, then, shape)
    after
      30_000 -> {:error, :timeout}
    end
  end

  defp answer(_kind, _key, nil, _shape), do: {:error, :nxdomain}
  defp answer(_kind, _key, {:error, reason}, _shape), do: {:error, reason}
  defp answer(_kind, _key, list, shape) when is_list(list), do: {:ok, shape.(list)}

  defp of_family(addresses, :inet), do: Enum.filter(addresses, &(tuple_size(&1) == 4))
  defp of_family(addresses, :inet6), do: Enum.filter(addresses, &(tuple_size(&1) == 8))

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, answer}] -> answer
      [] -> nil
    end
  end

  defp bump(key), do: :ets.update_counter(@table, key, 1, {key, 0})

  defp count(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end
end
