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
  Counts calls so a test can prove re-entrancy guarding — two rapid clicks
  must produce exactly one generation.

  A run stays in flight until the test releases it: the hold, the
  announcements, and their guarantees live in `KilnCMS.Test.Latch` (#1351) —
  see its moduledoc for the protocol. Assert on `release_all/0`'s return
  (`assert [_] = release_all()`): it is the proof the latch, not the bounded
  fallback, let the run finish.
  """
  @behaviour KilnCMS.Seo.Generator

  alias KilnCMS.Seo.Draft
  alias KilnCMS.Test.Latch

  def start_link, do: Latch.start_link(name: __MODULE__, listener: self())

  def count, do: Latch.entered(__MODULE__)

  # `listener` receives `{:latch_started, __MODULE__, n}` per run — explicit
  # (defaulted, not silently captured) so a caller resetting from a helper
  # process can point announcements at the asserting process.
  def reset(listener \\ self()), do: Latch.reset(__MODULE__, listener)

  def release_all, do: Latch.release_all(__MODULE__)

  @impl KilnCMS.Seo.Generator
  def draft(document, _opts \\ []) do
    n = Latch.enter(__MODULE__)
    # `n` is this run's own ordinal — a shared-count re-read here would label
    # every concurrently-held run with the same final number.
    {:ok, %Draft{seo_title: "Draft #{n} for #{document.title}"}}
  end
end
