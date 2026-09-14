import Config

# A fragment of config/runtime.exs, evaluated by it inside its
# `config_env() == :prod` guard — nothing here applies in dev or test. It sits
# at the position this block always occupied; evaluation ORDER matters, see the
# header of config/runtime.exs before moving anything.

# ### Rich embed cards (#489)
#
# `OEMBED_ENABLED=true` lets Kiln fetch oEmbed metadata — title, author,
# thumbnail — for an embed block's URL, so it renders a card instead of a bare
# link. **Off by default, and it is egress**: enabling it means the server
# makes an outbound HTTPS request when an editor saves a document containing
# an embed whose URL a known provider claims.
#
# Requests only ever go to the curated provider endpoints in
# `KilnCMS.OEmbed.Provider` — never to a URL discovered from content — and
# through the pinned, size-capped `KilnCMS.SafeFetch`. Provider HTML is
# discarded; only scalars are stored.
#
#     OEMBED_ENABLED=true
#     OEMBED_PROVIDERS=YouTube,Vimeo   # optional: narrow the shipped list
#
# `OEMBED_PROVIDERS` can only *restrict* the built-in list, never extend it —
# adding a provider is a code change, because it is a host this server will
# dial. Names are the `name` field of each entry in `KilnCMS.OEmbed.Provider`.
if KilnCMS.Config.Env.flag("OEMBED_ENABLED", false) do
  providers =
    case System.get_env("OEMBED_PROVIDERS") do
      nil -> nil
      "" -> nil
      list -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :kiln_cms, KilnCMS.OEmbed, enabled: true, providers: providers
end
