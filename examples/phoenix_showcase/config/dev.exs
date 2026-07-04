import Config

# The showcase runs on :4002 so it can sit alongside KilnCMS on :4000.
config :showcase, ShowcaseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "uPS1qUPGe14nxP7McNx5CqKAYGyhLjwwbvQQ/lIVnBFs0n+nfiG1KhEz7GLNTVzU",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:showcase, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/showcase_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :debug_heex_annotations, true

config :logger, :console, format: "[$level] $message\n"
