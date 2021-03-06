-module(erlog_make_server).
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : erlog_make_server.erl
%% Author  : Zachary Kessin
%% Purpose : Convert an erlog .pl file to an erlang gen_server

%% To export clauses use erl_export(clause/N) 
%% The prolog clause <<X>>/N will become the erlang function <<X>>/N, with the first 
%% Element of the erlang function being the pid of the gen server, and the last element 
%% of the prolog clause being the return value
%%TODO redo from core erlang to an AST setup



-compile(export_all).
-compile({parse_transform, seqbind}).
-include_lib("eunit/include/eunit.hrl").
-ifdef(TEST).

-compile(export_all).
-endif.


%% -spec(compile_buffer(atom(), iolist()) ->
%% 	     {ok, atom()}).


%    file:write_file("test1.ast", io_lib:format("% -*-Erlang -*- ~n~n~p~n",[AST@])),
%   file:write_file("test2.ast", io_lib:format("% -*-Erlang -*- ~n~n~p~n",[AST@])),

compile_file(File,Module) when is_atom(Module)->
    PL@                   = erlog:new(),
    {ok,PL@}             = PL@({consult, File}),
    {Exports,PL@}        = find_exports(PL@),
    ?debugVal(Exports),
    {ok, AST@}           = load_base_ast(),
    {ok, AST@}           = replace_filename(AST@, File),
    {ok, AST@}           = replace_module_name(AST@, Module),
    {ok, AST@}           = replace_start_link(AST@, Module),
    {ok, AST@}           = load_db_state(AST@, PL@),
    {ok, AST@}           = make_interface_functions(AST@, Exports),
    {ok, AST@}           = add_exports(AST@, Exports),
    {ok, AST@}           = make_handler_clauses(AST@,Exports),
    case compile:forms(AST@, [from_ast,debug_info,return]) of
        {ok, Module, Binary,Errors} ->
            file:write_file("errors", io_lib:format("% -*- Erlang -*- ~n~n~p~n",[Errors])),
            {module, Module}     = code:load_binary(Module, File, Binary),
            {ok, Module};
        E ->
            E
    end.


-spec(load_base_ast() -> {ok, term()}).
load_base_ast()->
    FileName   = code:priv_dir(erlog) ++ "/custom_server.erl",
    {ok, AST}  = epp:parse_file(FileName,[],[]),
    {ok, AST}.

replace_filename([FileLine|Rest] = _AST, PrologFile) ->
    {attribute,_, file, {_, _}} = FileLine,
    {ok,[{attribute,1, file, {PrologFile, 1}}|Rest]}.

replace_module_name([FirstLine,ModuleLine|Rest], PLModule) ->
    {attribute,_, module,_} = ModuleLine,
    {ok,[FirstLine,
         {attribute,3,module, PLModule}| Rest]}.

replace_start_link(AST, PLModule) ->
    AST1 = lists:keyreplace(start_link, 3, AST, 
                            {function,31,start_link,0,
                             [{clause,31,[],[],
                               [{call,32,
                                 {remote,32,{atom,32,gen_server},{atom,32,start_link}},
                                 [{atom,32,PLModule},{nil,32},{nil,32}]}]}]}),
    {ok, AST1}.
                         
print_exports(AST) ->   
    Exports = lists:filter(fun({attribute,_,export,_}) -> true;
                              (_)  -> false
                           end, AST),
    Exports.
        
add_exports(AST,PLExports) ->  
    print_exports(AST),
    AST1 = lists:map(fun({attribute,Line,export,[]}) ->
                                   {attribute,Line,export,PLExports};
                              (X) -> X
                           end,AST),
    print_exports(AST1),
    {ok,AST1}.

make_supervisor_childspec(AST,PLModule) ->
    Line = 23,
    AST1 = lists:keyreplace(make_supervisor_childspec,3, AST,
                             {function,Line,make_supervisor_childspec,0,
                              [{clause,Line,[],[],
                                [{tuple,21,
                                  [{atom,21,ok},
                                   {tuple,21,
                                    [{atom,21,PLModule},
                                     {tuple,22,
                                      [{atom,22,PLModule},
                                       {atom,22,start_link},
                                       {nil,22}]},
                                     {atom,23,permanent},
                                     {integer,23,100},
                                     {atom,23,worker},
                                     {cons,23,{atom,23,PLModule},{nil,23}}]}]}]}]}),

    {ok,AST1}.
    

find_exports(PL) ->
    PL@ = PL,
    {ok, PL@}	= PL@({consult, "src/erlog_make_server.pl"}),
    case PL@({prove, {find_exports, {'Exports'}}}) of 
	{{succeed, Res},PL@} ->
	    Exports = [{Fun, Arity } || {'/', Fun,Arity} <- proplists:get_value('Exports', Res)],
	    
	    {Exports,PL@};
	fail ->
	   {[], PL@}
    end.


load_db_state(AST, E0) ->
    {{ok,DB},_E2} = E0(get_db),
    AbstractDB    = abstract(DB),
    AST1          = lists:keyreplace(db_state, 3, AST, 
                             {function,26,db_state,0,
                              [{clause,26,[],[],[{tuple,27,[{atom,27,ok},AbstractDB]}]}]}),
    {ok, AST1}. 

make_handler_clauses(AST, Exports) ->
    NewClauses = [base_fn_clause(Predicate,Arity) ||{Predicate, Arity} <- Exports],
    AST1       = lists:keyreplace(handle_call,3, AST,
                                  {function, 39, handle_call, 3,
                                   NewClauses}),
    {ok,AST1}.


make_interface_function({Function, Arity}) when is_atom(Function) and is_integer(Arity)->
    Line = 31,
    Params = make_param_list(Arity - 1, Line),
    {function,Line,Function, Arity ,
     [{clause,Line,
       [{var,Line,'Pid'}|Params],
       [],
       [{call,Line,
         {remote,Line,{atom,30,gen_server},{atom,30,call}},
         [{var,Line,'Pid'},
          {tuple,Line,
           [{atom,Line,prove},
            {tuple, Line,
             [{atom, Line, Function}| Params]
            }]
          }]}]}]}.

insert_interface_inner([],_, Acc) ->
    {ok,Acc};
insert_interface_inner([{function,_, interface,_,_}|Rest], [], Acc) ->
    insert_interface_inner(Rest,[], Acc);
insert_interface_inner(AST = [{function,_, interface,_,_}|_], [E|ERest], Acc) ->
    insert_interface_inner(AST,ERest, Acc ++ [E]);
insert_interface_inner([F|Rest], E, Acc) ->
    insert_interface_inner(Rest, E, Acc ++ [F]).
    

insert_interface(AST, Exports) ->
    insert_interface_inner(AST,Exports,[]).

make_interface_functions(AST, Exports) ->
    InterfaceFns = [make_interface_function(Fn)|| Fn <-Exports],
    insert_interface(AST, InterfaceFns).



make_param_list(ParamCount,Line) when is_integer(ParamCount)->   
    PList     = lists:seq(65,65 + ParamCount -1),
    PAtomList = [list_to_atom([P]) ||P <-PList],
    [{var, Line, PAtom}|| PAtom <- PAtomList].

base_fn_clause(Predicate, ParamCount ) when is_atom(Predicate) andalso is_integer(ParamCount) ->
    ParamList = [{atom,46,Predicate}] ++ make_param_list( ParamCount - 1,46),
    {clause,46,
     [{match,46,
       {var,46,'_Prove'},
       {tuple,46,
        [{atom,46,prove},
         {tuple,46,
          ParamList
         }]}},
      {var,46,'_From'},
      {var,46,'Erlog'}],
     [],
         [{'case',47,
           {call,47,
            {var,47,'Erlog'},
            [{tuple,47,
              [{atom,47,prove},
               {tuple,47,
                ParamList ++ [{tuple,47,[{atom,47,'X'}]
                              }]}]}]},
           [{clause,48,
             [{tuple,48,
               [{tuple,48,
                 [{atom,48,succeed},
                  {cons,48,
                   {tuple,48,
                    [{atom,48,'X'},{var,48,'RetVal'}]},
                   {nil,48}}]},
                {var,48,'Erlog1'}]}],
             [],
             [{tuple,49,
               [{atom,49,reply},
                {tuple,49,[{atom,49,'ok'},
                           {var,49,'RetVal'}]},
                {var,49,'Erlog1'}]}]},
            {clause,50,
             [{atom,50,fail}],
             [],
             [{tuple,51,
               [{atom,51,reply},
                {atom,51,fail},
                {var,51,'Erlog'}]
              }]}]}]}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Taken from ulf wiger's parse_trans module

%% abstract/1 - modified from erl_eval:abstract/1:
-type abstract_expr() :: term().
-spec abstract(Data) -> AbsTerm when
      Data :: term(),
      AbsTerm :: abstract_expr().
abstract(T) when is_function(T) ->
    case erlang:fun_info(T, module) of
	{module, erl_eval} ->
	    case erl_eval:fun_data(T) of
		{fun_data, _Imports, Clauses} ->
		    {'fun', 0, {clauses, Clauses}};
		false ->
		    erlang:error(function_clause)  % mimicking erl_parse:abstract(T)
	    end;
	_ ->
	    erlang:error(function_clause)
    end;
abstract(T) when is_integer(T) -> {integer,0,T};
abstract(T) when is_float(T) -> {float,0,T};
abstract(T) when is_atom(T) -> {atom,0,T};
abstract([]) -> {nil,0};
abstract(B) when is_bitstring(B) ->
    {bin, 0, [abstract_byte(Byte, 0) || Byte <- bitstring_to_list(B)]};
abstract([C|T]) when is_integer(C), 0 =< C, C < 256 ->
    abstract_string(T, [C]);
abstract([H|T]) ->
    {cons,0,abstract(H),abstract(T)};
abstract(Tuple) when is_tuple(Tuple) ->
    {tuple,0,abstract_list(tuple_to_list(Tuple))}.

abstract_string([C|T], String) when is_integer(C), 0 =< C, C < 256 ->
    abstract_string(T, [C|String]);
abstract_string([], String) ->
    {string, 0, lists:reverse(String)};
abstract_string(T, String) ->
    not_string(String, abstract(T)).

not_string([C|T], Result) ->
    not_string(T, {cons, 0, {integer, 0, C}, Result});
not_string([], Result) ->
    Result.

abstract_list([H|T]) ->
    [abstract(H)|abstract_list(T)];
abstract_list([]) ->
    [].

abstract_byte(Byte, Line) when is_integer(Byte) ->
    {bin_element, Line, {integer, Line, Byte}, default, default};
abstract_byte(Bits, Line) ->
    Sz = bit_size(Bits),
    <<Val:Sz>> = Bits,
    {bin_element, Line, {integer, Line, Val}, {integer, Line, Sz}, default}.


