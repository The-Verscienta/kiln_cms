import Config

# A fragment of config/runtime.exs, evaluated by it inside its
# `config_env() == :prod` guard — nothing here applies in dev or test. It sits
# at the position this block always occupied; evaluation ORDER matters, see the
# header of config/runtime.exs before moving anything.

# OIDC SSO settings (#331) — only read when the strategy was compiled in
# (`config :kiln_cms, :sso_oidc, enabled: true`). OIDC_ISSUER is the
# provider's base URL (discovery at /.well-known/openid-configuration);
# OIDC_REDIRECT_URI is this site's callback base, e.g.
# "https://cms.example.com/auth".
if Application.get_env(:kiln_cms, :sso_oidc, [])[:enabled] do
  config :kiln_cms, :sso_oidc,
    enabled: true,
    client_id: System.get_env("OIDC_CLIENT_ID"),
    client_secret: System.get_env("OIDC_CLIENT_SECRET"),
    base_url: System.get_env("OIDC_ISSUER"),
    redirect_uri: System.get_env("OIDC_REDIRECT_URI")
end
