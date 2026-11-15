defmodule KilnCMS.Test.ProcessMemory do
  @moduledoc """
  Peak memory held by one piece of work while it runs, for bounded-memory
  tests (#2860, #2906).

  VM-wide `:erlang.memory/1` is the wrong measure: it also counts whatever
  Oban, caches and other test modules allocate at the same time, so a test
  asserting "the VM grew by less than 32 MiB" flakes under CI load. This
  measures only the work's own processes.

  `fun` runs in a fresh worker whose group leader is a private forwarder.
  Every process the worker spawns, transitively, inherits that group leader
  unless something resets it, so "has our group leader" is the work's process
  family (Tasks, file io servers, port watchers). Its footprint is the
  processes' own memory plus each off-heap (refc) binary they reference,
  counted once by id, plus the ports they own. A file read into memory is a
  binary some family member holds, so it still counts in full; a raw file
  handle (`:file.open/2` with `:raw`) reads into the worker itself.
  """

  @doc """
  Runs `fun` and returns `{result, peak_bytes}`: its result and the largest
  footprint its process family had, sampled every 10 ms and once more at the
  end. A raise, throw or exit in `fun` is re-raised in the caller with its
  stacktrace.
  """
  @spec peak_growth((-> result)) :: {result, non_neg_integer()} when result: term()
  def peak_growth(fun) when is_function(fun, 0) do
    caller_gl = Process.group_leader()
    gl = spawn_link(fn -> forward_io(caller_gl) end)
    parent = self()
    ref = make_ref()

    worker =
      spawn_link(fn ->
        Process.group_leader(self(), gl)
        send(parent, {ref, :ready})

        receive do
          {^ref, :go} -> :ok
        end

        result =
          try do
            {:ok, fun.()}
          rescue
            e -> {:raise, e, __STACKTRACE__}
          catch
            kind, reason -> {kind, reason, __STACKTRACE__}
          end

        send(parent, {ref, :done, result})
      end)

    receive do
      {^ref, :ready} -> :ok
    end

    sampler = Task.async(fn -> sample(gl, 0) end)
    send(worker, {ref, :go})

    result =
      receive do
        {^ref, :done, result} -> result
      end

    send(sampler.pid, :stop)
    peak = Task.await(sampler, 5_000)
    Process.unlink(gl)
    Process.exit(gl, :kill)

    case result do
      {:ok, value} -> {value, peak}
      {:raise, e, stack} -> reraise e, stack
      {kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp forward_io(target) do
    receive do
      msg ->
        send(target, msg)
        forward_io(target)
    end
  end

  defp sample(gl, peak) do
    receive do
      :stop -> max(peak, footprint(gl))
    after
      10 -> sample(gl, max(peak, footprint(gl)))
    end
  end

  defp footprint(gl) do
    family =
      for pid <- Process.list(),
          Process.info(pid, :group_leader) == {:group_leader, gl},
          do: pid

    {heaps, binaries} =
      Enum.reduce(family, {0, %{}}, fn pid, {heaps, binaries} ->
        case Process.info(pid, [:memory, :binary]) do
          [memory: memory, binary: bins] ->
            {heaps + memory,
             Enum.reduce(bins, binaries, fn {id, size, _}, acc -> Map.put(acc, id, size) end)}

          nil ->
            {heaps, binaries}
        end
      end)

    ports =
      for port <- Port.list(),
          {:connected, owner} <- [Port.info(port, :connected)],
          owner in family,
          {:memory, memory} <- [Port.info(port, :memory)],
          reduce: 0,
          do: (acc -> acc + memory)

    heaps + (binaries |> Map.values() |> Enum.sum()) + ports
  end
end
