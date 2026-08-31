defmodule KilnCMS.StubSeoGenerator do
  @moduledoc """
  Deterministic `KilnCMS.Seo.Generator` for tests — the drafting twin of
  `KilnCMS.StubEmbedder`.

  Derives its draft from the document it was handed, so assertions can prove
  the *right* content actually reached the generator (and, for the locale
  tests, that the record's locale travelled with it) rather than just that
  something came back.

  Enable per-suite by swapping app env:

      setup do
        previous = Application.get_env(:kiln_cms, KilnCMS.Seo, [])

        Application.put_env(
          :kiln_cms,
          KilnCMS.Seo,
          Keyword.merge(previous, generator: KilnCMS.StubSeoGenerator, model: "stub:stub")
        )

        on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Seo, previous) end)
      end

  That is global app env, so any suite using it must be `async: false` — the
  same caveat `StubEmbedder` carries. **No stub here ever touches the network.**
  """

  @behaviour KilnCMS.Seo.Generator

  alias KilnCMS.Seo.Draft

  @impl KilnCMS.Seo.Generator
  def draft(document, _opts \\ []) do
    {:ok,
     %Draft{
       seo_title: "SEO: #{document.title}",
       seo_description: "A summary of #{document.title} in #{document.locale}.",
       seo_keywords: ["stub keyphrase", "second"],
       usage: %{input_tokens: 100, output_tokens: 20}
     }}
  end
end

defmodule KilnCMS.StubSeoGenerator.Failing do
  @moduledoc "A generator that always returns an error, for the failure path."
  @behaviour KilnCMS.Seo.Generator

  @impl KilnCMS.Seo.Generator
  def draft(_document, _opts \\ []), do: {:error, :boom}
end

defmodule KilnCMS.StubSeoGenerator.Raising do
  @moduledoc "A generator that raises, proving the facade degrades instead of crashing its caller."
  @behaviour KilnCMS.Seo.Generator

  # Raising unconditionally is the whole point, so dialyzer is right that there
  # is no local return — that's the behaviour under test, not a defect.
  @dialyzer {:nowarn_function, draft: 1}
  @dialyzer {:nowarn_function, draft: 2}

  @impl KilnCMS.Seo.Generator
  def draft(_document, _opts \\ []), do: raise("provider exploded")
end

defmodule KilnCMS.StubSeoGenerator.Counting do
  @moduledoc """
  Counts calls in an Agent so a test can prove re-entrancy guarding — two rapid
  clicks must produce exactly one generation.

  A run stays **in flight until the test releases it** with `release_all/0`
  (#1351). The guard can only be exercised while a run is genuinely in flight,
  and this stub used to hold that window open with a 150ms sleep — the whole
  budget in which the test's second click had to land, raced against two
  LiveView round-trips on a loaded CI box. A latch makes the window the test's
  to close: an instant completion can't slip in before the second click, and a
  forgotten release resolves itself after 3s (inside every caller's
  `render_async` budget) so a mistake reads as that test's own assertion
  failing, never as a hung suite.
  """
  @behaviour KilnCMS.Seo.Generator

  alias KilnCMS.Seo.Draft

  def start_link, do: Agent.start_link(fn -> {0, [], false, nil} end, name: __MODULE__)

  def count, do: Agent.get(__MODULE__, fn {n, _pids, _released?, _listener} -> n end)

  # Called from the test process, which thereby becomes the listener: every
  # run announces itself to it as `{:counting_draft_started, n}`, so a test
  # can await "run one is in flight" with `assert_receive` instead of polling.
  def reset do
    listener = self()
    Agent.update(__MODULE__, fn _ -> {0, [], false, listener} end)
  end

  @doc """
  Let every in-flight run complete. Sticky: a run that only *starts* after
  this call (a second run a broken guard let through) is released on arrival
  rather than waiting out the fallback, so the caller's count assertion sees
  it promptly.
  """
  def release_all do
    Agent.get_and_update(__MODULE__, fn {n, pids, _released?, listener} ->
      {pids, {n, [], true, listener}}
    end)
    |> Enum.each(&send(&1, :release))
  end

  @impl KilnCMS.Seo.Generator
  def draft(document, _opts \\ []) do
    {released?, n, listener} =
      Agent.get_and_update(__MODULE__, fn {n, pids, released?, listener} ->
        {{released?, n + 1, listener}, {n + 1, [self() | pids], released?, listener}}
      end)

    if listener, do: send(listener, {:counting_draft_started, n})

    unless released? do
      receive do
        :release -> :ok
      after
        3_000 -> :ok
      end
    end

    {:ok, %Draft{seo_title: "Draft #{count()} for #{document.title}"}}
  end
end
