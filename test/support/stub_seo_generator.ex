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

  @impl KilnCMS.Seo.Generator
  def draft(_document, _opts \\ []), do: raise("provider exploded")
end

defmodule KilnCMS.StubSeoGenerator.Counting do
  @moduledoc """
  Counts calls in an Agent so a test can prove re-entrancy guarding — two rapid
  clicks must produce exactly one generation.
  """
  @behaviour KilnCMS.Seo.Generator

  alias KilnCMS.Seo.Draft

  def start_link, do: Agent.start_link(fn -> 0 end, name: __MODULE__)

  def count, do: Agent.get(__MODULE__, & &1)

  def reset, do: Agent.update(__MODULE__, fn _ -> 0 end)

  @impl KilnCMS.Seo.Generator
  def draft(document, _opts \\ []) do
    Agent.update(__MODULE__, &(&1 + 1))
    {:ok, %Draft{seo_title: "Draft #{count()} for #{document.title}"}}
  end
end
