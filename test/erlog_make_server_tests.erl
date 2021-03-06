-module(erlog_make_server_tests).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).


pl_arity() ->
    choose(2,4).

clause_name() ->
    elements(['edge','connected', ancestor, descendent,path, travel]).

ret_val() ->
    elements(['Path','X','Y','Z',boolean]).

erl_export() ->
    {erl_export, {'/', clause_name(), pl_arity()}, return, ret_val()}.

assert_functions() ->
    Functions   = po_set:module_info(functions),

    ?assert(lists:member({db_state,0},                   Functions)),
    ?assert(lists:member({make_supervisor_childspec, 0}, Functions)),
    ?assert(lists:member({start_link, 0},                Functions)),
    ?assert(lists:member({init,1} ,                      Functions)),
    ?assert(lists:member({handle_call, 3},               Functions)),
    ?assert(lists:member({handle_cast, 2},               Functions)),
    ?assert(lists:member({handle_info, 2},               Functions)),
    ?assert(lists:member({path, 3},                      Functions)),
    
    true.

prop_compile_file() ->
    {ok,po_set} = erlog_make_server:compile_file("priv/po_set.pl", po_set),
    true        = assert_functions(),
    {ok, Pid}   = po_set:start_link(),
    ?assert(is_process_alive(Pid)),
    {ok,Path}   = po_set:path(Pid,a,f),
    ?assertEqual([a,b,f], Path),
    true.

prop_find_exported_clauses() ->
    ?FORALL(Clauses, non_empty(list(erl_export())),
	    begin
		PL0             = erlog:new(),
                PL2             = add_export_clauses(Clauses, PL0),
		{Exports,_PL3}  = erlog_make_server:find_exports(PL2),
                ?assertEqual(length(Exports),length(Clauses)),
		?assert(lists:all(fun(_Export = {Fun, Arity}) ->
					  lists:keymember({'/',Fun, Arity}, 2, Clauses)
			      end, Exports)),
		true
	    end).



add_export_clauses(Clauses, PL0) ->
    lists:foldl(fun(CL,PL) ->
			{{succeed, _},PL1} = PL({prove,{asserta, CL}}),
			PL1
                end, PL0, Clauses).

purge(ModName) ->
                                %% Purge any results of old runs
                            code:purge(ModName),
                            code:delete(ModName).
prop_load_base_ast()->
    application:start(erlog),
    {ok, AST}  = erlog_make_server:load_base_ast(),
    lists:all(fun(F) ->
                      is_tuple(F)
              end, AST).
erlog_modules() ->
    ['fleck',
     'et',
     't1',
     'trees',
     'test',
     'family',
     'homer',
     'timer',
     'edges_pl',
     'po_set',
     'erlog_make_server',
     'example_dcg',
     'graph',
     'finite_dcg',
     'po_set'].
    
erlog_files() ->
    ["examples/fleck.pl",
     "examples/et.pl",
     "examples/t1.pl",
     "examples/trees.pl",
     "examples/test.pl",
     "examples/family.pl",
     "examples/homer.pl",
     "examples/timer.pl",
     "priv/edges_pl.pl",
     "priv/po_set.pl",
     "src/erlog_make_server.pl",
     "example_dcg.pl",
     "test/graph.pl",
     "test/finite_dcg.pl",
     "test/po_set.pl"].

prop_replace_file() ->
    application:start(erlog),
    {ok, AST}  = erlog_make_server:load_base_ast(),
    ?FORALL(PrologFile,
            elements(erlog_files()),
            begin
                {ok, AST1} = erlog_make_server:replace_filename(AST,PrologFile),
                [{attribute,1,file, {PrologFile,1}}|_] = AST1,
                {ok, _,_} = compile:forms(AST1, [from_ast,debug_info]),
                true
            end).

prop_replace_module_name() ->
    application:start(erlog),
    {ok, [ASTHead,_|Rest] = AST}  = erlog_make_server:load_base_ast(),
    ?FORALL(PrologModule,
            elements(erlog_modules()),
            begin

                {ok, [ASTHead,NewModuleLine|Rest] = AST1} = erlog_make_server:replace_module_name(AST, PrologModule),
                ?assertEqual({attribute,3,module,PrologModule}, NewModuleLine),
                {ok, _,_} = compile:forms(AST1, [from_ast,debug_info]),
                true
            end).

%%TODO, compile module and check that this is a valid child spec

prop_set_child_spec() ->
    application:start(erlog),
    {ok, AST}  = erlog_make_server:load_base_ast(),
    ?FORALL(PrologModule,
            elements(erlog_modules()),
            begin
                {ok, AST1}                 = erlog_make_server:make_supervisor_childspec(AST,PrologModule),
                ?assertEqual(length(AST1),length(AST)),

                _ChildSpec                 = lists:keyfind(make_supervisor_childspec,3,AST1),

                {ok,custom_server, Binary} = compile:forms(AST1,[]),
                code:load_binary(custom_server, "custom_server.erl",Binary),
                {ok,ChildSpec}             = custom_server:make_supervisor_childspec(),
                ok                         = supervisor:check_childspecs([ChildSpec]),
                true
            end).



exports(AST) ->
    lists:flatten(lists:map(
                    fun({attribute,_,export,Exports}) ->
                            Exports
                    end,
                    lists:filter(fun({attribute,_,export, _Exports}) ->
                                       true;
                                         (_) ->
                                       false
                                   end,AST))).

prop_add_prolog_export_clauses() ->
    application:start(erlog),
    {ok,  AST}  = erlog_make_server:load_base_ast(),
    BaseExports = exports(AST), 
    ?FORALL({_ModName, Clauses},
	    {'edges_pl',
	     non_empty(list(erl_export()))},
	    ?IMPLIES(length(Clauses) =:= length(lists:usort(Clauses)),
                     ?WHENFAIL(
                        begin
                            ?debugVal(Clauses)
                        end, 
                        begin
                            PL0             = erlog:new(),
                            PL2             = add_export_clauses(Clauses, PL0),
                            {Exports,_PL3}  = erlog_make_server:find_exports(PL2),
                            {ok, AST1}   = erlog_make_server:add_exports(AST,Exports),
                            ?assertEqual(length(AST1), length(AST)),
                            NewExports = exports(AST1),
                            ?assertEqual(NewExports, BaseExports++Exports),
                            true
                        end))).
    

prop_db_state() ->
    
    application:start(erlog),
    PL                         = erlog:new(),
    {ok, PL1}                  = PL({consult, "priv/po_set.pl"}),
    {ok,  AST}                 = erlog_make_server:load_base_ast(),
    {ok,  AST1}                = erlog_make_server:load_db_state(AST, PL1),
    {ok,custom_server, Binary} = compile:forms(AST1,[]),
    {module, _}                = code:load_binary(custom_server, "custom_server.erl",Binary),
    {ok, _DBState}             = custom_server:db_state(),
    {ok, E1}                   = custom_server:init([]),
    case E1({prove, {path, a, f, {'Path'}}}) of
        {{succeed, [{'Path', _Path}]},_E2} ->
            true;
        fail ->
            false
    end.

prop_make_param_list() ->
    ?FORALL({ParamCount},
            {
             choose(2,10)},
            begin
                Vars = erlog_make_server:make_param_list( ParamCount, 66),

                ?assertEqual(ParamCount, length(Vars)),
                ?assertEqual(Vars, lists:usort(Vars)),
                lists:all(fun({var,Line, PAtom}) when is_integer(Line) andalso is_atom(PAtom) ->
                                  true
                          end, Vars)

            end).


set_node() ->
    elements([a,b,c,d,e,f]).
edge() ->
    {edge, set_node(), set_node()}.
edges() ->
    non_empty(list(edge())).

%% prop_supervisor_spec() ->
%%     erlog_make_server_tests_sup:start_link(),
%%     ModName		= edges_pl,
%%     {ok,ModName}	= erlog_make_server:compile_file("priv/edges_pl.pl",ModName),
%%     R			= ModName:make_child_spec(make_ref()),
%%     ok			= supervisor:check_childspecs([R]),
%%     {ok,Pid}		= supervisor:start_child(erlog_make_server_tests_sup, R),
%%     is_process_alive(Pid).
    
    


%% prop_run_pl() ->
%%        ?FORALL({ModName, Edges},
%% 	    {'edges_pl',edges() },
%% 	    begin
%% 		code:purge(ModName),
%% 		code:delete(ModName),
%% 		{ok,ModName}	= erlog_make_server:compile_file("priv/edges_pl.pl",ModName),
%% 		Exports		= ModName:module_info(exports),

%% 		?assert(lists:member({add_edge, 3}, Exports)),

%% 		true            = lists:member({make_child_spec, 1}, Exports),
%% 		{ok,Pid}        = erlog_custom_server:start_link("priv/edges_pl.pl"),
%% 		true            = is_process_alive(Pid),
%% 		lists:foreach(fun({edge,S,F}) ->
%% 				      _R = ModName:add_edge(Pid,S,F),
				      
%% 				      true
%% 			  end, Edges),
%% 		unlink(Pid),
%% 		is_process_alive(Pid)
%% 	    end).
