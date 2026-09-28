# Seeds the benchmark database with a realistic published corpus (#1546).
#
#   MIX_ENV=prod mix run scripts/benchmarks/seed.exs
#
# Run by `api_latency.sh` against its OWN throwaway database. It refuses any
# other: DATABASE_URL must name a database whose name starts `kiln_cms_bench`.
#
# Everything goes through the domain code interfaces as an admin actor, the
# way `priv/repo/seeds.exs` does, so each document is versioned, indexed for
# search and fired exactly as an editor's publish would leave it. The script
# then waits until every firing job has run, so the benchmark starts against
# a corpus whose artifacts all exist.
#
# Environment:
#   BENCH_PAGES   published pages (default 500)
#   BENCH_POSTS   published posts (default 1500)
#   BENCH_DRAFTS  unpublished posts, which anonymous reads must filter out
#                 (default 200)
#   BENCH_SEED    RNG seed, so two runs build the same corpus (default 1546)

alias KilnCMS.Accounts
alias KilnCMS.Accounts.User
alias KilnCMS.CMS

db = KilnCMS.Repo.config()[:database] || ""

unless String.starts_with?(db, "kiln_cms_bench") do
  Mix.raise("Refusing to seed #{inspect(db)}: the benchmark only writes to kiln_cms_bench*")
end

int_env = fn name, default -> name |> System.get_env("#{default}") |> String.to_integer() end

pages = int_env.("BENCH_PAGES", 500)
posts = int_env.("BENCH_POSTS", 1500)
drafts = int_env.("BENCH_DRAFTS", 200)
seed = int_env.("BENCH_SEED", 1546)
:rand.seed(:exsss, {seed, 7, 11})

tenant = Accounts.default_org_id()
opts = [tenant: tenant]

admin =
  Ash.Seed.seed!(User, %{
    email: "bench-admin@kiln.test",
    name: "Bench Admin",
    hashed_password: Bcrypt.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(24))),
    confirmed_at: DateTime.utc_now(),
    role: :admin
  })

opts = Keyword.put(opts, :actor, admin)

words =
  ~w(kiln clay glaze fire studio vessel porcelain stoneware wheel throw trim bisque
     oxide ash reduction cone temperature pottery craft form surface texture colour
     editor content publish delivery headless schema block page post archive season
     garden river mountain city harbour market library museum journey morning winter
     summer autumn spring light shadow window market bridge signal network archive
     recipe method measure balance pattern rhythm detail lesson practice history)

# Real text is Zipf-shaped: a few words everywhere, most words rare. The
# common list above gives the first; `rare_word/1` gives the second — 3,000
# made-up words, two per sentence, so each lands in a handful of documents.
# load.exs derives the same words for its selective search queries.
syllables = ~w(ka lo mi re tu sa ven dor pli qua zen fo bri nu tal gor)

rare_word = fn n ->
  Enum.map_join([div(n, 256), rem(div(n, 16), 16), rem(n, 16)], &Enum.at(syllables, &1))
end

sentence = fn n ->
  (for(_ <- 1..n, do: Enum.random(words)) ++
     for(_ <- 1..2, do: rare_word.(:rand.uniform(3000) - 1)))
  |> Enum.shuffle()
  |> Enum.join(" ")
  |> String.capitalize()
  |> Kernel.<>(".")
end

paragraph = fn ->
  Enum.map_join(1..Enum.random(3..6), " ", fn _ -> sentence.(Enum.random(8..18)) end)
end

blocks = fn title ->
  sections =
    for i <- 1..Enum.random(2..4) do
      [
        %{"_type" => "heading", "text" => "#{title} — part #{i}", "level" => 2}
        | for(
            _ <- 1..Enum.random(1..3),
            do: %{
              "_type" => "rich_text",
              "body" => KilnCMS.Blocks.PortableText.from_html("<p>#{paragraph.()}</p>")
            }
          )
      ]
    end

  [%{"_type" => "heading", "text" => title, "level" => 1} | List.flatten(sections)]
end

IO.puts("Seeding taxonomy...")

categories =
  for i <- 1..12 do
    CMS.create_category!(%{name: "Category #{i}", slug: "category-#{i}"}, opts)
  end

tags =
  for i <- 1..40 do
    CMS.create_tag!(%{name: "Tag #{i}", slug: "tag-#{i}"}, opts)
  end

make = fn kind, i, publish? ->
  title = "#{sentence.(Enum.random(3..6)) |> String.trim_trailing(".")} #{i}"
  slug = "#{kind}-#{i}"

  attrs =
    %{
      title: title,
      slug: slug,
      seo_description: sentence.(14),
      category_id: Enum.random(categories).id,
      tag_ids: tags |> Enum.take_random(Enum.random(1..4)) |> Enum.map(& &1.id),
      blocks: blocks.(title)
    }

  record =
    case kind do
      :page -> CMS.create_page!(Map.delete(attrs, :tag_ids), opts)
      :post -> CMS.create_post!(Map.put(attrs, :excerpt, sentence.(20)), opts)
    end

  cond do
    not publish? -> record
    kind == :page -> CMS.publish_page!(record, %{}, opts)
    kind == :post -> CMS.publish_post!(record, %{}, opts)
  end
end

work =
  Enum.map(1..pages//1, &{:page, &1, true}) ++
    Enum.map(1..posts//1, &{:post, &1, true}) ++
    Enum.map(1..drafts//1, &{:post, posts + &1, false})

IO.puts("Seeding #{pages} pages, #{posts} posts and #{drafts} drafts...")
t0 = System.monotonic_time(:millisecond)

# The RNG state is per process, so each task seeds its own from the item —
# the corpus is the same whatever order the tasks run in.
work
|> Task.async_stream(
  fn {kind, i, publish?} = item ->
    :rand.seed(:exsss, {:erlang.phash2(item), i, seed})
    make.(kind, i, publish?)
  end,
  max_concurrency: 8,
  timeout: :infinity,
  ordered: false
)
|> Stream.with_index(1)
|> Enum.each(fn {{:ok, _}, n} -> if rem(n, 250) == 0, do: IO.puts("  #{n}/#{length(work)}") end)

IO.puts(
  "Seeded in #{div(System.monotonic_time(:millisecond) - t0, 1000)} s. Waiting for firing..."
)

pending = fn ->
  %{rows: [[n]]} =
    KilnCMS.Repo.query!(
      "SELECT count(*) FROM oban_jobs WHERE queue IN ('firing', 'search') AND state IN ('available','scheduled','executing','retryable')"
    )

  n
end

Stream.repeatedly(fn ->
  n = pending.()
  if n > 0, do: Process.sleep(2_000)
  n
end)
|> Stream.with_index()
|> Enum.find(fn {n, i} ->
  if rem(i, 5) == 0, do: IO.puts("  #{n} jobs pending")
  n == 0 or i > 900
end)

%{rows: [[artifacts]]} = KilnCMS.Repo.query!("SELECT count(*) FROM published_artifacts")
IO.puts("Done: #{artifacts} fired artifacts, #{pending.()} jobs still pending.")
