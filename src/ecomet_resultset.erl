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

-module(ecomet_resultset).

-include("ecomet.hrl").
-include("ecomet_schema.hrl").

%% ====================================================================
%% API functions
%% ====================================================================
-export([
	prepare/1,
	normalize/1,
	new/0,
  new_branch/0,
	execute/5,
	execute_local/4,
	remote_call/6,
	count/1,
	foldr/3,
	foldr/4,
	foldl/3,
	foldl/4,
	fold/5
	]).

%%====================================================================
%%		Test API
%%====================================================================
-ifdef(TEST).

-export([
	define_patterns/1,
	build_conditions/2,
	optimize/1,
	search_patterns/3,
	seacrh_idhs/3,
	execute_remote/4,
	wait_remote/2
]).

-endif.

-define(TIMEOUT,30000).
%%=====================================================================
%%	Preparing query
%%=====================================================================
%% For search process we need info about storages for indexes. It's contained in patterns. Next variants are possible:
%% 1. Patterns are defined by query conditions. Example:
%% 		{'AND',[
%% 			{<<".pattern">>, '=', PatternID},
%% 			{<<"my_field">>, '=', Value }
%% 		]}
%%		Search is limited by only pattern PatternID. So, we can define storage for this field and perform search only there
%% 2. Patterns are defined while search. Example query:
%%		{<<"my_field">>, '=', Value}
%%		It contains no info about patterns. On search we will perform first extra step - search for patterns
%% 		through all storages (index include top layer on pattern).
prepare(Conditions)->
	Patterned=define_patterns(Conditions),
	{Built,Direct}=build_conditions(Patterned,element(3,Patterned)),
	if
		% Query contains direct conditions, we must use normal form of the query
		Direct->
			Normal=normalize(Built),
			optimize(Normal);
		true->Built
	end.
%%
%% Define conditions on patterns
%%
define_patterns({<<".pattern">>,'=',PatternID})->
	ID=ecomet_object:get_id(PatternID),
	Bit=ecomet_bits:set_bit(ID,none),
	{'LEAF',{'=',<<".pattern">>,PatternID},Bit};
% Leaf condition
define_patterns({Field,Oper,Value}) when is_binary(Field)->
	{'LEAF',{Oper,Field,Value},'UNDEFINED'};
% Intersect or union patterns
define_patterns({Oper,List}) when (Oper=='AND') or (Oper=='OR')->
	Start=if Oper=='AND'->'UNDEFINED'; true->none end,
	{PatternBits,ConditionList}=
	lists:foldl(fun(Condition,{Bits,ResultList})->
		ReadyCondition=define_patterns(Condition),
		CBits=element(3,ReadyCondition),
		ResultBits=pbits_oper(Oper,Bits,CBits),
		{ResultBits,[ReadyCondition|ResultList]}
	end,{Start,[]},List),
	{Oper,lists:reverse(ConditionList),PatternBits};
define_patterns({'ANDNOT',Condition1,Condition2})->
	C1=define_patterns(Condition1),
	C1Bits=element(3,C1),
	C2=define_patterns(Condition2),
	{'ANDNOT',{C1,C2},C1Bits}.
%%
%% Building conditions
%%
build_conditions({'LEAF',{Oper,Field,Value},IntBits},ExtBits) when (Oper=='=') or (Oper=='LIKE')->
	Config=
	case pbits_oper('AND',IntBits,ExtBits) of
		'UNDEFINED'->'UNDEFINED';
		Patterns->
			build_tag_config(Patterns,Field)
	end,
	build_leaf({Oper,Field,Value},Config);
build_conditions({'LEAF',Condition,_},_)->
	case element(1,Condition) of
		':='->ok;
		':>'->ok;
		':>='->ok;
		':<'->ok;
		':=<'->ok;
		':LIKE'->ok;
		':<>'->ok;
		Oper->?ERROR({invalid_operation,Oper})
	end,
	{{'DIRECT',Condition,'UNDEFINED'},true};
build_conditions({Oper,ConditionList,IntBits},ExtBits) when (Oper=='AND') or (Oper=='OR')->
	XBits=pbits_oper('AND',ExtBits,IntBits),
	{ResConditons,ResDirect}=
	lists:foldr(fun(C,{AccConditions,AccDirect})->
		{Condition,CDirect}=build_conditions(C,XBits),
		{[Condition|AccConditions],CDirect or AccDirect}
	end,{[],false},ConditionList),
	% nothing can be added to XBits
	Config=if XBits=='UNDEFINED'->'UNDEFINED'; true->{XBits,[]} end,
	{{Oper,ResConditons,Config},ResDirect};
build_conditions({'ANDNOT',{Condition1,Condition2},IntBits},ExtBits)->
	XBits=pbits_oper('AND',IntBits,ExtBits),
	{C1,C1Direct}=build_conditions(Condition1,XBits),
	{C2,C2Direct}=build_conditions(Condition2,XBits),
	Config=if XBits=='UNDEFINED'->'UNDEFINED'; true->{XBits,[]} end,
	{{'ANDNOT',{C1,C2},Config},C1Direct or C2Direct}.
%%
%%	Build helpers
%%
build_tag_config(Patterns,Field)->
	% If patterns are defined, then we can define available storages for the tag
	element(2,ecomet_bits:foldl(fun(ID,{AccPatterns,AccStorages})->
		Map=ecomet_pattern:get_map({?PATTERN_PATTERN,ID}),
		case ecomet_field:get_storage(Map,Field) of
			% TAG is actual for the Pattern, add storage for the Field
			{ok,Storage}->
				StorageBits=
					case lists:keyfind(Storage,1,AccStorages) of
						false->none;
						{_,DefinedPatterns,_}->DefinedPatterns
					end,
				{ecomet_bits:set_bit(ID,AccPatterns),[{Storage,ecomet_bits:set_bit(ID,StorageBits),[]}|proplists:delete(Storage,AccStorages)]};
			% TAG a priory is empty for the Pattern,
			{error,undefined_field}->{AccPatterns,AccStorages}
		end
	end,{none,[]},Patterns,{none,none})).
build_leaf({'=',Field,Value},Config)->
	{{'TAG',{Field,Value,simple},Config},false};
build_leaf({'LIKE',Field,Value},Config)->
	ANDConfig=case Config of 'UNDEFINED'->'UNDEFINED'; {Patterns,_}->{Patterns,[]} end,
	% We drop first and last 3grams, it's ^start, end$
	case ecomet_index:split_3grams(Value) of
		% String is too short, use direct analog
		[]->{{'DIRECT',{':LIKE',Field,Value},'UNDEFINED'},true};
		[_PhraseEnd|NGrams]->
			{{'AND',[{'TAG',{Field,Gram,'3gram'},Config}||Gram<-lists:droplast(NGrams)],ANDConfig},false}
	end.

pbits_oper('AND',X1,X2)->
	case {X1,X2} of
		{'UNDEFINED',_}->X2;
		{_,'UNDEFINED'}->X1;
		_->ecomet_bits:oper('AND',X1,X2)
	end;
pbits_oper('OR',X1,X2)->
	case {X1,X2} of
		{'UNDEFINED',_}->'UNDEFINED';
		{_,'UNDEFINED'}->'UNDEFINED';
		_->ecomet_bits:oper('OR',X1,X2)
	end.
%%
%%	Query normalization. Simplified example:
%%	Source query:
%%	{'AND',[
%%		{'OR',[
%%			{<<"field1">>,'=',Value1},
%%			{<<"field2">>,'=',Value1}
%% 		]},
%%		{'OR',[
%%			{<<"field1">>,'=',Value2},
%%			{<<"field2">>,'=',Value2}
%% 		]},
%%		{<<"field3">>,':>',Value3}
%% 	]}
%%	Result:
%%																					base conditions (indexed)											direct conditions
%%																					/														\													/						\
%%																				and													 andnot					  				and					 andnot
%%																				 |														 |											 |						 |
%%	{'OR',[																 |														 |											 |						 |
%%		{'NORM',{ [{<<"field1">>,'=',Value1}, {<<"field1">>,'=',Value2 }], [] }, { [{<<"field3">>,':>',Value3}], [] } },
%%		{'NORM',{ [{<<"field1">>,'=',Value1}, {<<"field2">>,'=',Value2 }], [] }, { [{<<"field3">>,':>',Value3}], [] } },
%%		{'NORM',{ [{<<"field2">>,'=',Value1}, {<<"field1">>,'=',Value2 }], [] }, { [{<<"field3">>,':>',Value3}], [] } },
%%		{'NORM',{ [{<<"field2">>,'=',Value1}, {<<"field2">>,'=',Value2 }], [] }, { [{<<"field3">>,':>',Value3}], [] } }
%%	]}
%% 	For each 'NORM' we define search limits by indexed conditions and after that we load each object and check it for direct conditions
normalize(Conditions)->
	norm_sort(norm(Conditions),element(3,Conditions)).
norm({'TAG',Condition,Config})->
	[[{1,{'TAG',Condition,Config}}]];
norm({'DIRECT',Condition,Config})->
	[[{1,{'DIRECT',Condition,Config}}]];
norm({'AND',ANDList,_})->
	case lists:foldl(fun(AND,AndAcc)->
		list_mult(AndAcc,norm(AND))
	end,start,ANDList) of
		start->[[]];
		Result->Result
	end;
norm({'OR',ORList,_})->
	lists:foldl(fun(OR,OrAcc)->
		list_add(OrAcc,norm(OR))
	end,[[]],ORList);
norm({'ANDNOT',{Condition1,Condition2},_})->
	list_andnot(norm(Condition1),norm(Condition2)).

list_mult(start,List2)->List2;
list_mult([[]],_List2)->[[]];
list_mult(_List1,[[]])->[[]];
list_mult(List1,List2)->
	lists:foldr(fun(L1,Result)->
		lists:foldr(fun(L2,ResultTags)->
			[L1++L2|ResultTags]
		end,Result,List2)
	end,[],List1).

list_add([[]],List2)->List2;
list_add(List1,[[]])->List1;
list_add(List1,List2)->
	List1++List2.

list_andnot(List1,List2)->
	list_add(
		list_mult(List1,list_not(list_filter(List2,1))),
		list_mult(List1,
			list_mult(
				list_filter(List2,1),
				list_not(list_filter(List2,-1))
			)
		)
	).

list_not(List)->
	case lists:foldr(fun(E1,Acc1)->
		list_mult(Acc1,lists:foldr(fun({Sign,Tag},Acc2)->
			[[{Sign*-1,Tag}]|Acc2]
		end,[],E1))
	end,start,List) of
		start->[[]];
		Result->Result
	end.

list_filter(List,Sign)->
	lists:foldr(fun(E1,Acc1)->
		case lists:foldr(fun({ESign,Tag},Acc2)->
			case ESign of
				Sign->[{ESign,Tag}|Acc2];
				_->Acc2
			end
		end,[],E1) of
			[]->Acc1;
			FilteredList->list_add(Acc1,[FilteredList])
		end
	end,[[]],List).

norm_sort(List,Config)->
	ORList=
	lists:foldr(fun(E1,Acc1)->
    {{TAdd,TDel},{DAdd,DDel}}=
		lists:foldr(fun({Sign,Tag},{{TagAdd,TagDel},{DirectAdd,DirectDel}})->
			case {element(1,Tag),Sign} of
				{'TAG',1}->{{[Tag|TagAdd],TagDel},{DirectAdd,DirectDel}};
				{'TAG',-1}->{{TagAdd,[Tag|TagDel]},{DirectAdd,DirectDel}};
				{'DIRECT',1}->{{TagAdd,TagDel},{[Tag|DirectAdd],DirectDel}};
				{'DIRECT',-1}->{{TagAdd,TagDel},{DirectAdd,[Tag|DirectDel]}}
			end
		end,{{[],[]},{[],[]}},E1),
		if TAdd==[]->?ERROR(no_base_conditions); true->ok end,
		[{'NORM',{{{'AND',TAdd,Config},{'OR',TDel,Config}},{DAdd,DDel}},Config}|Acc1]
	end,[],List),
	{'OR',ORList,Config}.

% Optimize normalized query. Try to factor out indexed ands andnots
optimize({'OR',[SingleNorm],Config})->{'OR',[SingleNorm],Config};
optimize({'OR',Normalized,Config})->
  {ListAND,ListANDNOT}=
	lists:foldl(fun({'NORM',{{{'AND',AND,_},{'OR',ANDNOT,_}},_Direct},_},{AccAND,AccANDNOT})->
    {[ordsets:from_list(AND)|AccAND],[ordsets:from_list(ANDNOT)|AccANDNOT]
    }
	end,{[],[]},Normalized),
  case ordsets:intersection(ListAND) of
    % No common tags, nothing to pick out
    []->{'OR',Normalized,Config};
    XAND->
      XANDNOT=ordsets:intersection(ListANDNOT),
      Cleared=
      lists:foldr(fun({'NORM',{{{'AND',AND,_},{'OR',ANDNOT,_}},Direct},_},Acc)->
				% Base AND condition list can not be empty, so we take at least one condition. It's exessive, TODO
				BaseAND=
				case ordsets:subtract(ordsets:from_list(AND),XAND) of
					[]->[lists:nth(1,AND)];
					ClearAND->ClearAND
				end,
        [{'NORM',{{{'AND',BaseAND,Config},{'OR',ordsets:subtract(ordsets:from_list(ANDNOT),XANDNOT),Config}},Direct},Config}|Acc]
      end,[],Normalized),
      case XANDNOT of
        []->{'AND',XAND++[{'OR',Cleared,Config}],Config};
        _->
          {'AND',[{'ANDNOT',{{'AND',XAND,Config},{'OR',XANDNOT,Config}},Config},{'OR',Cleared,Config}],Config}
      end
  end.

%%=====================================================================
%%	API helpers
%%=====================================================================
new()->[].
new_branch()->{none,maps:new()}.

%%=====================================================================
%%	QUERY EXECUTION
%%=====================================================================
execute(DBs,Conditions,Map,Reduce,Union)->
	% Search steps:
	% 1. start remote databases search
	% 2. execute local databases search
	% 3. reduce remote search results
	% 4. Construct query result
	{LocalDBs,RemoteDBs}=lists:foldl(fun(DB,{Local,Remote})->
		case ecomet_db:is_local(DB) of
			true->{[DB|Local],Remote};
			false->{Local,[DB|Remote]}
		end
	end,{[],[]},DBs),
	% Step 1. Start remote search
	PID=execute_remote(RemoteDBs,Conditions,Map,Union),
	% Step 2. Local search
	LocalResult=lists:foldl(fun(DB,Result)->
		[{DB,execute_local(DB,Conditions,Map,Union)}|Result]
	end,[],LocalDBs),
	% Step 3. Reduce remote, order by database
	SearchResult=order_DBs(DBs,wait_remote(PID,LocalResult)),
	% Step 4. Return result
	Reduce(SearchResult).

order_DBs(DBs,Results)->
	order_DBs(DBs,Results,[]).
order_DBs([DB|Rest],Results,Acc)->
	case lists:keytake(DB,1,Results) of
		false->order_DBs(Rest,Results,Acc);
		{value,{_,DBResult},RestResults}->order_DBs(Rest,RestResults,[DBResult|Acc])
	end;
order_DBs([],_Results,Acc)->Acc.

% 1. Map search to remote nodes
% 2. Reduce results, reply
execute_remote([],_Conditions,_Map,_Union)->none;
execute_remote(DBs,Conditions,Map,Union)->
	ReplyPID=self(),
	IsTransaction=ecomet:is_transaction(),
	spawn_link(fun()->
		process_flag(trap_exit,true),
		StartedList=start_remote(DBs,Conditions,Map,Union,IsTransaction),
		ReplyPID!{remote_result,self(),reduce_remote(StartedList,[])}
	end).

% Wait for results from remote databases
wait_remote(none,RS)->RS;
wait_remote(PID,RS)->
	receive
		{remote_result,PID,RemoteRS}->RS++RemoteRS
	after
		?TIMEOUT->
			PID!query_timeout,
			receive
				{remote_result,PID,RemoteRS}->RS++RemoteRS
			after
				2000->?LOGWARNING(remote_request_timeout)
			end
	end.

%% Starting remote search
start_remote(DBs,Conditions,Map,Union,IsTransaction)->
	lists:foldl(fun(DB,Result)->
		case ecomet_db:get_search_node(DB,[]) of
			none->Result;
			Node->
				SearchParams=[DB,Conditions,Union,Map,IsTransaction],
				[{spawn_link(Node,?MODULE,remote_call,[self()|SearchParams]),SearchParams,[Node]}|Result]
		end
	end,[],DBs).

%% Search for remote process
remote_call(PID,DB,Conditions,Union,Map,IsTransaction)->
	LocalResult=
		if
			IsTransaction ->
				case ecomet:transaction(fun()->
					execute_local(DB,Conditions,Map,Union)
				end) of
					{ok,Result}->Result;
					{error,Error}->exit(Error)
				end;
			true ->execute_local(DB,Conditions,Map,Union)
		end,
	PID!{ecomet_resultset,self(),{DB,LocalResult}}.

%% Reducing remote results
reduce_remote([],ReadyResult)->ReadyResult;
% Wait remote results
reduce_remote(WaitList,ReadyResult)->
	receive
		% Result received
		{ecomet_resultset,PID,DBResult}->
			case lists:keyfind(PID,1,WaitList) of
				% We are waiting for this result
				{PID,_,_}->reduce_remote(lists:keydelete(PID,1,WaitList),[DBResult|ReadyResult]);
				% Unexpected result
				false->reduce_remote(WaitList,ReadyResult)
			end;
		% Remote process is down
		{'EXIT',PID,Reason}->
			case lists:keyfind(PID,1,WaitList) of
				% It's process that we are waiting result from. Node is node available now,
				% let's try another one form the cluster
				{PID,Params,TriedNodes} when Reason==noconnection->
					case ecomet_db:get_search_node(lists:nth(1,Params),TriedNodes) of
						% No other nodes can search this domain
						none->
							?LOGWARNING({no_search_nodes_available,lists:nth(1,Params)}),
							reduce_remote(lists:keydelete(PID,1,WaitList),ReadyResult);
						% Let's try another node
						NextNode->
							% Start task
							NewPID=spawn_link(NextNode,?MODULE,remote_call,[self()|Params]),
							reduce_remote(lists:keyreplace(PID,1,WaitList,{NewPID,Params,[NextNode|TriedNodes]}),ReadyResult)
					end;
				% We caught exit from some linked process.
				% Variant 1. Parent process get exit, stop the task
				% Variant 2. Process we are waiting is crashed due to error in the user fun
				_->exit(Reason)
			end;
		query_timeout->ReadyResult
	end.

%% Local search:
%% 1. Search patterns. Match all conditions against Pattern level index. This is optional step, we need it
%% 		only if patterns not explicitly defined in conditions.
%% 2. Search IDHIGHs. Match all conditions against IDHIGH level index.
%% 3. Search IDLOW. Match all conditions against IDLOW level index. Search only within defined on step 2 IDHIGHs
execute_local(DB,Conditions,Map,{Oper,RS})->
  case element(3,Conditions) of
    'UNDEFINED'->
			% Patterns search
			Patterned=search_patterns(Conditions,DB,'UNDEFINED'),
      execute_local(DB,Patterned,Map,{Oper,RS});
		{Patterns,_}->
			DB_RS=get_db_branch(DB,RS),
      % Patterns cycle
			RunPatterns=if Oper=='ANDNOT'->Patterns; true->ecomet_bits:oper(Oper,Patterns,get_branch([],DB_RS)) end,
			ResultRS=
      	element(2,ecomet_bits:foldr(fun(IDP,{IDPBits,IDPMap})->
					% IDHIGH search
					{HBits,Conditions1}=seacrh_idhs(Conditions,DB,IDP),
					RunHBits=if Oper=='ANDNOT'->HBits; true->ecomet_bits:oper(Oper,HBits,get_branch([IDP],DB_RS)) end,
					% IDH cycle
					case element(2,ecomet_bits:foldr(fun(IDH,{IDHBits,IDHMap})->
						% IDLOW search
						LBits=search_idls(Conditions1,DB,IDP,IDH),
						case ecomet_bits:oper(Oper,LBits,get_branch([IDP,IDH],DB_RS)) of
							none->{IDHBits,IDHMap};
							ResIDLs->{ecomet_bits:set_bit(IDH,IDHBits),maps:put(IDH,ecomet_bits:shrink(ResIDLs),IDHMap)}
						end
					end,new_branch(),RunHBits,{none,none})) of
						{none,_}->{IDPBits,IDPMap};
						{IDHBits,IDHMap}->{ecomet_bits:set_bit(IDP,IDPBits),maps:put(IDP,{ecomet_bits:shrink(IDHBits),IDHMap},IDPMap)}
					end
				end,new_branch(),RunPatterns,{none,none})),
			Map([{DB,ResultRS}])
	end.
%%
%% Search patterns
%%
search_patterns({'TAG',Tag,'UNDEFINED'},DB,ExtBits)->
	Storages=
		if
			% If no patterns range is defined yet, then search through all stoarges
			ExtBits=='UNDEFINED'->[?RAMLOCAL,?RAM,?RAMDISC,?DISC];
			true->
				% Define storages where field is defined
				Field=element(1,Tag),
				FoundStorages=
					element(2,ecomet_bits:foldl(fun(ID,AccStorages)->
						Map=ecomet_pattern:get_map({?PATTERN_PATTERN,ID}),
						case ecomet_field:get_storage(Map,Field) of
							{ok,Storage}->ordsets:add_element(Storage,AccStorages);
							{error,undefined_field}->AccStorages
						end
					end,[],ExtBits,{none,none})),
				% Order is [ramlocal,ram,ramdisc,disc]
				lists:subtract([?RAMLOCAL,?RAM,?RAMDISC,?DISC],lists:subtract([?RAMLOCAL,?RAM,?RAMDISC,?DISC],FoundStorages))
		end,
	Config=
		lists:foldr(fun(Storage,{AccPatterns,AccStorages})->
			case ecomet_index:read_tag(DB,Storage,[],Tag) of
				none->{AccPatterns,AccStorages};
				StoragePatterns->
					{ecomet_bits:oper('OR',AccPatterns,StoragePatterns),[{Storage,StoragePatterns,[]}|AccStorages]}
			end
		end,{none,[]},Storages),
	{'TAG',Tag,Config};
search_patterns({'AND',Conditions,'UNDEFINED'},DB,ExtBits)->
	{ResPatterns,ResConditions}=
		lists:foldr(fun(Condition,{AccPatterns,AccCond})->
			PatternedCond=search_patterns(Condition,DB,AccPatterns),
			% If one branch can be true only for PATTERNS1, then hole AND can be true only for PATTERNS1
			{CBits,_}=element(3,PatternedCond),
			{pbits_oper('AND',AccPatterns,CBits),[PatternedCond|AccCond]}
		end,{ExtBits,[]},Conditions),
	% 'UNDEFINED' only if AND contains no real tags.
	% !!! EMPTY {'AND',[]} MAY KILL ALL RESULTS
	Config=if ResPatterns=='UNDEFINED'->{none,[]}; true->{ResPatterns,[]} end,
	{'AND',ResConditions,Config};
search_patterns({'OR',Conditions,'UNDEFINED'},DB,ExtBits)->
	{ResPaterns,ResConditions}=
	lists:foldr(fun(Condition,{AccPatterns,AccCond})->
		PatternedCond=search_patterns(Condition,DB,ExtBits),
		{CBits,_}=element(3,PatternedCond),
		{ecomet_bits:oper('OR',AccPatterns,CBits),[PatternedCond|AccCond]}
	end,{none,[]},Conditions),
	% !!! EMPTY {'OR',[]} MAY KILL ALL RESULTS
	{'OR',ResConditions,{ResPaterns,[]}};
search_patterns({'ANDNOT',{Condition1,Condition2},'UNDEFINED'},DB,ExtBits)->
	C1=search_patterns(Condition1,DB,ExtBits),
	{C1Bits,_}=element(3,C1),
	C2=search_patterns(Condition2,DB,C1Bits),
	% ANDNOT can be true only for C1 patterns
	{'ANDNOT',{C1,C2},{C1Bits,[]}};
search_patterns({'NORM',{{AND,ANDNOT},Direct},'UNDEFINED'},DB,ExtBits)->
	ResAND=search_patterns(AND,DB,ExtBits),
	{ANDBits,_}=element(3,ResAND),
	ResANDNOT=search_patterns(ANDNOT,DB,ANDBits),
	{'NORM',{{ResAND,ResANDNOT},Direct},{ANDBits,[]}};
search_patterns({Oper,Conditions,{IntBits,IDHList}},_DB,ExtBits)->
	XBits=pbits_oper('AND',ExtBits,IntBits),
	{Oper,Conditions,{XBits,IDHList}};
% Strict operations
search_patterns(Condition,_DB,_ExtBits)->Condition.

%%
%% 	Search IDHs
%%
get_idh_storage([{Storage,SIDPBits,SIDHList}|Rest],IDP)->
	case ecomet_bits:get_bit(IDP,SIDPBits) of
		true->{Storage,SIDPBits,SIDHList};
		false->get_idh_storage(Rest,IDP)
	end;
get_idh_storage([],_IDP)->none.

seacrh_idhs({'TAG',Tag,{IDPBits,Storages}},DB,IDP)->
	% The tag can be found only in 1 storage for the pattern, because
	% tag defines field, that linked to certain storage
	case get_idh_storage(Storages,IDP) of
		none->{none,{'TAG',Tag,{IDPBits,Storages}}};
		{Storage,SIDPBits,SIDHList}->
			case ecomet_index:read_tag(DB,Storage,[IDP],Tag) of
				none->{none,{'TAG',Tag,{IDPBits,Storages}}};
				IDHs->
					ResStorages=[{Storage,SIDPBits,[{IDP,IDHs}|SIDHList]}|lists:keydelete(Storage,1,Storages)],
					{IDHs,{'TAG',Tag,{IDPBits,ResStorages}}}
			end
	end;
seacrh_idhs({Type,Condition,{IDPBits,IDHList}},DB,IDP)->
	case ecomet_bits:get_bit(IDP,IDPBits) of
		false->{none,{Type,Condition,{IDPBits,IDHList}}};
		true->
			{IDHBits,ResCondition}=search_type(Type,Condition,DB,IDP),
			ResIDHList=if IDHBits==none->IDHList; true->[{IDP,IDHBits}|IDHList] end,
			{IDHBits,{Type,ResCondition,{IDPBits,ResIDHList}}}
	end.
search_type('AND',Conditions,DB,IDP)->
	lists:foldr(fun(Condition,{AccBits,AccConditions})->
		if
		% One of branches is empty, no sense to search others
			AccBits==none->{none,AccConditions};
			true->
				{CBits,Condition1}=seacrh_idhs(Condition,DB,IDP),
				{ecomet_bits:oper('AND',AccBits,CBits),[Condition1|AccConditions]}
		end
	end,{start,[]},Conditions);
search_type('OR',Conditions,DB,IDP)->
	lists:foldr(fun(Condition,{AccBits,AccConditions})->
		{CBits,Condition1}=seacrh_idhs(Condition,DB,IDP),
		{ecomet_bits:oper('OR',AccBits,CBits),[Condition1|AccConditions]}
	end,{none,[]},Conditions);
search_type('ANDNOT',{Condition1,Condition2},DB,IDP)->
	case seacrh_idhs(Condition1,DB,IDP) of
		{none,Condition1_1}->{none,{Condition1_1,Condition2}};
		{C1Bits,Condition1_1}->
			{_C2Bits,Condition2_1}=seacrh_idhs(Condition2,DB,IDP),
			{C1Bits,{Condition1_1,Condition2_1}}
	end;
search_type('NORM',{{AND,ANDNOT},Direct},DB,IDP)->
	{ANDBits,AND1}=seacrh_idhs(AND,DB,IDP),
	ANDNOT1=
	if
		ANDBits==none->ANDNOT;
		true->
			{_,ANDNOTRes}=seacrh_idhs(ANDNOT,DB,IDP),
			ANDNOTRes
	end,
	{ANDBits,{{AND1,ANDNOT1},Direct}}.

search_idls({'TAG',Tag,Config},DB,IDP,IDH)->
	case get_idh_storage(element(2,Config),IDP) of
		none->none;
		{Storage,_SIDPBits,SIDHList}->
			case proplists:get_value(IDP,SIDHList,undefined) of
				% Nothing found for the Pattern, no sense to search storage
				undefined->none;
				IDHBits->
					case ecomet_bits:get_bit(IDH,IDHBits) of
						% Nothing found for the IDH
						false->none;
						true->ecomet_index:read_tag(DB,Storage,[IDP,IDH],Tag)
					end
			end
	end;
search_idls({Type,Condition,{_,IDHList}},DB,IDP,IDH)->
	case proplists:get_value(IDP,IDHList,undefined) of
		% Branch is empty for the IDP, no sense to search
		undefined->none;
		IDHBits->
			case ecomet_bits:get_bit(IDH,IDHBits) of
				% Branch is empty for the IDH
				false->none;
				true->search_type(Type,Condition,DB,IDP,IDH)
			end
	end.
search_type('AND',Conditions,DB,IDP,IDH)->
	lists:foldl(fun(Condition,AccBits)->
		if
		% One of branches is empty, no sense to search others
			AccBits==none->none;
			true->
				CBits=search_idls(Condition,DB,IDP,IDH),
				ecomet_bits:oper('AND',AccBits,CBits)
		end
	end,start,Conditions);
search_type('OR',Conditions,DB,IDP,IDH)->
	lists:foldl(fun(Condition,AccBits)->
		CBits=search_idls(Condition,DB,IDP,IDH),
		ecomet_bits:oper('OR',AccBits,CBits)
	end,none,Conditions);
search_type('ANDNOT',{Condition1,Condition2},DB,IDP,IDH)->
	case search_idls(Condition1,DB,IDP,IDH) of
		none->none;
		C1Bits->
			C2Bits=search_idls(Condition2,DB,IDP,IDH),
			ecomet_bits:oper('ANDNOT',C1Bits,C2Bits)
	end;
search_type('NORM',{{AND,ANDNOT},{DAND,DANDNOT}},DB,IDP,IDH)->
	case search_idls(AND,DB,IDP,IDH) of
		none->none;
		ANDBits->
			ANDNOTBits=search_idls(ANDNOT,DB,IDP,IDH),
			case ecomet_bits:oper('ANDNOT',ANDBits,ANDNOTBits) of
				none->none;
				TBits->
					element(2,ecomet_bits:foldl(fun(IDL,AccBits)->
						Object=ecomet_object:construct({DB,IDP,IDH*?BITSTRING_LENGTH+IDL}),
						case check_direct(DAND,'AND',Object) of
							false->ecomet_bits:reset_bit(IDL,AccBits);
							true->
								case check_direct(DANDNOT,'OR',Object) of
									true->ecomet_bits:reset_bit(IDL,AccBits);
									false->AccBits
								end
						end
					end,TBits,TBits,{none,none}))
			end
	end.

check_direct(Conditions,Oper,Object)->
	Start=if Oper=='AND'->true; true->false end,
	check_direct(Conditions,Oper,Object,Start).
check_direct([Condition|Rest],'AND',Object,Result)->
	case (check_condition(Condition,Object) and Result) of
		true->check_direct(Rest,'AND',Object,true);
		false->false
	end;
check_direct([Condition|Rest],'OR',Object,Result)->
	case (check_condition(Condition,Object) or Result) of
		true->true;
		false->check_direct(Rest,'OR',Object,false)
	end;
check_direct([],_Oper,_Object,Result)->Result.

check_condition({'DIRECT',{Oper,Field,Value},_},Object)->
	case ecomet_object:read_field(Object,Field) of
		{ok,FieldValue}->
			case Oper of
				':='->FieldValue==Value;
				':>'->FieldValue>Value;
				':>='->FieldValue>=Value;
				':<'->FieldValue<Value;
				':=<'->FieldValue=<Value;
				':LIKE'->direct_like(FieldValue,Value);
				':<>'->FieldValue/=Value
			end;
		{error,_}->false
	end.

direct_like(String,Pattern) when (is_binary(Pattern) and is_binary(String))->
	case Pattern of
		% Symbol '^' is string start
		<<"^",StartPattern/binary>>->
			Length=size(StartPattern)*8,
			case String of
				<<StartPattern:Length/binary,_/binary>>->true;
				_->false
			end;
		% Full text search
		_->case binary:match(String,Pattern) of
				 nomatch->false;
				 _->true
			 end
	end.

%%=====================================================================
%%	ResultSet iterator
%%=====================================================================
count(RS)->
	lists:foldr(fun({_DB,DB_RS},RSAcc)->
		element(2,ecomet_bits:foldr(fun(IDP,PatternAcc)->
			element(2,ecomet_bits:foldr(fun(IDH,Acc)->
				Acc+ecomet_bits:count(ecomet_bits:to_vector(get_branch([IDP,IDH],DB_RS)),0)
			end,PatternAcc,get_branch([IDP],DB_RS),{none,none}))
		end,RSAcc,get_branch([],DB_RS),{none,none}))
	end,0,RS).

foldr(F,Acc,RS)->
  foldr(F,Acc,RS,none).
foldr(F,Acc,RS,Page)->
  fold(F,Acc,RS,foldr,Page).

foldl(F,Acc,RS)->
  foldl(F,Acc,RS,none).
foldl(F,Acc,RS,Page)->
  fold(F,Acc,RS,foldl,Page).

fold(F,Acc,RS,Scan,none)->
  lists:Scan(fun({_DB,DB_RS},RSD)->
    element(2,ecomet_bits:Scan(fun(IDP,RSP)->
			element(2,ecomet_bits:Scan(fun(IDH,RSH)->
				element(2,ecomet_bits:Scan(fun(IDL,RSL)->
          F({IDP,IDH*?BITSTRING_LENGTH+IDL},RSL)
        end,RSH,get_branch([IDP,IDH],DB_RS),{none,none}))
      end,RSP,get_branch([IDP],DB_RS),{none,none}))
    end,RSD,get_branch([],DB_RS),{none,none}))
  end,Acc,RS);
fold(F,Acc,RS,Scan,{Page,Length})->
  From=(Page-1)*Length,
  To=From+Length,
  lists:Scan(fun({_DB,DB_RS},RSD)->
    element(2,ecomet_bits:Scan(fun(IDP,RSP)->
      element(2,ecomet_bits:Scan(fun(IDH,{Count,RSH})->
				{BitsCount,NewAcc}=ecomet_bits:Scan(fun(IDL,RSL)->
					F({IDP,IDH*?BITSTRING_LENGTH+IDL},RSL)
        end,RSH,get_branch([IDP,IDH],DB_RS),{From-Count,To-Count}),
				{Count+BitsCount,NewAcc}
      end,RSP,get_branch([IDP],DB_RS),{none,none}))
    end,RSD,get_branch([],DB_RS),{none,none}))
  end,{0,Acc},RS).

%%=====================================================================
%%	Internal helpers
%%=====================================================================
get_db_branch(DB,RS)->
	case lists:keyfind(DB,1,RS) of
		{DB,DB_Result}->DB_Result;
		false->new_branch()
	end.

% Get branch from result set
get_branch([Key|Rest],{_,Map})->
	case maps:find(Key,Map) of
		{ok,Value}->get_branch(Rest,Value);
		error->none
	end;
get_branch([],Value)->
	case Value of
		{Bits,Map} when is_map(Map)->Bits;
		Bits->Bits
	end.

