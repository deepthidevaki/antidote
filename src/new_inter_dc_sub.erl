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
-module(new_inter_dc_sub).
-behaviour(gen_server).
-include("antidote.hrl").

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3, start_link/0, add_dc/1]).
-record(state, {connections :: [zmq_socket()]}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) -> {ok, #state{connections = []}}.

add_dc(Publishers) -> gen_server:call(?MODULE, {add_dc, Publishers}).

handle_call({add_dc, Publishers}, _From, State) ->
  F = fun(Address) ->
    Socket = zmq_utils:create_connect_socket(sub, true, Address),
    ok = zmq_utils:sub_filter(Socket, <<>>), %% TODO: actually subscribe only to partitions this node is responsible for
    Socket
  end,
  Sockets = lists:map(F, Publishers),
  {reply, ok, State#state{connections = Sockets ++ State#state.connections}}.

handle_info({zmq, _Socket, BinaryMsg, _Flags}, State) ->
  Txn = binary_to_term(BinaryMsg),
  ok = new_inter_dc_sub_vnode:deliver_message(Txn),
  {noreply, State}.

handle_cast(_Request, State) -> {noreply, State}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
terminate(_Reason, State) -> lists:foreach(fun zmq_utils:close_socket/1, State#state.connections).