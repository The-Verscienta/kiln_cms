defmodule KilnCMSWeb.AdminAllowlistHTML do
  @moduledoc """
  The page `KilnCMSWeb.Plugs.AdminAllowlist` answers a refused request with
  (#2248): a standalone document, because the gate runs ahead of the session,
  the root layout and the CSP nonce the layout's scripts need. It loads the
  stylesheet and nothing else.
  """
  use KilnCMSWeb, :html

  embed_templates "admin_allowlist_html/*"
end
