%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc NkSIP REFER Plugin Callbacks
-module(nksip_refer_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([sip_refer/2, sip_subscribe/2, sip_notify/2]).
-export([sip_refer/3, sip_refer_update/3]).
-export([nks_sip_parse_uac_opts/2, nks_sip_call/3, nks_sip_uac_reply/3]).


%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip].


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin ~p started (~s)", [?MODULE, Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin ~p stopped (~s)", [?MODULE, Name]),
    {ok, Config}.



%% ===================================================================
%% Specific
%% ===================================================================


% @doc Called when a REFER request arrives
-spec sip_refer(ReferTo::nksip:uri(), Req::nksip:request(), Call::nksip:call()) ->
        boolean().

sip_refer(_ReferTo, _Req, _Call) ->
    false.
    

% @doc Called when a REFER event is received
-spec sip_refer_update(SubsHandle, Status, Call) ->
    ok
    when SubsHandle :: nksip:handle(), 
         Status :: init | active | {notify, binary()} | terminated,
         Call :: nksip:call().

sip_refer_update(_SubsHandle, _Status, _Call) ->
    ok.



%% ===================================================================
%% SIP Core
%% ===================================================================


%% @doc Called to parse specific UAC options
-spec nks_sip_parse_uac_opts(nksip:request(), nksip:optslist()) ->
    {error, term()}|{continue, list()}.

nks_sip_parse_uac_opts(Req, Opts) ->
    case lists:keyfind(refer_subscription_id, 1, Opts) of
        {refer_subscription_id, Refer} when is_binary(Refer) ->
            {continue, [Req, Opts]};
        {refer_subscription_id, _} ->
            {error, {invalid_config, refer_subscription_id}};
        false ->
            {continue, [Req, Opts]} 
    end.


%% @private 
-spec sip_refer(nksip:request(), nksip:call()) ->
    {reply, nksip:sipreply()}.

sip_refer(Req, Call) ->
    {reply, nksip_refer:process(Req, Call)}.


%% @private 
-spec sip_subscribe(nksip:request(), nksip:call()) ->
    {reply, nksip:sipreply()}.

sip_subscribe(Req, _Call) ->
    case Req#sipmsg.event of
        {<<"refer">>, [{<<"id">>, _ReferId}]} ->
            {reply, ok};
        _ ->
            continue
    end.


%% @private 
-spec sip_notify(nksip:request(), nksip:call()) ->
    {reply, nksip:sipreply()}.

sip_notify(Req, Call) ->
    case Req#sipmsg.event of
        {<<"refer">>, [{<<"id">>, _ReferId}]} ->
            {ok, Body} = nksip_request:body(Req),
            SubsHandle = nksip_subscription_lib:get_handle(Req),
            #call{srv_id=SrvId} = Call,
            catch SrvId:sip_refer_update(SubsHandle, {notify, Body}, Call),
            {reply, ok};
        _ ->
            continue
    end.


%% @doc This plugin callback function is used to call application-level 
%% Service callbacks.
-spec nks_sip_call(atom(), list(), nksip:srv_id()) ->
    continue.

nks_sip_call(sip_dialog_update, 
          [
            {
                subscription_status, 
                Status, 
                {user_subs, #subscription{event={<<"refer">>, _}}, _}=Subs
            }, 
            _Dialog, Call
          ], 
          _SrvId) ->
    #call{srv_id=SrvId} = Call,
    {ok, SubsId} = nksip_subscription:get_handle(Subs),
    Status1 = case Status of
        init -> init;
        active -> active;
        middle_timer -> middle_timer;
        {terminated, _} -> terminated
    end,
    catch SrvId:sip_refer_update(SubsId, Status1, Call),
    continue;

nks_sip_call(_, _, _) ->
    continue.



    %% @doc Called when the UAC must send a reply to the user
-spec nks_sip_uac_reply({req, nksip:request()} | {resp, nksip:response()} | {error, term()}, 
                     nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip:call()} | {continue, list()}.

nks_sip_uac_reply({resp, Resp}, #trans{from={srv, _}, opts=Opts}=UAC, Call) ->
    #sipmsg{class={resp, Code, Reason}} = Resp,
    case nklib_util:get_value(refer_subscription_id, Opts) of
        undefined -> 
            ok;
        SubsId ->
            Sipfrag = <<
                "SIP/2.0 ", (nklib_util:to_binary(Code))/binary, 32,
                Reason/binary
            >>,
            NotifyOpts = [
                async, 
                {content_type, <<"message/sipfrag;version=2.0">>}, 
                {body, Sipfrag},
                {subscription_state, 
                    case Code>=200 of 
                        true -> {terminated, noresource}; 
                        false -> active
                    end}
            ],
            nksip_uac:notify(SubsId, NotifyOpts)
    end,
    {continue, [{resp, Resp}, UAC, Call]};

nks_sip_uac_reply(Class, UAC, Call) ->
    {continue, [Class, UAC, Call]}.

