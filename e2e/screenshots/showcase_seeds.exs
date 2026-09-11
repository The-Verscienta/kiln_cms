# Demo content for the home-page screenshots (`home.spec.js`). The stock
# seeds make three near-empty records and no media, which photographs as an
# empty product. Run AFTER `mix e2e.setup` (which runs priv/repo/seeds.exs):
#
#     MIX_ENV=e2e mix run e2e/screenshots/showcase_seeds.exs
#
# Idempotent by slug / filename, like the stock seeds. Everything goes through
# the domain code interfaces as the demo admin, and media through
# `KilnCMS.Media.Ingest`, so what is photographed is what the app really does.
# The site is fictional: "Tidewater Clay Studio".

alias KilnCMS.Accounts
alias KilnCMS.CMS
alias KilnCMS.Media.Ingest

tenant = Accounts.default_org_id()

{:ok, admin} =
  Accounts.get_user_by_email("admin@kiln.test", not_found_error?: false, authorize?: false)

admin || raise "run `MIX_ENV=e2e mix e2e.setup` first — the demo admin is missing"
opts = [actor: admin, tenant: tenant]

# --- Media -----------------------------------------------------------------

# Soft two-colour gradients stand in for photography: no binary fixtures in
# the repo, no licensing question, and they read as imagery at thumbnail size.
media_specs = [
  {"glaze-tests.jpg", "Rows of glaze test tiles", [196, 120, 84], [244, 214, 178], 35},
  {"wheel-room.jpg", "The wheel room at golden hour", [70, 94, 120], [226, 178, 132], 120},
  {"kiln-opening.jpg", "Opening the gas kiln", [132, 52, 36], [250, 170, 90], 200},
  {"studio-shelves.jpg", "Bisqueware drying on the shelves", [150, 142, 128], [232, 226, 214],
   80},
  {"tidewater-bowls.jpg", "Celadon bowls from the spring firing", [92, 140, 128], [214, 234, 222],
   300},
  {"harbour-view.jpg", "The harbour from the studio door", [48, 86, 132], [178, 208, 230], 160},
  {"clay-body.jpg", "Wedging a stoneware clay body", [120, 88, 70], [210, 186, 160], 250},
  {"market-stall.jpg", "Saturday market stall", [180, 96, 110], [246, 206, 190], 20}
]

existing_media =
  CMS.list_media_items!(opts)
  |> Map.new(&{&1.filename, &1})

tmp = Path.join(System.tmp_dir!(), "kiln-showcase-#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp)

media =
  Map.new(media_specs, fn {filename, alt, from, to, angle} ->
    case existing_media[filename] do
      nil ->
        path = Path.join(tmp, filename)

        Image.new!(1600, 1067)
        |> Image.linear_gradient!(start_color: from, finish_color: to, angle: angle)
        |> Image.write!(path, quality: 85)

        {:ok, item} = Ingest.store_file(path, filename, opts ++ [alt: alt])
        IO.puts("  media #{filename}")
        {filename, item}

      item ->
        {filename, item}
    end
  end)

File.rm_rf!(tmp)

image_block = fn filename, caption, order ->
  item = media[filename]

  %{
    type: :image,
    order: order,
    data: %{
      "url" => Map.get(item, :url),
      "media_id" => item.id,
      "alt" => item.alt,
      "caption" => caption
    }
  }
end

# --- Content -----------------------------------------------------------------

p = fn text -> "<p>#{text}</p>" end

# `state` is where the record should end up; `at` is a scheduled publish time
# (the calendar shot) and only applies to a record left in draft.
content = [
  {:page, "Welcome to Tidewater", "welcome-tidewater", :published, nil,
   [
     %{type: :heading, content: "Hand-thrown stoneware from the harbour", data: %{"level" => 1}},
     %{
       type: :rich_text,
       content:
         p.(
           "We are a small studio on the Tidewater quay making functional pottery for everyday tables. " <>
             "Come for a class, stay for the <strong>Saturday kiln opening</strong>."
         )
     },
     image_block.("wheel-room.jpg", "The wheel room, where every class starts.", 2),
     %{type: :quote, content: "Every pot is a small record of an afternoon."},
     %{type: :heading, content: "What's on this season", data: %{"level" => 2}},
     %{
       type: :rich_text,
       content:
         "<ul><li>Six-week wheel course, Tuesdays</li><li>Glaze chemistry weekend</li>" <>
           "<li>Open studio for members</li></ul>"
     }
   ]},
  {:page, "Classes & workshops", "classes", :published, nil,
   [
     %{type: :heading, content: "Classes & workshops", data: %{"level" => 1}},
     %{type: :rich_text, content: p.("Small groups, all materials and firings included.")}
   ]},
  {:page, "Visit the studio", "visit", :in_review, nil,
   [
     %{type: :heading, content: "Visit the studio", data: %{"level" => 1}},
     %{type: :rich_text, content: p.("Open Thursday to Sunday, 10:00–17:00.")}
   ]},
  {:page, "Gallery", "gallery", :draft, nil,
   [%{type: :heading, content: "Gallery", data: %{"level" => 1}}]},
  {:post, "Notes from the spring firing", "spring-firing", :published, nil,
   [
     %{type: :heading, content: "Notes from the spring firing", data: %{"level" => 1}},
     image_block.("kiln-opening.jpg", "Cone 10, reduction.", 1),
     %{type: :rich_text, content: p.("Forty-two pots in, thirty-nine out whole.")}
   ]},
  {:post, "Mixing a celadon that behaves", "celadon", :published, nil,
   [%{type: :rich_text, content: p.("Iron, a little patience, and a lot of test tiles.")}]},
  {:post, "Meet our new studio members", "new-members", :in_review, nil,
   [%{type: :rich_text, content: p.("Four new faces at the wheels this month.")}]},
  {:post, "Summer market dates", "summer-market", :draft, 4,
   [%{type: :rich_text, content: p.("Find us at the harbour market every Saturday.")}]},
  {:post, "Glaze chemistry weekend: what to bring", "glaze-weekend", :draft, 9,
   [%{type: :rich_text, content: p.("Aprons, notebooks, and curiosity.")}]},
  {:post, "Kiln opening — open house", "kiln-open-house", :draft, 15,
   [%{type: :rich_text, content: p.("Doors open at 11. Bring a friend.")}]},
  {:post, "Recycling clay without the mess", "recycling-clay", :draft, nil,
   [%{type: :rich_text, content: p.("Slaking, drying, wedging — the whole loop.")}]}
]

for {kind, title, slug, state, days_ahead, blocks} <- content do
  list = if kind == :page, do: &CMS.list_pages!/1, else: &CMS.list_posts!/1

  case list.(opts ++ [query: [filter: [slug: slug]]]) do
    [_ | _] ->
      IO.puts("  #{kind} #{slug} already exists")

    [] ->
      blocks = blocks |> Enum.with_index() |> Enum.map(fn {b, i} -> Map.put_new(b, :order, i) end)
      attrs = %{title: title, slug: slug, blocks: blocks}

      record =
        if kind == :page,
          do: CMS.create_page!(attrs, opts),
          else: CMS.create_post!(Map.put(attrs, :excerpt, title), opts)

      record =
        case {kind, state} do
          {:page, :published} -> CMS.publish_page!(record, %{}, opts)
          {:post, :published} -> CMS.publish_post!(record, %{}, opts)
          {:page, :in_review} -> CMS.submit_page_for_review!(record, %{}, opts)
          {:post, :in_review} -> CMS.submit_post_for_review!(record, %{}, opts)
          _ -> record
        end

      if days_ahead do
        at =
          DateTime.utc_now()
          |> DateTime.add(days_ahead, :day)
          |> Map.merge(%{hour: 9, minute: 0, second: 0, microsecond: {0, 0}})

        if kind == :page,
          do: CMS.update_page!(record, %{scheduled_at: at}, opts),
          else: CMS.update_post!(record, %{scheduled_at: at}, opts)
      end

      IO.puts("  #{kind} #{slug} (#{state})")
  end
end

IO.puts("Showcase seeding complete.")
