%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
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
%%
%% -------------------------------------------------------------------

-module(meta_data_sender).
-behaviour(gen_fsm).

-include("antidote.hrl").

-export([start_link/4,
	 put_meta_dict/2,
	 put_meta_dict/3,
	 put_meta_data/3,
	 put_meta_data/4,
	 get_meta_dict/1,
	 get_merged_data/0,
         remove_partition/1,
	 send_meta_data/2]).

%% Callbacks
-export([init/1,
	 code_change/4,
	 handle_event/3,
	 handle_info/3,
         handle_sync_event/4,
	 terminate/3]).


-record(state, {
	  table,
	  table2,
	  last_result,
	  update_function,
	  merge_function}).

%% ===================================================================
%% Public API
%% ===================================================================

%% -spec start_link(fun(() -> [fun((term(),term())->boolean()), fun((dict())->dict()), dict(), dict()]) -> {ok,pid()} | ignore | {error,term()}.
start_link(UpdateFunction, MergeFunction, InitialLocal, InitialMerged) ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [UpdateFunction, MergeFunction, InitialLocal, InitialMerged], []).
    %%gen_fsm:start_link({local, ?MODULE}, ?MODULE, ExportFun(), []).

-spec put_meta_dict(partition_id(), dict()) -> ok.
put_meta_dict(Partition,Dict) ->
    put_meta_dict(Partition, Dict, undefined).

%% -spec put_meta_dict(partition_id(), dict(), fun((dict(),dict())->dict() | undefined) -> ok.
put_meta_dict(Partition, Dict, Func) ->
    case ets:info(?META_TABLE_NAME) of
	undefined ->
	    ok;
	_ ->
	    Result = case Func of
			 undefined ->
			     Dict;
			 _ ->
			     Func(Dict, get_meta_data(Partition))
		     end,
	    true = ets:insert(?META_TABLE_NAME, {Partition, Result}),
	    ok
    end.


-spec put_meta_data(partition_id(), term(), term()) -> ok.
put_meta_data(Partition, Key, Value) ->
    put_meta_data(Partition, Key, Value, fun(_Prev,Val) -> Val end).

-spec put_meta_data(partition_id(), term(), term(), fun((term(),term()) -> term())) -> ok.
put_meta_data(Partition, Key, Value, Func) ->
    case ets:info(?META_TABLE_NAME) of
	undefined ->
	    ok;
	_ ->
	    Dict = case ets:lookup(?META_TABLE_NAME, Partition) of
		       [] ->
			   dict:new();
		       [{Partition,Other}] ->
			   Other
		   end,
	    NewDict = case dict:find(Key,Dict) of
			  error ->
			      dict:store(Key, Value, Dict);
			  {ok, Prev} ->
			      dict:store(Key, Func(Prev,Value), Dict)
		      end,
	    put_meta_dict(Partition, NewDict, undefined)
    end.

-spec get_meta_dict(partition_id()) -> dict().
get_meta_dict(Partition) ->
    case ets:info(?META_TABLE_NAME) of
	undefined ->
	    dict:new();
	_ ->
	    case ets:lookup(?META_TABLE_NAME, Partition) of
		[] ->
		    dict:new();
		[{Partition,Other}] ->
		    Other
	    end
    end.

-spec remove_partition(partition_id()) -> ok | false.
remove_partition(Partition) ->
    lager:info("removing partition ~p from meta data table", [Partition]),
    case ets:info(?META_TABLE_NAME) of
	undefined ->
	    false;
	_ ->
	    true = ets:delete(?META_TABLE_NAME, Partition),
	    ok
    end.

%% Add info about a new DC. This info could be
%% used by other modules to communicate to other DC
-spec get_merged_data() -> dict().
get_merged_data() ->
    case ets:info(?META_TABLE_STABLE_NAME) of
	undefined ->
	    dict:new();
	_ ->
	    case ets:lookup(?META_TABLE_STABLE_NAME, merged_data) of
		[] ->
		    dict:new();
		[{merged_data,Other}] ->
		    Other
	    end
    end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



init([UpdateFunction,MergeFunction,InitialLocal,InitialMerged]) ->
    Table = ets:new(?META_TABLE_STABLE_NAME, [set, named_table, ?META_TABLE_STABLE_CONCURRENCY]),
    Table2 = ets:new(?META_TABLE_NAME, [set, named_table, public, ?META_TABLE_CONCURRENCY]),
    true = ets:insert(?META_TABLE_STABLE_NAME, {merged_data, InitialMerged}),
    {ok, send_meta_data, #state{table = Table, table2 = Table2, last_result = InitialLocal, update_function = UpdateFunction, merge_function = MergeFunction}, ?META_DATA_SLEEP}.

send_meta_data(timeout, State = #state{last_result = LastResult, update_function = UpdateFunction, merge_function = MergeFunction}) ->
    Dict = get_meta_data(MergeFunction),
    NodeList = get_node_list(),
    LocalMerged = dict:fetch(local_merged,Dict),
    MyNode = node(),
    ok = lists:foreach(fun(Node) ->
			       ok = meta_data_manager:send_meta_data(Node,MyNode,LocalMerged)
		       end, NodeList),
    MergedDict = MergeFunction(Dict),
    {NewBool, NewResult} = update_stable(LastResult,MergedDict,UpdateFunction),
    Store = case NewBool of
		true ->
		    true = ets:insert(?META_TABLE_STABLE_NAME, {merged_data, NewResult}),
		    NewResult;
		false ->
		    LastResult
	    end,
    {next_state, send_meta_data, State#state{last_result = Store}, ?META_DATA_SLEEP}.

handle_info(_Info, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop, badmsg, StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%




-spec get_meta_data(fun((dict()) -> dict())) -> dict() | false.			 
get_meta_data(MergeFunc) ->
    TablesReady = case ets:info(?REMOTE_META_TABLE_NAME) of
		      undefined ->
			  false;
		      _ ->
			  case ets:info(?META_TABLE_NAME) of
			      undefined ->
				  false;
			      _ ->
				  true
			  end
		  end,
    case TablesReady of
	false ->
	    false;
	true ->
	    RemoteDict = dict:from_list(ets:tab2list(?REMOTE_META_TABLE_NAME)),
	    %% Be sure that you are only checking active nodes
	    NodeDict = get_node_dict(),
	    NewDict =
		dict:fold(fun(NodeId, _Tab, Acc) ->
				  case dict:is_key(NodeId, NodeDict) of
				      true ->
					  Acc;
				      false ->
					  ok = meta_data_manager:remove_node(NodeId),
					  dict:erase(NodeId, Acc)
				  end
			  end, RemoteDict, RemoteDict),
	    LocalMerged = MergeFunc(dict:from_list(ets:tab2list(?META_TABLE_NAME))),
	    dict:store(local_merged, LocalMerged, NewDict)
    end.

-spec update_stable(dict(), dict(), fun((term(),term()) -> boolean())) -> {boolean(),dict()}.
update_stable(LastResult,NewDict,UpdateFunc) ->
    dict:fold(fun(DcId, Time, {Bool,Acc}) ->
		      Last = case dict:find(DcId, LastResult) of
				 {ok, Val} ->
				     Val;
				 error ->
				     undefined
			     end,
		      case UpdateFunc(Last,Time) of
			  true ->
			      {true,dict:store(DcId, Time, Acc)};
			  false ->
			      {Bool,Acc}
		      end
	      end, {false,LastResult}, NewDict).

-spec get_node_list() -> [term()].
get_node_list() ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    MyNode = node(),
    lists:delete(MyNode, riak_core_ring:ready_members(Ring)).

-spec get_node_dict() -> dict().
get_node_dict() ->
    NodeList = get_node_list(),
    lists:foldl(fun(Node,Acc) ->
			dict:store(Node,0,Acc)
		end, dict:new(),NodeList).
