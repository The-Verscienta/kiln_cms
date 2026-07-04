// Minimal LiveView client for the showcase. Establishes the LiveSocket so the
// interactive bits (search-as-you-type, the contact form) work.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
