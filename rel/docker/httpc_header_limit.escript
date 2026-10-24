#!/usr/bin/env escript
%% Lifts `:httpc`'s default response-header limit, for the Docker builder
%% and for every CI job right after `erlef/setup-beam`.
%%
%% OTP 29.1.1 (inets 9.8) defaults httpc's `max_header_size` request option
%% to 10240 bytes, settable per request only, and GitHub's release-download
%% redirects send ~10.7 KB of headers. Mix tools that fetch GitHub release
%% assets through httpc without the option (tailwind, rustler_precompiled,
%% elixir_make) then fail with `{header_too_long, {max, 10240}}`.
%%
%% The OTP image ships no source, so this rewrites the default in
%% `request_options_defaults/0` from the installed beam's own debug_info and
%% recompiles it in place (or into $OUT): `nolimit`, as OTP 29.0 behaved.
%% It fails, rather than patching nothing, unless exactly one default is
%% found. The Dockerfile restores the stock beam before `mix release`; a CI
%% runner's OTP is thrown away with the job.
main(_) ->
    Beam = code:which(httpc),
    Out = case os:getenv("OUT") of false -> filename:dirname(Beam); D -> D end,
    {ok, {httpc, [{debug_info, {debug_info_v1, Backend, Meta}}]}} =
        beam_lib:chunks(Beam, [debug_info]),
    {ok, Forms} = Backend:debug_info(erlang_v1, httpc, Meta, []),
    {Patched, N} = lists:mapfoldl(fun patch_form/2, 0, Forms),
    N =:= 1 orelse halt_with("expected one max_header_size default in httpc, found ~p", [N]),
    {ok, httpc, Bin} = compile:forms(Patched, [debug_info, return_errors]),
    ok = file:write_file(filename:join(Out, "httpc.beam"), Bin),
    io:format("httpc: max_header_size default now nolimit (~s)~n", [Out]).

patch_form({function, _, request_options_defaults, 0, _} = F, N) -> rewrite(F, N);
patch_form(F, N) -> {F, N}.

rewrite({tuple, L, [{atom, _, max_header_size} = K, {integer, IL, 10240} | Rest]}, N) ->
    {{tuple, L, [K, {atom, IL, nolimit} | Rest]}, N + 1};
rewrite(T, N) when is_tuple(T) ->
    {Es, N1} = lists:mapfoldl(fun rewrite/2, N, tuple_to_list(T)),
    {list_to_tuple(Es), N1};
rewrite(L, N) when is_list(L) -> lists:mapfoldl(fun rewrite/2, N, L);
rewrite(X, N) -> {X, N}.

halt_with(Fmt, Args) -> io:format(standard_error, Fmt ++ "~n", Args), halt(1).
