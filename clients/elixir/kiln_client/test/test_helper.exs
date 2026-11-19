Application.put_env(:kiln_client, :base_url, "http://kiln.test")

# No `retry: false` here: the client turns Req's retry off itself (#2730),
# and the tests count requests to prove it.
Application.put_env(:kiln_client, :req_options, plug: {Req.Test, KilnClient})

ExUnit.start()
