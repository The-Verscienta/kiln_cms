# Demo content for the SwiftUI reader. Run from the Kiln checkout's root,
# after `mix setup` (which runs priv/repo/seeds.exs and creates the admin):
#
#     mix run examples/swiftui-reader/kiln/seed.exs
#
# It adds an admin-defined `recipe` type with one field of each kind the app
# shows natively:
#
#   * `ingredients`, a repeating `:group` (item, amount, unit);
#   * `method`, a rich `:text` delivered as plain text (with paragraph
#     breaks) and as Portable Text;
#   * `hero`, a `:media` image with a focal point;
#   * `serves` and `minutes`, integers.
#
# and publishes three recipes, each with a generated hero image. Idempotent:
# everything is looked up by its name or slug first, so re-running it changes
# nothing. Development only — it refuses :prod.
#
# Keep each HTML paragraph on one line: the HTML → Portable Text conversion
# keeps a newline inside a `<p>` as a `\n` in the span.

if Mix.env() == :prod, do: Mix.raise("The SwiftUI reader's demo seed is for development only.")

Logger.configure(level: :warning)

alias KilnCMS.Accounts
alias KilnCMS.CMS
alias KilnCMS.CMS.ContentTypes
alias KilnCMS.CMS.FieldDefinition
alias KilnCMS.Media.Ingest

org = Accounts.default_org_id()
admin_email = System.get_env("ADMIN_EMAIL", "admin@kiln.test")

admin =
  case Accounts.get_user_by_email(admin_email, not_found_error?: false, authorize?: false) do
    {:ok, %{} = user} -> user
    _ -> Mix.raise("No #{admin_email}. Run `mix setup` (or `mix run priv/repo/seeds.exs`) first.")
  end

opts = [actor: admin, tenant: org]

# --- The type and its fields ------------------------------------------------

recipe =
  case CMS.get_type_definition_by_name("recipe", opts) do
    {:ok, definition} ->
      IO.puts("  type recipe already exists")
      definition

    {:error, _not_found} ->
      IO.puts("  created type recipe")

      CMS.create_type_definition!(
        %{name: "recipe", label: "Recipe", plural_label: "Recipes"},
        opts
      )
  end

existing = fn ->
  recipe.id |> CMS.field_definitions_for_definition!(opts) |> Map.new(&{&1.name, &1})
end

ensure_field = fn attrs ->
  case existing.()[attrs.name] do
    nil ->
      IO.puts("  created field recipe.#{attrs.name}")
      CMS.create_field_definition!(Map.put(attrs, :type_definition_id, recipe.id), opts)

    field ->
      field
  end
end

ensure_field.(%{name: "serves", label: "Serves", field_type: :integer})
ensure_field.(%{name: "minutes", label: "Minutes", field_type: :integer})
ensure_field.(%{name: "hero", label: "Hero image", field_type: :media})

ensure_field.(%{
  name: "method",
  label: "Method",
  field_type: :text,
  deliver_plain: true,
  plain_breaks: true,
  deliver_portable: true
})

ensure_field.(%{name: "ingredients", label: "Ingredients", field_type: :group, multiple: true})

# Re-read: `for_definition` is what loads a group's sub-fields.
ingredients = existing.()["ingredients"]
sub_fields = Map.new(FieldDefinition.group_fields(ingredients), &{&1.name, &1})

for {name, extra} <- [
      {"item", %{field_type: :string, required: true}},
      {"amount", %{field_type: :float}},
      {"unit", %{field_type: :select, options: ["g", "ml", "tsp", "tbsp", "pcs"]}}
    ],
    not Map.has_key?(sub_fields, name) do
  IO.puts("  created field recipe.ingredients.#{name}")

  CMS.create_field_definition!(
    Map.merge(%{name: name, label: String.capitalize(name), group_of_id: ingredients.id}, extra),
    opts
  )
end

# --- Hero images ------------------------------------------------------------

# A generated image per recipe — a gradient with a "plate" off-centre — so the
# focal point visibly matters when the app crops it.
hero_image = fn filename, {from, to}, {cx, cy} ->
  case CMS.list_media_items!(Keyword.put(opts, :query, filter: [filename: filename])) do
    [item | _] ->
      item

    [] ->
      svg = """
      <svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1067">
        <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#{from}"/><stop offset="1" stop-color="#{to}"/>
        </linearGradient></defs>
        <rect width="1600" height="1067" fill="url(#g)"/>
        <circle cx="#{round(cx * 1600)}" cy="#{round(cy * 1067)}" r="230" fill="#fffaf0"/>
        <circle cx="#{round(cx * 1600)}" cy="#{round(cy * 1067)}" r="160" fill="#{to}" opacity="0.85"/>
      </svg>
      """

      path = Path.join(System.tmp_dir!(), filename)
      {:ok, {image, _flags}} = Vix.Vips.Operation.svgload_buffer(svg)
      :ok = Vix.Vips.Image.write_to_file(image, path)

      {:ok, item} =
        Ingest.store_file(path, filename,
          actor: admin,
          tenant: org,
          alt: "A plate of " <> (filename |> Path.rootname() |> String.replace("-", " ")),
          focal_x: cx,
          focal_y: cy
        )

      File.rm(path)
      IO.puts("  uploaded #{filename}")
      item
  end
end

# The variants (and the item's width/height) come from VariantWorker, an Oban
# job. Wait for it so the first artifacts already carry them; a server started
# later would re-fire the recipes when they land anyway.
await_variants = fn item ->
  Enum.reduce_while(1..60, item, fn _, item ->
    item = CMS.get_media_item!(item.id, opts)

    if item.width && item.variants not in [nil, [], %{}] do
      {:halt, item}
    else
      Process.sleep(500)
      {:cont, item}
    end
  end)
end

# --- Recipes ----------------------------------------------------------------

recipes = [
  %{
    slug: "buttermilk-pancakes",
    title: "Buttermilk pancakes",
    serves: 4,
    minutes: 25,
    hero: {"buttermilk-pancakes.jpg", {"#f6d365", "#c9752b"}, {0.72, 0.36}},
    intro: "<p>Thick, soft pancakes for a slow weekend morning.</p>",
    ingredients: [
      %{"item" => "Plain flour", "amount" => 200, "unit" => "g"},
      %{"item" => "Buttermilk", "amount" => 300, "unit" => "ml"},
      %{"item" => "Eggs", "amount" => 2, "unit" => "pcs"},
      %{"item" => "Baking powder", "amount" => 2, "unit" => "tsp"},
      %{"item" => "Melted butter", "amount" => 2, "unit" => "tbsp"}
    ],
    method: """
    <h2>Batter</h2>
    <ol><li>Whisk the <strong>flour</strong> and baking powder.</li>
    <li>Beat in the eggs, buttermilk and butter until <em>just</em> smooth.</li></ol>
    <h2>Cook</h2>
    <p>Ladle onto a hot pan. Flip when bubbles <em>stop</em> popping — about <code>2 min</code> a side.</p>
    <blockquote>Lumps are fine; overmixing is not.</blockquote>
    <p>More in <a href="https://kilncms.dev">the Kiln docs</a>.</p>
    """
  },
  %{
    slug: "shakshuka",
    title: "Shakshuka",
    serves: 2,
    minutes: 30,
    hero: {"shakshuka.jpg", {"#ff9a8b", "#a83232"}, {0.3, 0.6}},
    intro: "<p>Eggs poached in a peppery tomato sauce.</p>",
    ingredients: [
      %{"item" => "Chopped tomatoes", "amount" => 400, "unit" => "g"},
      %{"item" => "Red pepper", "amount" => 1, "unit" => "pcs"},
      %{"item" => "Eggs", "amount" => 4, "unit" => "pcs"},
      %{"item" => "Smoked paprika", "amount" => 1, "unit" => "tsp"}
    ],
    method: """
    <p>Soften the pepper in oil, add the paprika, then the tomatoes. Simmer for <strong>10 minutes</strong>.</p>
    <ul><li>Make four wells.</li><li>Crack in the eggs and cover.</li>
    <ul><li>Runny yolks: 5 minutes.</li></ul></ul>
    <p><s>Stir</s> Don't stir once the eggs are in.</p>
    """
  },
  %{
    slug: "green-salad",
    title: "Green salad",
    serves: 2,
    minutes: 10,
    hero: {"green-salad.jpg", {"#d4fc79", "#3b8d5b"}, {0.5, 0.5}},
    intro: "<p>Crisp leaves, sharp dressing.</p>",
    ingredients: [
      %{"item" => "Little gem lettuce", "amount" => 2, "unit" => "pcs"},
      %{"item" => "Olive oil", "amount" => 3, "unit" => "tbsp"},
      %{"item" => "Lemon juice", "amount" => 1, "unit" => "tbsp"},
      %{"item" => "Flaky salt"}
    ],
    method: """
    Whisk the oil and lemon with a pinch of salt.

    Dress the leaves just before serving.
    """
  }
]

for spec <- recipes do
  case ContentTypes.list!("recipe", Keyword.put(opts, :query, filter: [slug: spec.slug])) do
    [%{state: :published} | _] ->
      IO.puts("  recipe #{spec.slug} already exists")

    [draft | _] ->
      ContentTypes.transition("recipe", "publish", draft, opts)
      IO.puts("  published recipe #{spec.slug}")

    [] ->
      {filename, colours, focal} = spec.hero
      hero = filename |> hero_image.(colours, focal) |> await_variants.()

      entry =
        ContentTypes.create!(
          "recipe",
          %{
            title: spec.title,
            slug: spec.slug,
            blocks: [
              %{
                "_type" => "rich_text",
                "body" => KilnCMS.Blocks.PortableText.from_html(spec.intro)
              }
            ],
            custom_fields: %{
              "serves" => spec.serves,
              "minutes" => spec.minutes,
              "hero" => hero.id,
              "ingredients" => spec.ingredients,
              "method" => spec.method
            }
          },
          opts
        )

      ContentTypes.transition("recipe", "publish", entry, opts)
      IO.puts("  published recipe #{spec.slug}")
  end
end

IO.puts("Recipe demo ready: GET /api/sync?initial=true&type=recipe")
