%%----------------------------------------------------------------
%% Copyright (c) 2020 Faceplate
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%----------------------------------------------------------------

-module(ecomet_query).

-include("ecomet.hrl").

-record(compiled_query,{conditions,map,reduce}).
-record(field,{alias,value}).
-record(get,{value,args,aggregate}).

-export([
  run/1,
  parse/1,
  run_statements/1,
  get/3,get/4,
  subscribe/4,
  set/3,
  delete/2,delete/3,
  execute/2,execute/3,
  compile/3,compile/4,
  system/3
]).

%%====================================================================
%%		Parser
%%====================================================================
-export([
  macros/2,
  wrap_transactions/1
]).

%%====================================================================
%%		QL functions
%%====================================================================
-export([
  concat/1,
  string/1
]).

%%====================================================================
%%		Test API
%%====================================================================
-ifdef(TEST).

-export([
  get_alias/2,
  read_fun/1,
  read_map/1,
  is_aggregate/1,
  read_up/1,
  insert_to_group/4,
  sort_groups/2,
  merge_trees/4,
  reorder_fields/3,
  grouped_resut/4,
  groups_page/2,
  compare_rows/3,
  sort_leafs/3,
  compile_map_reduce/3
]).

-endif.

%%=====================================================================
%%
%%			API
%%
%%=====================================================================
run(Statements)->
  ParsedStatements=parse(Statements),
  run_statements(ParsedStatements).

parse(Statements) when is_binary(Statements)->
  parse(unicode:characters_to_list(Statements));
parse(Statements) when is_list(Statements)->
  case ecomet_ql_lexer:string(Statements) of
    {ok,Tokens,_}->
      case ecomet_ql_parser:parse(Tokens) of
        {ok,StatementsList}->wrap_transactions(StatementsList);
        {error,Error}->?ERROR(Error)
      end;
    Error->?ERROR(Error)
  end;
parse(_Statements)->?ERROR(invalid_string).

run_statements(Statements)->
  run_statements(Statements,[]).
run_statements([S|Rest],Acc)->
  run_statement(Rest,safe_statement(S,Acc));
run_statements([],Acc)->
  case Acc of
    [Single]->Single;
    Multiple->lists:reverse(Multiple)
  end.

safe_statement(Statement,Acc)->
  try
    run_statement(Statement,Acc)
  catch
    _:Error ->[{error,Error}|Acc]
  end.

run_statement({get,Fields,Condition,Params},Acc)->
  DBs=ecomet_db:get_databases(),
  [get(DBs,Fields,Condition,Params)|Acc];
run_statement({set,Fields,Condition,Params},Acc)->
  DBs=ecomet_db:get_databases(),
  [set(DBs,Fields,Condition,Params)|Acc];
run_statement({insert,Fields},Acc)->
  Object=ecomet_object:create(Fields),
  [ecomet_object:get_oid(Object)|Acc];
run_statement({delete,Condition,Params},Acc)->
  DBs=ecomet_db:get_databases(),
  [delete(DBs,Condition,Params)|Acc];
run_statement(transaction_start,Acc)->
  ecomet_transaction:start(),
  [ok|Acc];
run_statement(transaction_commit,Acc)->
  ecomet_transaction:commit(),
  [ok|Acc];
run_statement(transaction_rollback,Acc)->
  ecomet_transaction:rollback(),
  [ok|Acc];
run_statement({transaction,Statements},Acc)->
  case ecomet_transaction:internal(fun()->
    lists:foldl(fun run_statement/2,Acc,Statements)
  end) of
    {ok,Results}->Results;
    {error,Error}->
      Results=[{error,Error}||_<-lists:seq(1,length(Statements))],
      Results++Acc
  end.

%%=====================================================================
%%	GET
%%=====================================================================
% Fields = [
%   <<"field1">>,                   - name of field
%   {<<"alias">>,<<"field2">>},     - alias for field
%   {fun,[Fields]},                 - fun on fields
%   {<<"alias">>,{fun,[Fields]}}    - alias for fun
% ]
get(DBs,Fields,Conditions)->
  get(DBs,Fields,Conditions,[]).
get(DBs,Fields,Conditions,Params)->
  CompiledQuery=compile(get,Fields,Conditions,Params),
  Union=proplists:get_value(union,Params,{'OR',ecomet_resultset:new()}),
  execute(CompiledQuery,DBs,Union).

system(DBs,Fields,Conditions)->
  Conditions1=ecomet_resultset:prepare(Conditions),
  {Map,Reduce}=compile_map_reduce(get,Fields,[]),
  Compiled = #compiled_query{
    conditions = Conditions1,
    map = Map,
    reduce = Reduce
  },
  execute(Compiled,DBs,{'OR',ecomet_resultset:new()}).

%%=====================================================================
%%	SUBSCRIBE
%%=====================================================================
% Fields = [
%   <<"field1">>,                   - name of field
%   {<<"alias">>,<<"field2">>},     - alias for field
%   {fun,[Fields]},                 - fun on fields
%   {<<"alias">>,{fun,[Fields]}}    - alias for fun
% ]
subscribe(ID,DBs,Fields,Conditions)->

  %----------Compile fields---------------------------
  % Per object reading plan
  ReadMap=read_map(Fields),
  % Fields to read from storage
  DependFields=
    maps:fold(fun(_,#field{value = #get{args = Args}},Acc)->
      ordsets:union(Args,Acc)
    end,[],ReadMap),
  % Compile the function for building query fields
  Read=
    fun(Changed,Object)->
      maps:fold(fun(ID,#field{value = #get{args = Args,value=Fun}},Acc)->
        case ordsets:intersection(Changed,Args) of
          []->
            % If the changes are not among the function arguments list the the field is not affected
            Acc;
          _->
            % The value has to be recalculated
            Acc#{ID=>Fun(Object)}
        end
      end,#{},ReadMap)
    end,

  %----------Prepare conditions----------------------
  {Tags, CheckFun}=ecomet_resultset:prepare_subscribe(Conditions),

  %--------Register the subscription-----------------
  ok = ecomet_subscription:add(#{
    id=>ID,
    databases=>DBs,
    fields=>DependFields,
    read=>Read,
    tags=>Tags,
    conditions=>Conditions,
    check=>CheckFun
  }).

%%=====================================================================
%%	SET
%%=====================================================================
% Fields = [
%   {<<"field1">>,Value},           - name of field
%   {<<"field2">>,{fun,[Fields]}}   - value as fun
% ]
set(DBs,Fields,Conditions)->
  set(DBs,Fields,Conditions,[]).
set(DBs,Fields,Conditions,Params)->
  CompiledQuery=compile(set,Fields,Conditions,Params),
  Union=proplists:get_value(union,Params,{'OR',ecomet_resultset:new()}),
  execute(CompiledQuery,DBs,Union).
%%=====================================================================
%%	DELETE
%%=====================================================================
delete(DBs,Conditions)->
  delete(DBs,Conditions,[]).
delete(DBs,Conditions,Params)->
  CompiledQuery=compile(delete,none,Conditions,Params),
  Union=proplists:get_value(union,Params,{'OR',ecomet_resultset:new()}),
  execute(CompiledQuery,DBs,Union).
%%=====================================================================
%%	COMPILE
%%=====================================================================
compile(Type,Fields,Conditions)->compile(Type,Fields,Conditions,[]).
compile(Type,Fields,Conditions,Params)->
  Conditions1=set_rights(Type,Conditions),
  Conditions2=ecomet_resultset:prepare(Conditions1),
  {Map,Reduce}=compile_map_reduce(Type,Fields,Params),
  #compiled_query{
    conditions = Conditions2,
    map = Map,
    reduce = Reduce
  }.

%%=====================================================================
%%	EXECUTE
%%=====================================================================
execute(CompiledQuery,DBs)->
  execute(CompiledQuery,DBs,{'OR',ecomet_resultset:new()}).
execute(#compiled_query{conditions = Conditions,map = Map,reduce = Reduce},DBs,Union)->
  ecomet_resultset:execute(DBs,Conditions,Map,Reduce,Union).

%%-------------GET------------------------------------------------
%% Search params:
%%	- {page,{Number,ItemsPerPage}} - Paginating. Return only items for defined page
%%	- {order,[{Field1,Order},{Field2,Order}]} - Sorting results
%%	- {group,[Field1,Field2]} - Grouping results
%%	- {lock,none|read|write} - lock level on objects
%%-----------HIGHLY OPTIMIZED (no objects open)-------------------
%% CASE 1. Raw result requested
compile_map_reduce(get,rs,_Params)->
  {fun(RS)->RS	end,fun(Results)->lists:append(Results) end};
%% CASE 2. Only objects count needed
compile_map_reduce(get,[count],_Params)->
  Map=
    fun(RS)->
      ecomet_resultset:count(RS)
    end,
  Reduce=fun lists:sum/1,
  {Map,Reduce};
%% CASE 3. Only objects oid needed
compile_map_reduce(get,[<<".oid">>],Params)->
  Page=proplists:get_value(page,Params,none),
  Map=fun(RS)->RS	end,
  Order=
    case proplists:get_value(order,Params,[]) of
      [{<<".oid">>,'DESC'}|_]->foldl;
      _->foldr
    end,
  Reduce=
    if
      Page=:=none ->
        fun(Results)->ecomet_resultset:fold(fun(OID,Acc)->[OID|Acc] end,[],lists:append(Results),Order,none) end;
      true ->
        Traverse=
          if
            Order=:=foldl ->foldr;
            true -> foldl
          end,
        fun(Results)->
          {Count,Res}=ecomet_resultset:fold(fun(OID,Acc)->[OID|Acc] end,[],lists:append(Results),Traverse,Page) ,
          {Count,lists:reverse(Res)}
        end
    end,
  {Map,Reduce};
%%-----------COMMON VARIANTS. Objects are opened for reading------------
compile_map_reduce(get,Fields,Params)->
  ReadMap=read_map(Fields),
  AliasMap=maps:fold(fun(ID,#field{alias=Alias},Acc)->Acc#{Alias=>ID} end,#{},ReadMap),

  % All columns to order by
  OrderAll=[{maps:get(Name,AliasMap),OrderType}||{Name,OrderType}<-proplists:get_value(order,Params,[])],

  %---Columns to group by---
  % Put sort order if defined.
  % 'group' has priority over 'order':
  % 	1. rows are grouped,
  % 	2. groups are sorted
  % 	3. rows are sorted within groups.
  Group=
    lists:map(fun(Name)->
      ID=maps:get(Name,AliasMap),
      % Check no grouping by aggregated fields requested
      case maps:get(ID,ReadMap) of
        #field{value = #get{ aggregate=undefined}}->ok;
        #field{alias=InvalidGroup}->erlang:error({group_by_aggregated,InvalidGroup})
      end,
      SortOrder=proplists:get_value(ID,OrderAll,none),
      {ID,SortOrder}
    end,proplists:get_value(group,Params,[])),
  % Sorting within groups
  Order=
    case {Group,proplists:get_value(order,Params,[])} of
      % No sorting, no grouping. Results from old to new
      {[],[]}->foldr;
      % OPTIMIZED. Sorting by oid, no grouping. No real sorting performed, task is solved while traversing search results
      {[],[{<<".oid">>,'DESC'}|_]}->foldl;
      {[],[{<<".oid">>,'ASC'}|_]}->foldr;
      % Common case
      _->OrderAll--Group
    end,
  % Define type of query (aggregated/search), check no mix of plain and aggregated fields
  Aggregate=is_aggregate(maps:without([ID||{ID,_}<-Group],ReadMap)),
  % Paginating
  Page=proplists:get_value(page,Params,none),
  % Fun to read object fields from storage, default lock is dirty (fastest)
  ReadUp=read_up(proplists:get_value(lock,Params,dirty)),

  % Build Map/Reduce plan
  {Map,Reduce}=map_reduce_plan(#{
    read=>ReadMap,
    aggregate=>Aggregate,
    group=>Group,
    order=>Order,
    page=>Page,
    read_up=>ReadUp
  }),

  GroupFields=[ID||{ID,_}<-Group],
  GroupHeader=[begin #field{alias=Alias}=maps:get(ID,ReadMap), Alias end||ID<-GroupFields],
  Header=GroupHeader++[Alias||{_,#field{alias=Alias}}<-lists:usort(maps:to_list(maps:without(GroupFields,ReadMap)))],

  ReduceFun=
    if
      Page=:=none ->fun(Result)->{Header,Reduce(Result)} end ;
      true -> fun(Result)->{Count,Rows}=Reduce(Result), {Count,{Header,Rows}} end
    end,
  {Map,ReduceFun};

compile_map_reduce(set,Fields,Params)->
  Updates=
    [case Value of
       {Fun,ArgList} when is_function(Fun,1) and is_list(ArgList)->
         {Field,read_fun(Value)};
       _->{Field,Value}
     end || {Field,Value} <- maps:to_list(Fields) ],
  % Fun to read object fields from storage, default lock is none (check rights is performed)
  ReadUp=read_up(proplists:get_value(lock,Params,none)),
  ReadFields=ordsets:union([Args||{_,#get{args = Args}}<-Updates]),
  Map=
    fun(RS)->
      ecomet_resultset:foldr(fun(OID,Acc)->
        ObjectMap=ReadUp(OID,ReadFields),
        NewValues=
          [{Name,
            case Value of
              #get{value = Fun}->Fun(ObjectMap);
              _->Value
            end}||{Name,Value}<-Updates],
        ecomet_object:edit(maps:get(object,ObjectMap),maps:from_list(NewValues)),
        Acc+1
      end,0,RS)
    end,
  Reduce=fun lists:sum/1,
  {Map,Reduce};

compile_map_reduce(delete,none,Params)->
  % Fun to read object fields from storage, default lock is none (check rights is performed)
  ReadUp=read_up(proplists:get_value(lock,Params,none)),
  Map=
    fun(RS)->
      ecomet_resultset:foldr(fun(OID,Acc)->
        #{object:=Object}=ReadUp(OID,[]),
        ecomet_object:delete(Object),
        Acc+1
      end,0,RS)
    end,
  Reduce=fun lists:sum/1,
  {Map,Reduce}.
%%-----------------------------------------------------------------
%%	MAP/REDUCE PLANNING
%%-----------------------------------------------------------------
%%--------SEARCH QUERIES (Not aggregated)--------------------------
%% CASE 1. Simple search - no grouping, no sorting
map_reduce_plan(#{aggregate:=false,group:=[],order:=Order}=Params) when (Order=:=foldl) or (Order=:=foldr)->
  % Per row reading plan
  Read=maps:get(read,Params),
  % Fields to read from storage
  StorageFields=
    maps:fold(fun(_,#field{value = #get{args = Args}},Acc)->
      ordsets:union(Args,Acc)
    end,[],Read),
  RowFieldsFunList=
    [field_read_fun(maps:get(ID,Read))||ID<-ordsets:from_list(maps:keys(Read))],
  % Fun for reading from storage
  ReadUp=maps:get(read_up,Params),
  % Fun to build per row results
  BuildRowFun=
    fun(OID)->
      Object=ReadUp(OID,StorageFields),
      [F(Object)||F<-RowFieldsFunList]
    end,
  % Build result
  case maps:get(page,Params) of
    % NO PAGING
    none->
      MapFun=
        fun(RS)->
          ecomet_resultset:fold(fun(OID,Acc)->[BuildRowFun(OID)|Acc] end,[],RS,Order,none)
        end,
      ReduceFun=
        fun([Init|Results])->
          % Traversing results from the right to optimize ++ operator (assume that Rows < Acc ).
          % If only database requested, no ++ is performed
          lists:foldr(fun({_,Rows},Acc)->Rows++Acc end,Init,Results)
        end,
      {MapFun,ReduceFun};
    % PAGE. Optimized case. Local worker sends raw resultSet, manager build rows itself only for requested page
    Page->
      MapFun=fun(RS)->RS end,
      Traverse=
        if
          Order=:=foldl -> foldr;
          true -> foldl
        end,
      ReduceFun=
        fun(Results)->
          {Count,Res}=ecomet_resultset:fold(fun(OID,Acc)->[BuildRowFun(OID)|Acc] end,[],lists:append(Results),Traverse,Page),
          {Count,lists:reverse(Res)}
        end,
      {MapFun,ReduceFun}
  end;
%% CASE 2. Grouping and/or sorting
map_reduce_plan(#{aggregate:=false}=Params)->
  % Per row reading plan
  Read=maps:get(read,Params),
  % Grouping/Sorting
  Grouping=maps:get(group,Params),
  Sorting=maps:get(order,Params),
  % Paginate result
  Page=maps:get(page,Params),

  % All fields to read from storage locally. If only page requested,
  % local worker reads fields needed to group and sort rows, query manager
  % reads other fields after merging results only for objects within requested page
  GroupAndSortFields=[ID||{ID,_}<-Grouping++Sorting],

  OtherFields=lists:usort(maps:keys(Read))--GroupAndSortFields,
  LocalReadUpFields=
    if
      Page=:=none ->lists:usort(maps:keys(Read));
      true -> GroupAndSortFields
    end,
  % Fields to read from storage needed for calculation object groups and local presorting
  LocalStorageFields=
    lists:foldl(fun(ID,Acc)->
      ordsets:union(field_args(maps:get(ID,Read)),Acc)
    end,[],LocalReadUpFields),
  GroupingFunList=
    [field_read_fun(maps:get(ID,Read))||ID<-GroupAndSortFields],
  OtherFieldsFunList=
    [field_read_fun(maps:get(ID,Read))||ID<-OtherFields],
  LeafObjectFun=
    fun(Object)->[F(Object)||F<-OtherFieldsFunList]	end,
  % If only page requested local worker puts OID instead of tail of values, query manager builds real values itself
  % only for objects within requested page
  LocalLeaf=
    if
      Page=:=none->LeafObjectFun;
      true ->fun(Object)-> maps:get(<<".oid">>,Object) end
    end,
  % Fun for reading from storage
  ReadUp=maps:get(read_up,Params),
  %-------Fun to build local result--------------
  MapFun=
    fun(RS)->
      Groups=
        ecomet_resultset:fold(fun(OID,Acc)->
          Object=ReadUp(OID,LocalStorageFields),
          GroupValues=[F(Object)||F<-GroupingFunList],
          Row=LocalLeaf(Object),
          insert_to_group(GroupValues,fun(GroupAcc)->[Row|GroupAcc] end,[],Acc)
        end,#{},RS,foldr,none),
      sort_groups(length(Grouping++Sorting),Groups)
    end,
  %------REDUCE--------------------------------------
  ResultLeaf=
    if
      Page=:=none ->fun(Values)->Values end;
      true->
        OtherStorageFields=
          lists:foldl(fun(ID,Acc)->
            ordsets:union(field_args(maps:get(ID,Read)),Acc)
          end,[],OtherFields),
        fun(OID)->
          Object=ReadUp(OID,OtherStorageFields),
          LeafObjectFun(Object)
        end
    end,
  % Build final row. If sorting within group is performed, then sorting fields put in the head of the row,
  % we need to restore requested order of fields
  Positions=field_positions([ID||{ID,_}<-Sorting]++OtherFields),
  Prototype=erlang:make_tuple(length(Positions),none),

  % Traversing groups
  TraverseGroups=[{true,Order}||{_,Order}<-Grouping]++[{false,Order}||{_,Order}<-Sorting],

  MergeTrees=
    fun([InitTree|Results])->
      lists:foldr(fun(GroupsTree,Acc)->
        merge_trees(length(TraverseGroups),GroupsTree,fun(RowList,GroupAcc)->
          RowList++GroupAcc
        end,Acc)
      end,InitTree,Results)
     end,
  %-------Fun to reduce results--------------
  ReduceFun=
    case Page of
      none->
        FinalRow=
          fun(Head,Rows)->
            [reorder_fields(Head++ResultLeaf(Tail),Positions,Prototype)||Tail<-Rows]
          end,
        fun(Results)->
          grouped_resut(TraverseGroups,MergeTrees(Results),FinalRow,[])
        end;
      _ ->
        PrepareRow=
          fun(Head,Rows)->
            [{Head,OID}||OID<-Rows]
          end,
        FinalRow=
          fun(_,Rows)->
            [reorder_fields(Head++ResultLeaf(OID),Positions,Prototype)||{Head,OID}<-Rows]
          end,
        fun(Results)->
          PreparedResults=grouped_resut(TraverseGroups,MergeTrees(Results),PrepareRow,[]),
          {length(PreparedResults),final_resut(length(Grouping),groups_page(PreparedResults,Page),FinalRow,[])}
        end
    end,
  {MapFun,ReduceFun};

%%--------AGGREGATING QUERIES--------------------------
%% CASE 3. Aggregated results, no grouping
map_reduce_plan(#{group:=[]}=Params)->
  % Per row reading plan
  Read=maps:get(read,Params),
  % Fields to read from storage
  StorageFields=
    maps:fold(fun(_,#field{value = #get{args = Args}},Acc)->
      ordsets:union(Args,Acc)
    end,[],Read),

  RowFieldsFunList=
    [F#field.value#get.value||{_,F}<-ordsets:from_list(maps:to_list(Read))],
  % Fun for reading from storage
  ReadUp=maps:get(read_up,Params),
  % Fun to build per row results
  BuildRowFun=
    fun(OID)->
      Object=ReadUp(OID,StorageFields),
      [F(Object)||F<-RowFieldsFunList]
    end,
  AggregateFunList=
    [field_aggregate_fun(F)||{_,F}<-ordsets:from_list(maps:to_list(Read))],
  AppendRowFun=
    fun(Row,GroupAcc)->
      [Fun(Value,Acc)||{Fun,Value,Acc}<-lists:zip3(AggregateFunList,Row,GroupAcc)]
    end,
  % Fun for reading from storage
  ReadUp=maps:get(read_up,Params),
  %-------Fun to build local result--------------
  MapFun=
    fun(RS)->
      ecomet_resultset:foldl(fun(OID,Acc)->
        AppendRowFun(BuildRowFun(OID),Acc)
      end,[none||_<-AggregateFunList],RS)
    end,
  %------REDUCE--------------------------------------
  ReduceFun=
    fun([Init|Results])->
      lists:foldl(fun(Res,Acc)->
        AppendRowFun(Res,Acc)
      end,Init,Results)
    end,
  {MapFun,ReduceFun};

%% CASE 4. Aggregated results, grouping
map_reduce_plan(Params)->
  % Per row reading plan
  Read=maps:get(read,Params),
  % Grouping/Sorting
  Grouping=maps:get(group,Params),

  GroupFields=[ID||{ID,_}<-Grouping],
  OtherFields=lists:usort(maps:keys(Read))--GroupFields,

  % Fields to read from storage
  StorageFields=
    lists:foldl(fun(ID,Acc)->
      ordsets:union(field_args(maps:get(ID,Read)),Acc)
    end,[],GroupFields++OtherFields),

  GroupingFunList=
    [field_read_fun(maps:get(ID,Read))||ID<-GroupFields],
  OtherFieldsFunList=
    [field_read_fun(maps:get(ID,Read))||ID<-OtherFields],
  AggregateFunList=
    [field_aggregate_fun(maps:get(ID,Read))||ID<-OtherFields],

  % Fun for reading from storage
  ReadUp=maps:get(read_up,Params),
  % Fun to append row to group
  AppendRowFun=
    fun(Row,GroupAcc)->
      [Fun(Value,Acc)||{Fun,Value,Acc}<-lists:zip3(AggregateFunList,Row,GroupAcc)]
    end,
  % Fun for reading from storage
  ReadUp=maps:get(read_up,Params),

  InitGroup=[none||_<-AggregateFunList],
  %-------Fun to build local result--------------
  MapFun=
    fun(RS)->
      Groups=
        ecomet_resultset:foldl(fun(OID,Acc)->
          Object=ReadUp(OID,StorageFields),
          GroupValues=[F(Object)||F<-GroupingFunList],
          Row=[F(Object)||F<-OtherFieldsFunList],
          insert_to_group(GroupValues,fun(GroupAcc)->AppendRowFun(Row,GroupAcc) end,InitGroup,Acc)
        end,#{},RS),
      sort_groups(length(Grouping),Groups)
    end,
  %------REDUCE--------------------------------------
  % Traversing groups
  TraverseGroups=[{true,Order}||{_,Order}<-Grouping],
  LeafSorting=
    case {maps:get(order,Params),lists:last(Grouping)} of
      % No sorting by aggregates
      {[],{_,OrderType}}->OrderType;
      % Leaf level already sorted. TODO reorder leaf if sorting by aggregates has priority over leaf group
      {_,{_,OrderType}} when OrderType=/=none->OrderType;
      % Sorting by aggregates
      {Sorting,_}->
        SortList=
          [case orddict:find(ID,Sorting) of
             {ok,OrderType}->OrderType;
             error->none
           end||ID<-OtherFields],
        fun({_,Row1},{_,Row2})->
          compare_rows(SortList,Row1,Row2)
        end
    end,
  FinalRow=fun(_Head,Row)->Row end,
  %-------Fun to reduce results--------------
  Page=maps:get(page,Params),
  ReduceFun=
    fun([InitTree|Results])->
      % Traversing results from the right to optimize ++ operator (assume that RowList < GroupAcc )
      MergedGroups=
        lists:foldr(fun(GroupsTree,Acc)->
          merge_trees(length(TraverseGroups),GroupsTree,AppendRowFun,Acc)
        end,InitTree,Results),
      SortedGroups=sort_leafs(length(Grouping)-1,MergedGroups,LeafSorting),
      if
        Page=:=none -> grouped_resut(lists:droplast(TraverseGroups),SortedGroups,FinalRow,[]);
        true ->
          PreparedResults=grouped_resut(lists:droplast(TraverseGroups),SortedGroups,FinalRow,[]),
          {length(PreparedResults),groups_page(PreparedResults,Page)}
      end
    end,
  {MapFun,ReduceFun}.

%%====================UTILITIES================================
read_map(Fields)->
  read_map(lists:zip(lists:seq(1,length(Fields)),Fields),#{}).
read_map([{I,Field}|Rest],Acc)->
  {Alias,Value}=get_alias(Field,I),
  Get=read_fun(Value),
  read_map(Rest,Acc#{I=>#field{
    alias = Alias,
    value = Get
  }});
read_map([],Acc)->Acc.

get_alias(Field,I)->
  case Field of
    {Alias,Value} when is_binary(Alias)->{Alias,Value};
    FieldName when is_binary(FieldName)->{FieldName,FieldName};
    _->{integer_to_binary(I),Field}
  end.

read_fun(count)->
  #get{
    value = fun(_Object)->1 end,
    args = [],
    aggregate = fun(Value,Acc)->
      if
        Acc=:=none ->Value ;
        true->Acc+Value
      end
    end
  };
read_fun({Aggregate,Value}) when (Aggregate=:=sum) or (Aggregate=:=max) or (Aggregate=:=min)->
  Get=read_fun(Value),
  Fun=
    case Aggregate of
      sum->fun(V,Acc)->Acc+V end;
      max->fun(V,Acc)->if V>Acc->V; true->Acc end end;
      min->fun(V,Acc)->if V<Acc->V; true->Acc end end
    end,
  AggregateFun=
    fun(V,Acc)->
      if
        V=:=none->Acc;
        true->
          if
            Acc=:=none->V;
            true->Fun(V,Acc)
          end
      end
    end,
  Get#get{ aggregate= AggregateFun};
read_fun({Fun,Arguments}) when is_function(Fun,1)->
  ArgumentList=[read_fun(Arg)||Arg<-Arguments],
  #get{
    value = fun(Object)->Fun([ArgFun(Object)||#get{value=ArgFun}<-ArgumentList]) end,
    args = lists:foldl(fun(#get{args=Args},Acc)->ordsets:union(Args,Acc) end,[],ArgumentList)
  };
read_fun(FieldName) when is_binary(FieldName)->
  #get{
    value = fun(Object)->maps:get(FieldName,Object) end,
    args = [FieldName]
  };
read_fun(Field)->erlang:error({invalid_query_field,Field}).

field_read_fun(#field{value = Get})->Get#get.value.
field_args(#field{value = Get})->Get#get.args.
field_aggregate_fun(#field{value = Get})->Get#get.aggregate.

is_aggregate(Map)->
  [F|Tail]=[Field||{_,Field}<-maps:to_list(Map)],
  is_aggregate(Tail,F#field.value#get.aggregate=/=undefined).
is_aggregate([Field|Rest],Result)->
  if
    (Field#field.value#get.aggregate=/=undefined)=:=Result->is_aggregate(Rest,Result);
    true->erlang:error(mix_aggegated_and_plain_fields)
  end;
is_aggregate([],Result)->Result.


read_up(dirty)->
  % GET .name, $SUM(price), .folder, to_path(archive), binary_field WHERE GROUP BY .pattern

  % [
  %   [{3,4},[
  %     [ <<"item1">>,34]
  %     [ <<"item3">>,48]
  %   ]]
  %   [{3,7},[
  %     [<<"item1">>,34],
  %     [<<"item1">>,34]
  %   ]]
  % ]
  % [
  %   [ {3,87}, <<"ITEM1">>, 45, {3,7}, {4,5}, <<5,6,8>>  ]
  %   [ {3,88}, <<"ITEM1">>, 45, {3,7}, {4,5}, <<5,6,8>>  ]

  % ]
  % [ <<"ITEM1">>, 45, {3,7}, {gas,5}, <<5,6,8>> ]
  %
  %
  % fun([{Type,Value},{Type,Value2}])-> end,
  %
  %
  fun(OID,Fields)->
    Object=ecomet_object:construct(OID),
    read_up(Fields,Object,#{<<".oid">>=>OID,object=>Object})
  end;
read_up(Lock)->
  fun(OID,Fields)->
    Object=ecomet_object:open(OID,Lock),
    read_up(Fields,Object,#{<<".oid">>=>OID,object=>Object})
  end.
read_up([<<".oid">>|Rest],Object,Acc)->
  read_up(Rest,Object,Acc);
read_up([Field|Rest],Object,Acc)->
  {ok,Value}=ecomet:read_field(Object,Field),
  read_up(Rest,Object,Acc#{Field=>Value});
read_up([],Object,Acc)->
  Acc#{
    object=>Object,
    <<".oid">>=>ecomet_object:get_oid(Object)
  }.
%%--------Local presorting----------------------------------
% Tree level is sorted list of tuples - { Key, ItemList }.
% ItemList can be subtree.
%-----------------------------------------------------------
insert_to_group([LeafGroup],InsertFun,Init,Acc)->
  GroupAcc=maps:get(LeafGroup,Acc,Init),
  Acc#{LeafGroup=>InsertFun(GroupAcc)};
insert_to_group([Group|Rest],InsertFun,Init,Acc)->
  Branch=maps:get(Group,Acc,#{}),
  Acc#{Group=>insert_to_group(Rest,InsertFun,Init,Branch)}.

sort_groups(L,Tree) when L>0->
  lists:usort([{K,sort_groups(L-1,V)}||{K,V}<-maps:to_list(Tree)]);
% Leaf group
sort_groups(_L,Leaf)->Leaf.

%---------Merging groups----------------------------
% Not sorted level, Tree is map
merge_trees(L,Tree1,Tree2,Fun) when L>0->
  Merge=
    fun(SubTree1,SubTree2)->merge_trees(L-1,SubTree1,SubTree2,Fun) end,
  union_groups(Tree1,Tree2,Merge);
merge_trees(_L,Leaf1,Leaf2,Fun)->Fun(Leaf1,Leaf2).

% Algorithm from ordsets with merging
union_groups([{K1,V1}|Rest1],[{K2,_}|_]=Set2,Merge) when K1 < K2 ->
  [{K1,V1}|union_groups(Rest1,Set2,Merge)];
union_groups([{K1,_}|_]=Set1, [{K2,V2}|Rest2],Merge) when K1 > K2 ->
  [{K2,V2}|union_groups(Rest2,Set1,Merge)];
% K1 == K2. Merge subtrees
union_groups([{K,V1}|Rest1],[{_,V2}|Rest2],Merge)->
  [{K,Merge(V1,V2)}|union_groups(Rest1,Rest2,Merge)];
union_groups([], Rest2,_) -> Rest2;
union_groups(Rest1,[],_) -> Rest1.

field_positions(FieldOrder)->
  Map=lists:zip(lists:usort(FieldOrder),lists:seq(1,length(FieldOrder))),
  [proplists:get_value(ID,Map)||ID<-FieldOrder].

reorder_fields([V|RestV],[P|RestP],Acc)->
  reorder_fields(RestV,RestP,setelement(P,Acc,V));
reorder_fields([],[],Acc)->
  tuple_to_list(Acc).

%-----------Output grouped results-----------------------
% Traversing in descending order
grouped_resut([{Type,'DESC'}|Rest],Tree,BuildRow,Head)->
  grouped_resut([{Type,'ASC'}|Rest],lists:reverse(Tree),BuildRow,Head);
% Group level
grouped_resut([{true,_}|Rest],Tree,BuildRow,Head)->
  [[Key,grouped_resut(Rest,Branch,BuildRow,Head)]||{Key,Branch}<-Tree];
% Sorted level
grouped_resut([{false,_}|Rest],Tree,BuildRow,Head)->
  lists:append([grouped_resut(Rest,Branch,BuildRow,Head++[Key])||{Key,Branch}<-Tree]);
% Leaf level
grouped_resut([],Rows,BuildRow,Head)->
  BuildRow(Head,Rows).

groups_page(Tree,{Number,Count})->
  Skip=(Number-1)*Count,
  Length=length(Tree),
  if
    Length=<Skip ->[] ;
    true->lists:sublist(Tree,Skip+1,Count)
  end.

% Group level
final_resut(L,Tree,BuildRow,Head) when L>0->
  [[Key,final_resut(L-1,Branch,BuildRow,Head)]||[Key,Branch]<-Tree];
% Leaf level
final_resut(_L,Rows,BuildRow,Head)->
  BuildRow(Head,Rows).


compare_rows([none|Rest],[_|R1],[_|R2])->
  compare_rows(Rest,R1,R2);
compare_rows([_|Rest],[E1|R1],[E2|R2]) when E1==E2->
  compare_rows(Rest,R1,R2);
compare_rows([Order|_],[E1|_],[E2|_])->
  if
    Order=:='DESC'->E1>E2;
    true->E1=<E2
  end;
compare_rows([],[],[])->true.

sort_leafs(L,Tree,Fun) when L>0->
  [{Key,sort_leafs(L-1,Branch,Fun)}||{Key,Branch}<-Tree];
sort_leafs(L,Leaf,Fun) when is_function(Fun)->
  sort_leafs(L,lists:sort(Fun,Leaf),'ASC');
sort_leafs(L,Rows,'DESC')->
  sort_leafs(L,lists:reverse(Rows),'ASC');
sort_leafs(_L,Rows,_Order)->
  [[Head|Tail]||{Head,Tail}<-Rows].

%% ====================================================================
%% MACROS
%% ====================================================================
macros(term,[Text]) when is_binary(Text)->
  case ecomet_types:string_to_term(Text) of
    {ok,Value}->Value;
    {error,_Error}->?ERROR({invalid_term,Text})
  end;
macros(term,_Arguments)->
  ?ERROR({term,invalid_arguments});
macros(path,[Path]) when is_binary(Path)->
  case ecomet:path2oid(Path) of
    {ok,OID}->OID;
    {error,_}->?ERROR({invalid_path,Path})
  end;
macros(path,_Arguments)->
  ?ERROR({path,invalid_arguments});
macros(Macros,_Arguments)->
  ?ERROR({invalid_macros,Macros}).

%% ====================================================================
%% PARSER
%% ====================================================================
wrap_transactions(Statements)->
  wrap_transactions(Statements,0,[]).
wrap_transactions([transaction_start|Rest],Level,Acc)->
  case wrap_transactions(Rest,Level+1,[]) of
    {TransactionStatements,Tail}->
      Acc1=
        if
          length(TransactionStatements)>0 -> [{transaction,TransactionStatements}|Acc];
          true -> Acc
        end,
      wrap_transactions(Tail,Level,Acc1);
    Tail->lists:reverse(Acc)++[transaction_start|Tail]
  end;
wrap_transactions([End|Rest],Level,Acc)
  when End=:=transaction_commit; End=:=transaction_rollback->
  if
    Level>0 ->
      if
        End=:=transaction_commit-> {lists:reverse(Acc),Rest};
        true ->
          % What is the sense to start transaction if you know you roll it back?
          ?ERROR(rollback_internal_transaction)
      end;
    true -> wrap_transactions(Rest,Level,[End|Acc])
  end;
wrap_transactions([S|Rest],Level,Acc)->
  wrap_transactions(Rest,Level,[S|Acc]);
wrap_transactions([],_Level,Acc)->lists:reverse(Acc).

%% ====================================================================
%% QL functions
%% ====================================================================
concat(Items)->
  concat(Items,<<>>).
concat([Item|Rest],Acc)->
  concat(Rest,<<Acc/binary,Item/binary>>);
concat([],Acc)->Acc.

string([Term])->
  ecomet_types:term_to_string(Term).


%% ====================================================================
%% Internal helpers
%% ====================================================================
set_rights(system,Conditions)->
  Conditions;
set_rights(Type,Conditions)->
  case ecomet_user:is_admin() of
    {ok,true}->Conditions;
    {error,Error}->?ERROR(Error);
    _->
      {ok,UserID}=ecomet_user:get_user(),
      {ok,UserGroups}=ecomet_user:get_usergroups(),
      Level=
        if
          Type=:=get -> <<".readgroups">>;
          true -> <<".writegroups">>
        end,
      {'AND',[
        Conditions,
        {'OR',[
          {Level,'=',GID}|| GID<-[UserID|UserGroups]
        ]}
      ]}
  end.
