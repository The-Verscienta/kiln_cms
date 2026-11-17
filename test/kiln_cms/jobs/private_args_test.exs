defmodule KilnCMS.Jobs.PrivateArgsTest do
  @moduledoc """
  `KilnCMS.Jobs.PrivateArgs` (#2992): which workers' args are private, the
  seal the automation readers accept, and when `finishing/3` drops the keys
  from a job's row.
  """
  use KilnCMS.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Jobs.PrivateArgs

  defmodule ProbeWorker do
    @moduledoc false
    use Oban.Worker, queue: :default, max_attempts: 3

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defp insert!(args \\ %{"keep" => "id", "secret" => "visitor data"}),
    do: args |> ProbeWorker.new() |> Oban.insert!()

  defp args(job), do: Repo.one!(from(j in Oban.Job, where: j.id == ^job.id, select: j.args))

  describe "registry" do
    test "every registered name is a loaded Oban worker, spelled as Oban stores it" do
      for {name, keys} <- PrivateArgs.registry() do
        assert {:ok, module} = Oban.Worker.from_string(name)
        assert function_exported?(module, :perform, 1), "#{name} is not an Oban worker"
        assert Oban.Worker.to_string(module) == name
        assert keys != []
      end
    end

    test "keys/1 answers for a module or the stored name, and [] for any other worker" do
      assert PrivateArgs.keys(KilnCMS.Forms.AutoresponderWorker) == ~w(data to)
      assert PrivateArgs.keys("KilnCMS.Automation.RuleWorker") == ~w(payload sealed)
      assert PrivateArgs.keys(KilnCMS.Mail.DeliveryWorker) == []
      assert PrivateArgs.keys(nil) == []
      refute PrivateArgs.registered?("KilnCMS.Newsletter.SendWorker")
    end
  end

  describe "seal/1 and open/1" do
    test "round-trip a payload, and the seal does not show it" do
      payload = %{"title" => "Draft secret", "nested" => %{"n" => 1}}
      sealed = PrivateArgs.seal(payload)

      refute sealed =~ "Draft secret"
      assert PrivateArgs.open(sealed) == {:ok, payload}
    end

    test "anything else is unreadable" do
      assert PrivateArgs.open("not base64 !") == {:error, :unreadable}
      assert PrivateArgs.open(Base.encode64("not a ciphertext")) == {:error, :unreadable}
      assert PrivateArgs.open(nil) == {:error, :unreadable}
    end
  end

  describe "finishing/3" do
    test "a finishing outcome drops the keys and returns the outcome" do
      for outcome <- [:ok, {:ok, 1}, {:cancel, "x"}, {:discard, "x"}, :discard, :whatever] do
        job = insert!()
        assert PrivateArgs.finishing(job, ~w(secret), fn -> outcome end) == outcome
        assert args(job) == %{"keep" => "id"}, "kept the keys on #{inspect(outcome)}"
      end
    end

    test "a snooze or a failure with attempts left keeps them" do
      for outcome <- [{:snooze, 5}, {:error, "transient"}] do
        job = %{insert!() | attempt: 1}
        assert PrivateArgs.finishing(job, ~w(secret), fn -> outcome end) == outcome
        assert args(job)["secret"] == "visitor data"
      end
    end

    test "a failure on the last attempt drops them" do
      job = %{insert!() | attempt: 3}
      assert PrivateArgs.finishing(job, ~w(secret), fn -> {:error, "x"} end) == {:error, "x"}
      assert args(job) == %{"keep" => "id"}
    end

    test "a raise re-raises, and drops them only on the last attempt" do
      early = %{insert!() | attempt: 1}

      assert_raise RuntimeError, fn ->
        PrivateArgs.finishing(early, ~w(secret), fn -> raise "boom" end)
      end

      assert args(early)["secret"] == "visitor data"

      last = %{insert!() | attempt: 3}

      assert_raise RuntimeError, fn ->
        PrivateArgs.finishing(last, ~w(secret), fn -> raise "boom" end)
      end

      assert args(last) == %{"keep" => "id"}
    end

    test "a job that was never inserted is left alone" do
      assert PrivateArgs.finishing(%Oban.Job{args: %{}}, ~w(secret), fn -> :ok end) == :ok
    end
  end
end
