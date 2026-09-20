defmodule KilnCMS.Media.ImageTransformVectorsTest do
  @moduledoc """
  The URL-builder parity tripwire.

  `KilnCMS.Media.ImageTransform` is the reference for the transform URL
  grammar; the JS SDK (`clients/js/src/transform.ts`) and the Elixir client
  (`KilnClient.Image`) reimplement it, because a headless frontend has to
  build these URLs without calling Kiln. All three assert the same checked-in
  vectors — this side from ExUnit, the others from vitest and the client's own
  ExUnit suite — so a change to one builder that the others don't mirror turns
  exactly one suite red instead of producing URLs the server 400s or 403s.

  To regenerate after a deliberate change mirrored in all three:

      MIX_ENV=test mix run --no-start scripts/generate_image_transform_vectors.exs
  """
  # async: false — builds under the fixture's signing key via the app env.
  use ExUnit.Case, async: false

  alias KilnCMS.Media.ImageTransform

  @vectors Path.expand("../../../clients/js/test/fixtures/image_transform_vectors.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  setup do
    previous = Application.get_env(:kiln_cms, :image_transforms)
    # The vectors are built against the shipped ladder; an operator override
    # in the test env would make them lie.
    Application.put_env(:kiln_cms, :image_transforms, [])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, :image_transforms, previous),
        else: Application.delete_env(:kiln_cms, :image_transforms)
    end)
  end

  test "the fixture was built against the shipped size ladder" do
    assert @vectors["sizes"] == ImageTransform.sizes()
  end

  test "version/1 reproduces every version vector" do
    for %{"media" => name, "expected" => expected} <- @vectors["versions"], expected do
      assert ImageTransform.version(@vectors["media"][name]) == expected, name
    end
  end

  test "url/2 reproduces every URL vector" do
    for %{"name" => name, "media" => media, "options" => options, "key" => key} = vector <-
          @vectors["urls"] do
      assert ImageTransform.url(@vectors["media"][media], opts(options, key)) ==
               vector["expected"],
             name
    end
  end

  test "srcset/3 reproduces every srcset vector" do
    for %{"name" => name, "media" => media, "options" => options, "key" => key} = vector <-
          @vectors["srcsets"] do
      assert ImageTransform.srcset(@vectors["media"][media], vector["widths"], opts(options, key)) ==
               vector["expected"],
             name
    end
  end

  test "every unsigned vector passes the server's allowlist, and every signed one its signature" do
    Application.put_env(:kiln_cms, :image_transforms, signing_key: @vectors["signing_key"])

    for %{"expected" => path, "name" => name} <- @vectors["urls"] do
      ["", "media", id, "t", ops] = String.split(path, "/")
      assert {:ok, params} = ImageTransform.parse(ops), name
      assert :ok = ImageTransform.authorize(id, params), name
    end
  end

  defp opts(options, key) do
    Enum.map(options, fn
      {"width", v} -> {:width, v}
      {"height", v} -> {:height, v}
      {"aspect_ratio", v} -> {:aspect_ratio, v}
      {"dpr", v} -> {:dpr, v}
      {"fit", v} -> {:fit, String.to_existing_atom(v)}
      {"crop", v} -> {:crop, String.to_existing_atom(v)}
      {"format", v} -> {:format, String.to_existing_atom(v)}
      {"quality", v} -> {:quality, v}
    end) ++ if(key, do: [sign: true, key: key], else: [sign: false])
  end
end
