defmodule KilnCMS.Docs.ExtrasLinksTest do
  @moduledoc """
  Every relative Markdown link between two ExDoc extras lands on the file whose
  path was written.

  ExDoc resolves a relative link from an extra **by basename alone**. The whole
  of `ExDoc.Formatter.extra_paths/1` is

      Map.put(acc, Path.basename(source_path), id)

  folded over `extras` in order, and `ExDoc.Autolink.build_extra_link/2` looks
  the link up as `config.extras[Path.basename(path)]`. The directories you wrote
  are never consulted, and the `filename:` override changes only the *output*
  name, not this lookup. So when several extras share a basename, every relative
  link to any of them renders as a link to whichever was registered **last**.

  Four extras are named `README.md` — the root one plus `examples/`, `projects/`
  and `clients/elixir/kiln_client/`. Ten links written as `../README.md`,
  `../projects/README.md` or `../examples/README.md` therefore rendered as links
  to the Elixir client's page, and an eleventh (`../clients/js/README.md`, not an
  extra at all) was quietly absorbed into it too.

  **`mix docs --warnings-as-errors` does not catch this.** It warns only when a
  basename is missing from the map entirely; a basename that *is* present
  resolves silently, to the wrong page. The docs job was green the whole time.

  The fix in the source documents is to link a README by its absolute
  `https://github.com/The-Verscienta/kiln_cms/blob/main/…` URL — the only form
  that is right both on github.com and in `mix docs` output, and the form this
  repository already uses for `.github/SECURITY.md` and `AGENTS.md`. This test is
  what stops the silent form from coming back, for README and for any basename
  that collides later.

  See CONTRIBUTING.md, "Documentation", and the `extras/0` comment in `mix.exs`.
  """
  use ExUnit.Case, async: true

  # The extensions ExDoc treats as extras and rewrites to `.html`
  # (`ExDoc.Autolink`'s `@builtin_ext`). Anything else is passed through
  # untouched and is not our business.
  @builtin_ext [".livemd", ".cheatmd", ".md", ".txt", ""]

  # `[text](href)`, allowing one level of brackets inside the text so that
  # ``[`examples/README.md`](…)`` and `[**Creating an admin user**](…)` match.
  @link ~r/\[(?:[^\[\]]|\[[^\]]*\])*\]\(([^()\s]+)\)/

  @extras Mix.Project.config()[:docs][:extras] |> Enum.map(fn {path, _} -> to_string(path) end)

  test "every relative link between extras resolves to the file it names" do
    links = for extra <- @extras, link <- relative_links(extra), do: link

    # A broken regex or a moved extras list would otherwise pass vacuously.
    assert length(links) > 200,
           "expected the extras to contain hundreds of relative links, found #{length(links)}"

    mistargeted =
      for {source, line, href, written} <- links,
          resolved = resolves_to(written),
          resolved != nil and resolved != written do
        "  #{source}:#{line}\n" <>
          "      written:  #{href}  ->  #{written}\n" <>
          "      renders as a link to:  #{resolved}"
      end

    assert mistargeted == [],
           """
           These links render as links to a different file than the one they name.

           ExDoc resolves a relative link from an extra by BASENAME, taking the
           last extra registered with that basename — the directories below are
           ignored. Nothing in `mix docs --warnings-as-errors` reports it.

           #{Enum.join(mistargeted, "\n")}

           Fix each one by linking the file's absolute URL:

               https://github.com/The-Verscienta/kiln_cms/blob/main/<path>

           which is correct both on github.com and in the generated docs. Do not
           fix it by reordering `extras:` in mix.exs — that only moves which of
           the colliding links is wrong.
           """
  end

  # The extra ExDoc actually links to for a path with this basename: the last
  # registered one, or nil when no extra shares the basename (which ExDoc
  # reports itself, as a warning the docs job turns into an error).
  defp resolves_to(written) do
    base = Path.basename(written)

    @extras
    |> Enum.filter(&(Path.basename(&1) == base))
    |> List.last()
  end

  # Relative links to a Markdown-ish file, as {source, line, href, written},
  # where `written` is the link target resolved to a repo-root-relative path.
  defp relative_links(extra) do
    for {line, number} <-
          extra |> File.read!() |> prose() |> String.split("\n") |> Enum.with_index(1),
        [_, href] <- Regex.scan(@link, line),
        uri = URI.parse(href),
        is_nil(uri.scheme),
        is_nil(uri.host),
        is_binary(uri.path),
        uri.path != "",
        Path.extname(uri.path) in @builtin_ext do
      written = uri.path |> Path.expand(Path.dirname(extra)) |> Path.relative_to_cwd()
      {extra, number, href, written}
    end
  end

  # Blank out what ExDoc never autolinks — fenced code blocks, inline code spans
  # and HTML comments — keeping the line count so failures point at the real
  # line. Without this, `mix docs`'s own prose about `[text](url)` and the
  # comment in README.md explaining the SECURITY.md link both read as links.
  defp prose(markdown) do
    markdown
    |> String.replace(~r/<!--.*?-->/s, &String.replace(&1, ~r/[^\n]/, " "))
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_fence? ->
      cond do
        Regex.match?(~r/^\s*(```|~~~)/, line) -> {"", not in_fence?}
        in_fence? -> {"", true}
        true -> {String.replace(line, ~r/``[^`]*``|`[^`\n]*`/, ""), false}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end
end
