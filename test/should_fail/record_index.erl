-module(record_index).

-export([f/0, g/0]).

-record(rec, { apa :: integer()}).

-spec f() -> boolean().
f() ->
    #rec.apa.

-spec g() -> 2.
g() ->
    #rec.apa.
