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
-module(vectorclock_vnode).

-behaviour(riak_core_vnode).

-include("floppy.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_vnode/1]).

-export([init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

-ignore_xref([start_vnode/1]).

-define(META_PREFIX, {partition,vectorclock}).

-record(currentclock,{last_received_clock :: vectorclock:vectorclock(),
                      partition_vectorclock :: vectorclock:vectorclock(),
                      stable_snapshot :: vectorclock:vectorclock(),
                      partition}).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

%% @doc Initialize the clock
init([Partition]) ->
    {ok, #currentclock{last_received_clock=dict:new(),
                      partition_vectorclock=dict:new(),
                      stable_snapshot = dict:new(),
                      partition = Partition}}.

%% @doc
handle_command(get_clock, _Sender,
               #currentclock{partition_vectorclock=Clock} = State) ->
    {reply, {ok, Clock}, State};

handle_command(get_stable_snapshot, _Sender,
               State=#currentclock{stable_snapshot=Clock}) ->
    {reply, {ok, Clock}, State};

handle_command(calculate_stable_snapshot, _Sender,
               State=#currentclock{partition_vectorclock = Clock}) ->
    %% Calculate stable_snapshot from minimum of vectorclock of all partitions
    lager:error("Calculating stable snapshot"),
    Stable_snapshot = riak_core_metadata:fold(
                        fun({_Key, V}, A) ->
                                find_min(V,A)
                        end,
                        Clock, ?META_PREFIX),
    lager:info("Stable snapshot ~p ",[Stable_snapshot]),
    {reply, {ok, Stable_snapshot},
     State#currentclock{stable_snapshot=Stable_snapshot}};

%% @doc This function implements following code
%% if last_received_vectorclock[partition][dc] < time
%%   vectorclock[partition][dc] = last_received_vectorclock[partition][dc]
%% last_received_vectorclock[partition][dc] = time
handle_command({update_clock, DcId, Timestamp}, _Sender,
               #currentclock{last_received_clock=LastClock,
                             partition_vectorclock=VClock,
                             partition=Partition
                            } = State) ->
    case dict:find(DcId, LastClock) of
        {ok, LClock} ->
            case LClock < Timestamp of
                true ->
                    NewLClock = dict:store(DcId, Timestamp, LastClock),
                    NewPClock = dict:store(DcId, Timestamp-1, VClock),
                    %% Broadcast new pvv to other partition
                    riak_core_metadata:put(?META_PREFIX, Partition, NewPClock),
                    {reply, {ok, NewLClock},
                     State#currentclock{last_received_clock=NewLClock,
                                        partition_vectorclock=NewPClock}
                    };
                false ->
                    {reply, {ok, VClock}, State}
            end;
        error ->
            lager:info("Timestamp : ~p",[Timestamp]),
            NewLClock = dict:store(DcId, Timestamp, LastClock),
            NewPClock = dict:store(DcId, Timestamp - 1, VClock),
            riak_core_metadata:put(?META_PREFIX, Partition, NewPClock),
            {reply, {ok, NewLClock}, State#currentclock
             {last_received_clock=NewLClock,
              partition_vectorclock=NewPClock}}
    end;

handle_command(_Message, _Sender, State) ->
    {noreply, State}.

handle_handoff_command( _Message , _Sender, State) ->
    {noreply, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(_Data, State) ->
    {reply, ok, State}.

encode_handoff_item(Key, Operation) ->
    term_to_binary({Key, Operation}).

is_empty(State) ->
    {true, State}.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

find_min([VClock], StableClock) ->
    lager:info("VClock ~p", [VClock]),
    lager:info("StableClock ~p", [StableClock]),
    dict:fold(fun(Dc, Clock1, Snapshot) ->
                       case dict:find(Dc,StableClock) of
                           {ok, Clock2} ->
                               lager:info("Sn ~p",[Snapshot]),
                               dict:store(Dc, min(Clock1, Clock2), Snapshot);
                           _ -> Snapshot
                       end
               end,
               dict:new(),
               VClock).
