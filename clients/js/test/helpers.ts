/**
 * Test seam: a recording fetch stub, the JS analogue of the Elixir client's
 * `Req.Test` plug. Every call records the URL and headers it saw, so tests
 * assert on path/params after the call.
 */

export interface RecordedCall {
  url: URL;
  headers: Record<string, string>;
}

export interface FetchStub {
  calls: RecordedCall[];
  fetchImpl: typeof globalThis.fetch;
}

export interface StubResponse {
  status?: number;
  body?: unknown;
  /** Raw (non-JSON) body text. */
  text?: string;
}

/** Answer each call with the next response in `responses` (last one repeats). */
export function stubFetch(...responses: StubResponse[]): FetchStub {
  const calls: RecordedCall[] = [];
  let index = 0;

  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    calls.push({ url, headers: { ...((init?.headers ?? {}) as Record<string, string>) } });

    const response = responses[Math.min(index, responses.length - 1)] ?? {};
    index += 1;

    const body = response.text ?? JSON.stringify(response.body ?? {});
    return new Response(body, {
      status: response.status ?? 200,
      headers: { "content-type": "application/json" },
    });
  }) as typeof globalThis.fetch;

  return { calls, fetchImpl };
}

export function emptyDoc(): { data: unknown[] } {
  return { data: [] };
}
