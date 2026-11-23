defmodule KilnCMS.Test.ProcessMemoryTest do
  @moduledoc """
  The measure the bounded-memory tests stand on (#2906). Both of its
  properties were checked by hand when it was written for the media archiver
  (#2860) and are pinned here: memory held outside the work's process family
  is not counted, and memory held anywhere inside it, a grandchild included,
  is.

  No test waits on a sleep for a sample to land (#3196): one sample walks
  every process on the node and can outlast any hold under a loaded suite.
  They hold the memory until `sample/0` or `await_periodic_sample/0` returns.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Test.ProcessMemory

  @mib 1_048_576

  test "returns fun's result with the peak" do
    assert {:hello, peak} = ProcessMemory.peak_growth(fn -> :hello end)
    assert is_integer(peak) and peak >= 0
  end

  test "a large allocation by an unrelated process during the run is not counted" do
    outsider =
      spawn_link(fn ->
        receive do
          {:allocate, from} ->
            big = :binary.copy(<<1>>, 200 * @mib)
            send(from, :allocated)

            receive do
              :release -> byte_size(big)
            end
        end
      end)

    {_, peak} =
      ProcessMemory.peak_growth(fn ->
        send(outsider, {:allocate, self()})
        assert_receive :allocated, 10_000
        # A sample taken while the outsider holds it, so the bound below is
        # measured against the hold rather than passing for want of a sample.
        ProcessMemory.sample()
      end)

    send(outsider, :release)
    assert peak < 32 * @mib, "an outsider's 200 MiB counted: #{div(peak, @mib)} MiB"
  end

  # The periodic sampler catches it, not just the last sample: by the time
  # that one runs the worker has exited and the binary is gone.
  test "a binary held by the worker counts in full" do
    {_, peak} =
      ProcessMemory.peak_growth(fn ->
        big = :binary.copy(<<1>>, 64 * @mib)
        ProcessMemory.await_periodic_sample()
        byte_size(big)
      end)

    assert peak >= 64 * @mib
  end

  test "a binary held by a Task's spawned grandchild counts in full" do
    {_, peak} =
      ProcessMemory.peak_growth(fn ->
        Task.async(fn ->
          parent = self()

          grandchild =
            spawn_link(fn ->
              big = :binary.copy(<<1>>, 64 * @mib)
              send(parent, :held)

              receive do
                :release -> byte_size(big)
              end
            end)

          assert_receive :held, 10_000
          # The Task asks, so a grandchild left out of the family fails the
          # bound below rather than this call.
          ProcessMemory.sample()
          send(grandchild, :release)
        end)
        |> Task.await(15_000)
      end)

    assert peak >= 64 * @mib
  end

  test "sample/0 and await_periodic_sample/0 raise outside peak_growth/1" do
    assert_raise ArgumentError, ~r/inside the work/, fn -> ProcessMemory.sample() end

    assert_raise ArgumentError, ~r/inside the work/, fn ->
      ProcessMemory.await_periodic_sample()
    end
  end

  test "the work's io still reaches the caller's group leader" do
    assert ExUnit.CaptureIO.capture_io(fn ->
             ProcessMemory.peak_growth(fn -> IO.write("through the forwarder") end)
           end) == "through the forwarder"
  end

  test "a raise in fun is re-raised in the caller" do
    assert_raise RuntimeError, "boom", fn ->
      ProcessMemory.peak_growth(fn -> raise "boom" end)
    end
  end
end
