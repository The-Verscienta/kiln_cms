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

  @marker :"$kiln_process_memory_forwarder"

  @doc """
  Runs `fun` and returns `{result, peak_bytes}`: its result and the largest
  footprint its process family had, sampled every 10 ms and once more at the
  end. A raise, throw or exit in `fun` is re-raised in the caller with its
  stacktrace.

  One sample walks every process on the node, so under a loaded suite it can
  take longer than the work holds its memory. Tests that must see a sample
  while something is held call `sample/0` or `await_periodic_sample/0` from
  inside the work instead of sleeping (#3196).
  """
  @spec peak_growth((-> result)) :: {result, non_neg_integer()} when result: term()
  def peak_growth(fun) when is_function(fun, 0) do
    caller_gl = Process.group_leader()

    gl =
      spawn_link(fn ->
        Process.put(@marker, true)

        receive do
          {__MODULE__, :sampler, sampler} -> forward_io(caller_gl, sampler)
        end
      end)

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

    sampler = Task.async(fn -> sample(gl, 0, []) end)
    send(gl, {__MODULE__, :sampler, sampler.pid})
    send(worker, {ref, :go})

    result =
      receive do
        {^ref, :done, result} -> result
      end

    send(sampler.pid, :stop)
    # Unbounded: one walk of every process can take seconds under load, and
    # the test's own timeout bounds the whole run.
    peak = Task.await(sampler, :infinity)
    Process.unlink(gl)
    Process.exit(gl, :kill)

    case result do
      {:ok, value} -> {value, peak}
      {:raise, e, stack} -> reraise e, stack
      {kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  @doc """
  Takes a sample now and waits for it. Call it from inside the work given to
  `peak_growth/1` (any process it spawned, transitively) while the memory to
  be measured is held. Raises outside `peak_growth/1`.
  """
  @spec sample() :: :ok
  def sample, do: request(:sample)

  @doc """
  Waits until the periodic sampler has finished a sample that started after
  this call: what proves the 10 ms sampling itself catches a peak in the
  middle of the work, not only `sample/0` and the last sample. Raises outside
  `peak_growth/1`.
  """
  @spec await_periodic_sample() :: :ok
  def await_periodic_sample, do: request(:tick)

  defp request(kind) do
    gl = Process.group_leader()

    # Checked without a message, so a busy forwarder is never mistaken for a
    # missing one, and a real group leader is never sent one it doesn't know.
    case Process.info(gl, :dictionary) do
      {:dictionary, dict} when is_list(dict) ->
        unless Keyword.get(dict, @marker), do: raise_outside()

      _ ->
        raise_outside()
    end

    ref = make_ref()
    send(gl, {__MODULE__, kind, self(), ref})

    receive do
      {^ref, :sampled} -> :ok
    end
  end

  defp raise_outside do
    raise ArgumentError,
          "ProcessMemory.sample/0 and await_periodic_sample/0 must be called " <>
            "from inside the work given to peak_growth/1"
  end

  defp forward_io(target, sampler) do
    receive do
      {__MODULE__, _kind, _from, _ref} = request ->
        send(sampler, request)
        forward_io(target, sampler)

      msg ->
        send(target, msg)
        forward_io(target, sampler)
    end
  end

  # `waiting` holds `await_periodic_sample/0` callers: answered after the next
  # periodic sample, whose walk starts after their request arrived.
  defp sample(gl, peak, waiting) do
    receive do
      :stop ->
        max(peak, footprint(gl))

      {__MODULE__, :sample, from, ref} ->
        peak = max(peak, footprint(gl))
        send(from, {ref, :sampled})
        sample(gl, peak, waiting)

      {__MODULE__, :tick, from, ref} ->
        sample(gl, peak, [{from, ref} | waiting])
    after
      10 ->
        peak = max(peak, footprint(gl))
        Enum.each(waiting, fn {from, ref} -> send(from, {ref, :sampled}) end)
        sample(gl, peak, [])
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
