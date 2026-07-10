Application.put_env(:kiln_client, :base_url, "http://kiln.test")

Application.put_env(:kiln_client, :req_options,
  plug: {Req.Test, KilnClient},
  retry: false
)

ExUnit.start()
