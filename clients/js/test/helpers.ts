/**
 * Test seam: a recording fetch stub, the JS analogue of the Elixir client's
 * `Req.Test` plug. Every call records the method, URL, headers and JSON body
 * it saw, so tests assert on the request after the call.
 */

export interface RecordedCall {
  method: string;
  url: URL;
  headers: Record<string, string>;
  /** The request body, JSON-parsed; `undefined` when none was sent. */
  body: unknown;
}

export interface FetchStub {
  calls: RecordedCall[];
  fetchImpl: typeof globalThis.fetch;
}

export interface StubResponse {
  status?: number;
  body?: unknown;
  /** Raw (non-JSON) body text; `""` models an empty 204. */
  text?: string;
  headers?: Record<string, string>;
  /** Reject the fetch with this instead of answering (a network failure). */
  throws?: unknown;
}

/** Answer each call with the next response in `responses` (last one repeats). */
export function stubFetch(...responses: StubResponse[]): FetchStub {
  const calls: RecordedCall[] = [];
  let index = 0;

  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    calls.push({
      method: init?.method ?? "GET",
      url,
      headers: { ...((init?.headers ?? {}) as Record<string, string>) },
      body: typeof init?.body === "string" ? JSON.parse(init.body) : undefined,
    });

    const response = responses[Math.min(index, responses.length - 1)] ?? {};
    index += 1;

    if (response.throws !== undefined) throw response.throws;

    const status = response.status ?? 200;
    const body = response.text ?? JSON.stringify(response.body ?? {});
    // The Response constructor rejects a body on a null-body status (204).
    return new Response(status === 204 ? null : body, {
      status,
      headers: { "content-type": "application/json", ...response.headers },
    });
  }) as typeof globalThis.fetch;

  return { calls, fetchImpl };
}

export function emptyDoc(): { data: unknown[] } {
  return { data: [] };
}
