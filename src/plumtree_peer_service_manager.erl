%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Helium Systems, Inc.  All Rights Reserved.
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

-module(plumtree_peer_service_manager).

-define(TBL, cluster_state).

-behaviour(gen_server).

%% API
-export([start_link/0,
         members/0,
         get_local_state/0,
         get_actor/0,
         update_state/1,
         delete_state/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {}).

-include("plumtree.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Return membership list.
members() ->
    gen_server:call(?MODULE, members, infinity).

%% @doc Return local node's view of cluster membership.
get_local_state() ->
    gen_server:call(?MODULE, get_local_state, infinity).

%% @doc Return local node's current actor.
get_actor() ->
    gen_server:call(?MODULE, get_actor, infinity).

%% @doc Update cluster state.
update_state(State) ->
    gen_server:call(?MODULE, {update_state, State}, infinity).

%% @doc Delete state.
delete_state() ->
    gen_server:call(?MODULE, delete_state, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init([]) -> {ok, #state{}}.
init([]) ->
    lager:info("Initializing..."),
    %% setup ETS table for cluster_state
    _ = try ets:new(?TBL, [named_table, public, set, {keypos, 1}]) of
            _Res ->
                gen_actor(),
                maybe_load_state_from_disk(),
                ok
        catch
            error:badarg ->
                lager:warning("Table ~p already exists", [?TBL])
        end,
    {ok, #state{}}.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) -> {reply, term(), #state{}}.
handle_call(members, _From, State) ->
    Result = case hd(ets:lookup(?TBL, cluster_state)) of
        {cluster_state, ClusterState} ->
            {ok, ?SET:value(ClusterState)};
        _Else ->
            {error, _Else}
    end,
    {reply, Result, State};
handle_call(get_local_state, _From, State) ->
    Result = case hd(ets:lookup(?TBL, cluster_state)) of
        {cluster_state, ClusterState} ->
            {ok, ClusterState};
        _Else ->
            {error, _Else}
    end,
    {reply, Result, State};
handle_call(get_actor, _From, State) ->
    Result = case hd(ets:lookup(?TBL, actor)) of
        {actor, Actor} ->
            {ok, Actor};
        _Else ->
            {error, _Else}
    end,
    {reply, Result, State};
handle_call({update_state, NewState}, _From, State) ->
    persist_state(NewState),
    {reply, ok, State};
handle_call(delete_state, _From, State) ->
    delete_state_from_disk(),
    {reply, ok, State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(Msg, State) ->
    lager:warning("Unhandled messages: ~p", [Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
add_self() ->
    Initial = ?SET:new(),
    Actor = ets:lookup(?TBL, actor),
    {ok, LocalState} = ?SET:update({add, node()}, Actor, Initial),
    persist_state(LocalState).

%% @private
gen_actor() ->
    Node = atom_to_list(node()),
    {M, S, U} = now(),
    TS = integer_to_list(M * 1000 * 1000 * 1000 * 1000 + S * 1000 * 1000 + U),
    Term = Node ++ TS,
    Actor = crypto:hash(sha, Term),
    ets:insert(?TBL, {actor, Actor}).

%% @private
data_root() ->
    case application:get_env(plumtree, plumtree_data_dir) of
        {ok, PRoot} ->
            filename:join(PRoot, "peer_service");
        undefined ->
            undefined
    end.

%% @private
write_state_to_disk(State) ->
    case data_root() of
        undefined ->
            ok;
        Dir ->
            File = filename:join(Dir, "cluster_state"),
            ok = filelib:ensure_dir(File),
            lager:info("writing state ~p to disk ~p",
                       [State, ?SET:to_binary(State)]),
            ok = file:write_file(File, ?SET:to_binary(State))
    end.

%% @private
delete_state_from_disk() ->
    case data_root() of
        undefined ->
            ok;
        Dir ->
            File = filename:join(Dir, "cluster_state"),
            ok = filelib:ensure_dir(File),
            case file:delete(File) of
                ok ->
                    lager:info("Leaving cluster, removed cluster_state");
                {error, Reason} ->
                    lager:info("Unable to remove cluster_state for reason ~p", [Reason])
            end
    end.

%% @private
maybe_load_state_from_disk() ->
    case data_root() of
        undefined ->
            add_self();
        Dir ->
            case filelib:is_regular(filename:join(Dir, "cluster_state")) of
                true ->
                    {ok, Bin} = file:read_file(filename:join(Dir, "cluster_state")),
                    {ok, State} = ?SET:from_binary(Bin),
                    lager:info("read state from file ~p~n", [State]),
                    persist_state(State);
                false ->
                    add_self()
            end
    end.

%% @private
persist_state(State) ->
    write_state_to_disk(State),
    ets:insert(?TBL, {cluster_state, State}).
