%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI (Abstract) Map-Reduce Service==
%%% This module provides an Erlang behaviour for fault-tolerant,
%%% database agnostic map-reduce.  See the hexpi test for example usage.
%%% @end
%%%
%%% BSD LICENSE
%%% 
%%% Copyright (c) 2012-2013, Michael Truog <mjtruog at gmail dot com>
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%% 
%%%     * Redistributions of source code must retain the above copyright
%%%       notice, this list of conditions and the following disclaimer.
%%%     * Redistributions in binary form must reproduce the above copyright
%%%       notice, this list of conditions and the following disclaimer in
%%%       the documentation and/or other materials provided with the
%%%       distribution.
%%%     * All advertising materials mentioning features or use of this
%%%       software must display the following acknowledgment:
%%%         This product includes software developed by Michael Truog
%%%     * The name of the author may not be used to endorse or promote
%%%       products derived from this software without specific prior
%%%       written permission
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
%%% CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
%%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
%%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
%%% SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
%%% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
%%% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
%%% DAMAGE.
%%%
%%% @author Michael Truog <mjtruog [at] gmail (dot) com>
%%% @copyright 2012-2013 Michael Truog
%%% @version 1.3.1 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_service_map_reduce).
-author('mjtruog [at] gmail (dot) com').

-behaviour(cloudi_service).

%% cloudi_service callbacks
-export([cloudi_service_init/3,
         cloudi_service_handle_request/11,
         cloudi_service_handle_info/3,
         cloudi_service_terminate/2]).

-include_lib("cloudi_core/include/cloudi_logger.hrl").
-include_lib("cloudi_core/include/cloudi_service.hrl").

-define(DEFAULT_MAP_REDUCE_MODULE,     undefined).
-define(DEFAULT_MAP_REDUCE_ARGUMENTS,         []).
-define(DEFAULT_CONCURRENCY,                 1.0). % schedulers multiplier

-record(state,
    {
        map_reduce_module,
        map_reduce_state,
        map_count,
        map_requests       % trans_id -> send_args
    }).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

%%%------------------------------------------------------------------------
%%% Callback functions from behavior
%%%------------------------------------------------------------------------

-callback cloudi_service_map_reduce_new(ModuleReduceArgs :: list(),
                                        Prefix :: string(),
                                        Dispatcher :: pid()) ->
    {'ok', ModuleReduceState :: any()} |
    {'error', Reason :: any()}.

-callback cloudi_service_map_reduce_send(ModuleReduceState :: any(),
                                         Dispatcher :: pid()) ->
    {'ok', SendArgs :: list(), NewModuleReduceState :: any()} |
    {'done', NewModuleReduceState :: any()} |
    {'error', Reason :: any()}.

-callback cloudi_service_map_reduce_resend(SendArgs :: list(),
                                           ModuleReduceState :: any()) ->
    {'ok', NewSendArgs :: list(), NewModuleReduceState :: any()} |
    {'error', Reason :: any()}.

-callback cloudi_service_map_reduce_recv(SendArgs :: list(),
                                         ResponseInfo :: any(),
                                         Response :: any(),
                                         Timeout :: non_neg_integer(),
                                         TransId :: binary(),
                                         ModuleReduceState :: any(),
                                         Dispatcher :: pid()) ->
    {'ok', NewModuleReduceState :: any()} |
    {'done', NewModuleReduceState :: any()} |
    {'error', Reason :: any()}.

-callback cloudi_service_map_reduce_info(Request :: any(),
                                         ModuleReduceState :: any(),
                                         Dispatcher :: pid()) ->
    {'ok', NewModuleReduceState :: any()} |
    {'done', NewModuleReduceState :: any()} |
    {'error', Reason :: any()}.

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_service
%%%------------------------------------------------------------------------

cloudi_service_init(Args, Prefix, Dispatcher) ->
    Defaults = [
        {map_reduce,             ?DEFAULT_MAP_REDUCE_MODULE},
        {map_reduce_args,        ?DEFAULT_MAP_REDUCE_ARGUMENTS},
        {concurrency,            ?DEFAULT_CONCURRENCY}],
    [MapReduceModule, MapReduceArguments, Concurrency] =
        cloudi_proplists:take_values(Defaults, Args),
    true = is_atom(MapReduceModule) and (MapReduceModule /= undefined),
    true = is_list(MapReduceArguments),
    case application:load(MapReduceModule) of
        ok ->
            ok = cloudi_x_reltool_util:application_start(MapReduceModule);
        {error, {already_loaded, MapReduceModule}} ->
            ok = cloudi_x_reltool_util:application_start(MapReduceModule);
        {error, _} ->
            ok = cloudi_x_reltool_util:module_loaded(MapReduceModule)
    end,
    cloudi_service:self(Dispatcher) !
        {init, Prefix, MapReduceModule, MapReduceArguments, Concurrency},
    {ok, undefined}.

cloudi_service_handle_request(_Type, _Name, _Pattern, _RequestInfo, _Request,
                              _Timeout, _Priority, _TransId, _Pid,
                              State, _Dispatcher) ->
    {reply, <<>>, State}.

cloudi_service_handle_info({init, Prefix,
                            MapReduceModule, MapReduceArguments, Concurrency},
                           undefined, Dispatcher) ->
    % cloudi_service_map_reduce_new/3 execution occurs outside of
    % cloudi_service_init/3 to allow send_sync and recv_sync function calls
    % because no Erlang process linking/spawning/etc. should be occurring,
    % only algorithmic initialization
    case MapReduceModule:cloudi_service_map_reduce_new(MapReduceArguments,
                                                       Prefix,
                                                       Dispatcher) of
        {ok, MapReduceState} ->
            MapCount = cloudi_configurator:concurrency(Concurrency),
            case map_send(MapCount, dict:new(), Dispatcher,
                          MapReduceModule, MapReduceState) of
                {ok, MapRequests, NewMapReduceState} ->
                    {noreply, #state{map_reduce_module = MapReduceModule,
                                     map_reduce_state = NewMapReduceState,
                                     map_count = MapCount,
                                     map_requests = MapRequests}};
                {error, _} = Error ->
                    {stop, Error, undefined}
            end;
        {error, _} = Error ->
            {stop, Error, undefined}
    end;

cloudi_service_handle_info(#timeout_async_active{trans_id = TransId} = Request,
                           #state{map_reduce_module = MapReduceModule,
                                  map_reduce_state = MapReduceState,
                                  map_requests = MapRequests} = State,
                           Dispatcher) ->
    case dict:find(TransId, MapRequests) of
        {ok, [_ | SendArgs]} ->
            NextMapRequests = dict:erase(TransId, MapRequests),
            case MapReduceModule:cloudi_service_map_reduce_resend(
                [Dispatcher | SendArgs], MapReduceState) of
                {ok, NewSendArgs, NewMapReduceState} ->
                    case erlang:apply(cloudi_service, send_async_active,
                                      NewSendArgs) of
                        {ok, NewTransId} ->
                            NewMapRequests = dict:store(NewTransId,
                                                        NewSendArgs,
                                                        NextMapRequests),
                            {noreply,
                             State#state{map_reduce_state = NewMapReduceState,
                                         map_requests = NewMapRequests}};
                        {error, _} = Error ->
                            {stop, Error, State}
                    end;
                {error, _} = Error ->
                    {stop, Error, State}
            end;
        error ->
            cloudi_service_map_reduce_info(Request, State, Dispatcher)
    end;

cloudi_service_handle_info(#return_async_active{response_info = ResponseInfo,
                                                response = Response,
                                                timeout = Timeout,
                                                trans_id = TransId} = Request,
                           #state{map_reduce_module = MapReduceModule,
                                  map_reduce_state = MapReduceState,
                                  map_requests = MapRequests} = State,
                           Dispatcher) ->
    case dict:find(TransId, MapRequests) of
        {ok, [_ | SendArgs]} ->
            case MapReduceModule:cloudi_service_map_reduce_recv(
                [Dispatcher | SendArgs], ResponseInfo, Response,
                Timeout, TransId, MapReduceState, Dispatcher) of
                {ok, NextMapReduceState} ->
                    case map_send(dict:erase(TransId, MapRequests),
                                  Dispatcher, MapReduceModule,
                                  NextMapReduceState) of
                        {ok, NewMapRequests, NewMapReduceState} ->
                            {noreply,
                             State#state{map_reduce_state = NewMapReduceState,
                                         map_requests = NewMapRequests}};
                        {error, _} = Error ->
                            {stop, Error, State}
                    end;
                {done, NewMapReduceState} ->
                    NewMapRequests = dict:erase(TransId, MapRequests),
                    NewState = State#state{map_reduce_state = NewMapReduceState,
                                           map_requests = NewMapRequests},
                    case dict:size(NewMapRequests) of
                        0 ->
                            {stop, shutdown, NewState};
                        _ ->
                            {noreply, NewState}
                    end;
                {error, _} = Error ->
                    {stop, Error, State}
            end;
        error ->
            cloudi_service_map_reduce_info(Request, State, Dispatcher)
    end;

cloudi_service_handle_info(Request, State, Dispatcher) ->
    cloudi_service_map_reduce_info(Request, State, Dispatcher).

cloudi_service_terminate(_, _) ->
    ok.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

map_send(MapRequests, Dispatcher, MapReduceModule, MapReduceState) ->
    map_send(1, MapRequests, Dispatcher, MapReduceModule, MapReduceState).

map_send(0, MapRequests, _Dispatcher, _MapReduceModule, MapReduceState) ->
    {ok, MapRequests, MapReduceState};

map_send(Count, MapRequests, Dispatcher, MapReduceModule, MapReduceState) ->
    case MapReduceModule:cloudi_service_map_reduce_send(MapReduceState,
                                                        Dispatcher) of
        {ok, SendArgs, NewMapReduceState} ->
            case erlang:apply(cloudi_service, send_async_active, SendArgs) of
                {ok, TransId} ->
                    map_send(Count - 1,
                             dict:store(TransId, SendArgs, MapRequests),
                             Dispatcher, MapReduceModule, NewMapReduceState);
                {error, _} = Error ->
                    Error
            end;
        {done, NewMapReduceState} ->
            {ok, MapRequests, NewMapReduceState};
        {error, _} = Error ->
            Error
    end.

cloudi_service_map_reduce_info(Request,
                               #state{map_reduce_module = MapReduceModule,
                                      map_reduce_state = MapReduceState,
                                      map_requests = MapRequests} = State,
                               Dispatcher) ->
    case MapReduceModule:cloudi_service_map_reduce_info(Request,
                                                        MapReduceState,
                                                        Dispatcher) of
        {ok, NewMapReduceState} ->
            {noreply, State#state{map_reduce_state = NewMapReduceState}};
        {done, NewMapReduceState} ->
            NewState = State#state{map_reduce_state = NewMapReduceState},
            case dict:size(MapRequests) of
                0 ->
                    {stop, shutdown, NewState};
                _ ->
                    {noreply, NewState}
            end;
        {error, _} = Error ->
            {stop, Error, State}
    end.

