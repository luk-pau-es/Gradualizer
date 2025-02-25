%% @private
-module(constraints).

-export([empty/0,
         vars/1,
         upper/2,
         lower/2,
         combine/1, combine/2,
         combine_with/4,
         add_var/2,
         solve/3,
         append_values/3,
         has_upper_bound/2]).

-export_type([t/0,
              mapset/1,
              var/0]).

-include_lib("stdlib/include/assert.hrl").

-type type() :: gradualizer_type:abstract_type().

-include("constraints.hrl").

-type t() :: #constraints{}.
-type mapset(T) :: #{T => true}.
-type var() :: gradualizer_type:gr_type_var().

-spec empty() -> t().
empty() ->
    #constraints{}.

-spec vars(mapset(var())) -> #constraints{}.
vars(Vars) ->
    #constraints{ exist_vars = Vars }.

-spec add_var(var(), t()) -> t().
add_var(Var, Cs) ->
    Cs#constraints{ exist_vars = maps:put(Var, true, Cs#constraints.exist_vars) }.

-spec upper(var(), type()) -> t().
upper(Var, Ty) ->
    #constraints{ upper_bounds = #{ Var => [Ty] } }.

-spec lower(var(), type()) -> t().
lower(Var, Ty) ->
    #constraints{ lower_bounds = #{ Var => [Ty] } }.

-spec combine(t(), t()) -> t().
combine(C1, C2) ->
    combine([C1, C2]).

-spec combine([t()]) -> t().
combine([]) ->
    empty();
combine([Cs]) ->
    Cs;
combine([C1, C2 | Cs]) ->
    C = combine_with(C1, C2, fun append_values/3, fun append_values/3),
    combine([C | Cs]).

-spec combine_with(t(), t(), BoundsMergeF, BoundsMergeF) -> t() when
      BoundsMergeF :: fun((var(), [type()], [type()]) -> [type()]).
combine_with(C1, C2, MergeLBounds, MergeUBounds) ->
    LBounds = gradualizer_lib:merge_with(MergeLBounds,
                                         C1#constraints.lower_bounds,
                                         C2#constraints.lower_bounds),
    UBounds = gradualizer_lib:merge_with(MergeUBounds,
                                         C1#constraints.upper_bounds,
                                         C2#constraints.upper_bounds),
    EVars = maps:merge(C1#constraints.exist_vars, C2#constraints.exist_vars),
    #constraints{lower_bounds = LBounds,
                 upper_bounds = UBounds,
                 exist_vars = EVars}.

-spec solve(t(), erl_anno:anno(), typechecker:env()) -> R when
      R :: {t(), {#{var() => type()}, #{var() => type()}}}.
solve(Constraints, Anno, Env) ->
    ElimVars = Constraints#constraints.exist_vars,
    WorkList = [ {E, LB, UB} || E <- maps:keys(ElimVars),
                                LB <- maps:get(E, Constraints#constraints.lower_bounds, []),
                                UB <- maps:get(E, Constraints#constraints.upper_bounds, []) ],
    Cs = solve_loop(WorkList, maps:new(), Constraints, ElimVars, Anno, Env),
    GlbSubs = fun(_Var, Tys) ->
                      {Ty, _C} = typechecker:glb(Tys, Env),
                      % TODO: Don't throw away the constraints
                      Ty
              end,
    LubSubs = fun(_Var, Tys) ->
                      Ty = typechecker:lub(Tys, Env),
                      Ty
              end,
    % TODO: What if the substition contains occurrences of the variables we're eliminating
    % in the range of the substitution?
    Subst = { maps:map(GlbSubs, maps:with(maps:keys(ElimVars), Cs#constraints.upper_bounds)),
              maps:map(LubSubs, maps:with(maps:keys(ElimVars), Cs#constraints.lower_bounds)) },
    UBounds = maps:without(maps:keys(ElimVars), Cs#constraints.upper_bounds),
    LBounds = maps:without(maps:keys(ElimVars), Cs#constraints.lower_bounds),
    C = #constraints{upper_bounds = UBounds,
                     lower_bounds = LBounds,
                     exist_vars = maps:new()},
    {C, Subst}.

solve_loop([], _, Constraints, _, _, _) ->
    Constraints;
solve_loop([I = {E, LB, UB} | WL], Seen, Constraints0, ElimVars, Anno, Env) ->
    case maps:is_key(I, Seen) of
        true ->
            solve_loop(WL, Seen, Constraints0, ElimVars, Anno, Env);
        false ->
            Constraints1 = case typechecker:subtype(LB, UB, Env) of
                    false ->
                        throw({constraint_error, Anno, E, LB, UB});
                    {true, Cs} ->
                        Cs
                end,

            % Subtyping should not create new existential variables
            ?assert(Constraints1#constraints.exist_vars == #{}),

            ELowerBounds = maps:with(maps:keys(ElimVars), Constraints1#constraints.lower_bounds),
            EUpperBounds = maps:with(maps:keys(ElimVars), Constraints1#constraints.upper_bounds),

            LBounds = gradualizer_lib:merge_with(fun append_values/3,
                                                 Constraints0#constraints.lower_bounds,
                                                 Constraints1#constraints.lower_bounds),
            UBounds = gradualizer_lib:merge_with(fun append_values/3,
                                                 Constraints0#constraints.upper_bounds,
                                                 Constraints1#constraints.upper_bounds),
            Constraints2 = #constraints{lower_bounds = LBounds,
                                        upper_bounds = UBounds},
            NewWL = ([ {EVar, Lower, Upper}
                       || {EVar, Lowers} <- maps:to_list(ELowerBounds),
                          Lower <- Lowers,
                          Upper <- maps:get(EVar, Constraints2#constraints.upper_bounds, []) ] ++
                     [ {EVar, Lower, Upper}
                       || {EVar, Uppers} <- maps:to_list(EUpperBounds),
                          Upper <- Uppers,
                          Lower <- maps:get(EVar, Constraints2#constraints.lower_bounds, []) ] ++
                     WL),
            solve_loop(NewWL, maps:put(I, true, Seen), Constraints2, ElimVars, Anno, Env)
    end.

append_values(_, Xs, Ys) ->
    Xs ++ Ys.

has_upper_bound(Var, Cs) ->
    maps:is_key(Var, Cs#constraints.upper_bounds).
