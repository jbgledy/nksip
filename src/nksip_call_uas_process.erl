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

%% @private Call UAS Management: Request Processing
-module(nksip_call_uas_process).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([process/2]).

-import(nksip_call_lib, [update/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @private 
-spec process(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().
    
process(#trans{method=Method, request=Req}=UAS, Call) ->
    if
        Method=='ACK'; Method=='CANCEL' ->        
            check_missing_dialog(Method, Req, UAS, Call);
        true ->
            check_supported(Method, Req, UAS, Call)
    end.


%% @private
-spec check_supported(nksip:method(), nksip:request(), 
                      nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_supported(Method, Req, UAS, Call) ->
    #sipmsg{require=Require} = Req,
    #call{srv_id=SrvId} = Call,
    Supported = ?GET_CONFIG(SrvId, supported),
    case [T || T <- Require, not lists:member(T, Supported)] of
        [] ->
            check_event(Method, Req, UAS, Call);
        BadRequires -> 
            RequiresTxt = nklib_util:bjoin(BadRequires),
            nksip_call_uas:do_reply({bad_extension,  RequiresTxt}, UAS, Call)
    end.


%% @private
-spec check_event(nksip:method(), nksip:request(), 
                      nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_event(Method, Req, UAS, Call) when Method=='SUBSCRIBE'; Method=='PUBLISH' ->
    #sipmsg{event=Event} = Req,
    #call{srv_id=SrvId} = Call,
    SupEvents = ?GET_CONFIG(SrvId, events),
    case Event of
        {Type, _} ->
            case lists:member(Type, [<<"refer">>|SupEvents]) of
                true -> 
                    check_notify(Method, Req, UAS, Call);
                false -> 
                    nksip_call_uas:do_reply(bad_event, UAS, Call)
            end;
        _ ->
            nksip_call_uas:do_reply(bad_event, UAS, Call)
    end;
check_event(Method, Req, UAS, Call) ->
    check_notify(Method, Req, UAS, Call).


%% @private
-spec check_notify(nksip:method(), nksip:request(), 
                      nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_notify('NOTIFY', Req, UAS, Call) ->
    case nksip_subscription_lib:state(Req) of
        invalid -> 
            nksip_call_uas:do_reply({invalid_request, "Invalid Subscription-State"}, UAS, Call);
        _ -> 
            check_missing_dialog('NOTIFY', Req, UAS, Call)
    end;
check_notify(Method, Req, UAS, Call) ->
    check_missing_dialog(Method, Req, UAS, Call).


%% @private
-spec check_missing_dialog(nksip:method(), nksip:request(), 
                           nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_missing_dialog('ACK', #sipmsg{to={_, <<>>}}, UAS, Call) ->
    ?call_notice("received out-of-dialog ACK", []),
    update(UAS#trans{status=finished}, Call);
    
check_missing_dialog(Method, #sipmsg{to={_, <<>>}}, UAS, Call)
        when Method=='BYE'; Method=='INFO'; Method=='PRACK'; Method=='UPDATE';
             Method=='NOTIFY' ->
    nksip_call_uas:do_reply(no_transaction, UAS, Call);

check_missing_dialog(Method, _Req, UAS, #call{srv_id=SrvId}=Call) ->
    case SrvId:nks_sip_uas_process(UAS, Call) of
        {continue, [UAS1, Call1]} ->
            dialog(Method, UAS1#trans.request, UAS1, Call1);
        {ok, Call1} ->
            Call1
    end.


%% @private
-spec dialog(nksip:method(), nksip:request(), 
             nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

dialog(Method, Req, UAS, Call) ->
    % lager:error("DIALOG: ~p\n~p\n~p\n~p", [Method, Req, UAS, Call]),
    #sipmsg{to={_, ToTag}} = Req,
    #trans{id=Id, opts=Opts, stateless=Stateless} = UAS,
    case Stateless orelse ToTag == <<>> of
        true ->
            method(Method, Req, UAS, Call);
        false ->           
            case nksip_call_uas_dialog:request(Req, Call) of
                {ok, Call1} ->
                    method(Method, Req, UAS, Call1);
                {error, Error} when Method=='ACK' -> 
                    ?call_notice("UAS ~p 'ACK' dialog request error: ~p", 
                                 [Id, Error]),
                    UAS2 = UAS#trans{status=finished},
                    update(UAS2, Call);
                {error, Error} ->
                    UAS2 = UAS#trans{opts=[no_dialog|Opts]},
                    nksip_call_uas:do_reply(Error, UAS2, Call)
            end
    end.



%% @private
-spec method(nksip:method(), nksip:request(), 
             nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

method(Method, Req, UAS, Call) ->
    #call{srv_id=SrvId} = Call,
    case SrvId:nks_sip_uas_method(Method, Req, UAS, Call) of
        {continue, [Method1, Req1, UAS1, Call1]} ->
            case do_method(Method1, Req1, UAS1, Call1) of
                {noreply, UAS2, Call2} ->
                    call_user_sip_method(UAS2, Call2);
                {reply, Reply} ->
                    nksip_call_uas:do_reply(Reply, UAS1, Call1)
            end;
        {ok, UAS1, Call1} ->
            call_user_sip_method(UAS1, Call1)
    end.

        

%% @private
-spec call_user_sip_method(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

call_user_sip_method(#trans{method='ACK', request=Req}, #call{srv_id=SrvId}=Call) ->
    case catch SrvId:sip_ack(Req, Call) of
        ok -> ok;
        Error -> ?call_error("Error calling callback ack/1: ~p", [Error])
    end,
    Call;

call_user_sip_method(#trans{method=Method, request=Req}=UAS, #call{srv_id=SrvId}=Call) ->
    #sipmsg{to={_, ToTag}} = Req,
    Fun = case Method of
        'INVITE' when ToTag == <<>> -> sip_invite;
        'INVITE' -> sip_reinvite;
        'UPDATE' -> sip_update;
        'BYE' -> sip_bye;
        'OPTIONS' -> sip_options;
        'REGISTER' -> sip_register;
        'PRACK' -> sip_prack;
        'INFO' -> sip_info;
        'MESSAGE' -> sip_message;
        'SUBSCRIBE' when ToTag == <<>> -> sip_subscribe;
        'SUBSCRIBE' -> sip_resubscribe;
        'NOTIFY' -> sip_notify;
        'REFER' -> sip_refer;
        'PUBLISH' -> sip_publish
    end,
    case catch SrvId:Fun(Req, Call) of
        {reply, Reply} -> 
            nksip_call_uas:do_reply(Reply, UAS, Call);
        noreply -> 
            Call;
        Error -> 
            ?call_error("Error calling callback ~p/2: ~p", [Fun, Error]),
            Reply = {internal_error, "Service Error"},
            nksip_call_uas:do_reply(Reply, UAS, Call)
    end.

   



% -spec dialog(nksip:method(), nksip:request(), 
%              nksip_call:trans(), nksip_call:call()) ->
%     nksip_call:call().

% dialog(Method, Req, UAS, Call) ->
%     % lager:error("DIALOG: ~p\n~p\n~p\n~p", [Method, Req, UAS, Call]),
%     #sipmsg{to={_, ToTag}} = Req,
%     #trans{id=Id, opts=Opts, stateless=Stateless} = UAS,
%     #call{srv_id=SrvId} = Call,
%     try
%         case Stateless orelse ToTag == <<>> of
%             true ->
%                 case SrvId:nks_sip_uas_method(Method, Req, UAS, Call) of
%                     {continue, [Method1, Req1, UAS1, Call1]} ->
%                         {UAS2, Call2} = method(Method1, Req1, UAS1, Call1);
%                     {ok, UAS2, Call2} ->
%                         ok
%                 end,
%                 case SrvId:nks_sip_method(UAS2, Call2) of
%                     {reply, Reply} -> 
%                         nksip_call_uas:do_reply(Reply, UAS2, Call2);
%                     noreply -> 
%                         Call2
%                 end;
%             false ->           
%                 case nksip_call_uas_dialog:request(Req, Call) of
%                     {ok, Call1} ->
%                         case SrvId:nks_sip_uas_method(Method, Req, UAS, Call1) of
%                             {continue, [Method2, Req2, UAS2, Call2]} ->
%                                 {UAS3, Call3} = method(Method2, Req2, UAS2, Call2);
%                             {ok, UAS3, Call3} ->
%                                 ok
%                         end,
%                         case SrvId:nks_sip_method(UAS3, Call3) of
%                             {reply, Reply} -> 
%                                 nksip_call_uas:do_reply(Reply, UAS3, Call3);
%                             noreply -> 
%                                 Call3
%                         end;
%                     {error, Error} when Method=='ACK' -> 
%                         ?call_notice("UAS ~p 'ACK' dialog request error: ~p", 
%                                      [Id, Error]),
%                         UAS2 = UAS#trans{status=finished},
%                         update(UAS2, Call);
%                     {error, Error} ->
%                         UAS2 = UAS#trans{opts=[no_dialog|Opts]},
%                         nksip_call_uas:do_reply(Error, UAS2, Call)
%                 end
%         end
%     catch
%         throw:{reply, TReply} -> 
%             nksip_call_uas:do_reply(TReply, UAS, Call)
%     end.



%% @private
-spec do_method(nksip:method(), nksip:request(), 
             nksip_call:trans(), nksip_call:call()) ->
    {noreply, nksip_call:trans(), nksip_call:call()} | {reply, nksip:sipreply()}.

do_method('INVITE', _Req, UAS, Call) ->
    UAS1 = nksip_call_lib:expire_timer(expire, UAS, Call),
    {noreply, UAS1, update(UAS1, Call)};
    
do_method('ACK', _Req, UAS, Call) ->
    UAS1 = UAS#trans{status=finished},
    {noreply, UAS1, update(UAS1, Call)};

do_method('BYE', _Req, UAS, Call) ->
    {noreply, UAS, Call};

do_method('INFO', _Req, UAS, Call) ->
    {noreply, UAS, Call};
    
do_method('OPTIONS', _Req, UAS, Call) ->
    {noreply, UAS, Call};

do_method('REGISTER', Req, UAS, Call) ->
    #sipmsg{supported=Supported} = Req,
    case nksip_sipmsg:header(<<"path">>, Req, uris) of
        error ->
            {reply, invalid_request};
        [] ->
            {noreply, UAS, Call};
        _Path ->
            case lists:member(<<"path">>, Supported) of
                true -> 
                    {noreply, UAS, Call};
                false -> 
                    {reply, {bad_extension, <<"path">>}}
            end
    end;
    
do_method('UPDATE', _Req, UAS, Call) ->
    {noreply, UAS, Call};
    
do_method('SUBSCRIBE', _Req, UAS, Call) ->
    {noreply, UAS, Call};

do_method('NOTIFY', _Req, UAS, Call) ->
    {noreply, UAS, Call};

do_method('MESSAGE', _Req, UAS, Call) ->
    {noreply, UAS, Call};

do_method('REFER', #sipmsg{headers=Headers}, UAS, Call) ->
    case proplists:get_all_values(<<"refer-to">>, Headers) of
        [_ReferTo] -> 
            {noreply, UAS, Call};
        _ -> 
            {reply, invalid_request}
    end;

do_method('PUBLISH', _Req, UAS, Call) ->
    {noreply, UAS, Call};

do_method(_Method, #sipmsg{srv_id=SrvId}, _UAS, _Call) ->
    {reply, {method_not_allowed, ?GET_CONFIG(SrvId, allow)}}.

