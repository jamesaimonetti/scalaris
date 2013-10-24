%  @copyright 2012 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Jan Fajerski <fajerski@zib.de>
%% @doc state for one map reduce job
%% @version $Id$
-module(mr_state).
-author('fajerski@zib.de').
-vsn('$Id$').

-define(TRACE(X, Y), ok).
%% -define(TRACE(X, Y), io:format(X, Y)).

-define(DEF_OPTIONS, []).

-export([new/5
        , get/2
        , get_phase/1
        , is_acked_complete/1
        , set_acked/2
        , next_phase/1
        , is_last_phase/1
        , add_data_to_next_phase/2
        , split_slide_state/2
        , get_slide_delta/2
        , add_slide_delta/2]).

-include("scalaris.hrl").
%% for ?required macro
-include("record_helpers.hrl").

-ifdef(with_export_type_support).
-export_type([data/0, jobid/0, state/0]).
-endif.

-type(fun_term() :: {erlanon, binary()} | {jsanon, binary()}).

-type(data() :: [{string(), term()}]).

-type(phase() :: {PhaseNr::pos_integer(), map | reduce, fun_term(),
                     Input::data()}).

-type(jobid() :: nonempty_string()).

-record(state, {jobid       = ?required(state, jobid) :: jobid()
                , client    = null :: comm:mypid() | null
                , master    = null :: comm:mypid() | null
                , phases    = ?required(state, phases) :: [phase()]
                , options   = ?required(state, options) :: [mr:option()]
                , current   = 1 :: pos_integer()
                , acked     = {null, intervals:empty()} :: {null | uid:global_uid(),
                                                            intervals:interval()}
               }).

-type(state() :: #state{}).

-type(pub_props() :: client  |
                     master  |
                     jobid   |
                     phases  |
                     options |
                     current).

-spec get(state(), pub_props())          -> comm:mypid().
get(#state{client     = Client
           , master   = Master
           , jobid    = JobId
           , phases   = Phases
           , options  = Options
           , current  = Cur
          }, Key) ->
    case Key of
        client   -> Client;
        master   -> Master;
        phases   -> Phases;
        options  -> Options;
        current  -> Cur;
        jobid    -> JobId
    end.

-spec new(jobid(), comm:mypid(), comm:mypid(), data(),
          mr:job_description()) ->
    state().
new(JobId, Client, Master, InitalData, {Phases, Options}) ->
    ?TRACE("mr_state: ~p~nnew state from: ~p~n", [comm:this(), {JobId, Client,
                                                                Master,
                                                                InitalData,
                                                                {Phases,
                                                                 Options}}]),
    PhasesWithData = lists:zipwith(
            fun({MoR, Fun}, {Round, Data}) -> 
                    {Round, MoR, Fun, Data}
            end, Phases, [{1, InitalData} | [{I, []} || I <- lists:seq(2,
                                                             length(Phases))]]),
    JobOptions = merge_with_default_options(Options, ?DEF_OPTIONS),
    NewState = #state{
                  jobid      = JobId
                  , client   = Client
                  , master   = Master
                  , phases   = PhasesWithData
                  , options  = JobOptions
          },
    NewState.

-spec next_phase(state()) -> state().
next_phase(State = #state{current = Cur}) ->
    State#state{current = Cur + 1}.

-spec is_last_phase(state()) -> boolean().
is_last_phase(#state{current = Cur, phases = Phases}) ->
    Cur =:= length(Phases).

-spec get_phase(state()) -> phase().
get_phase(#state{phases = Phases, current = Cur}) ->
    lists:keyfind(Cur, 1, Phases).

-spec is_acked_complete(state()) -> boolean().
is_acked_complete(#state{acked = {_Ref, Interval}}) ->
    intervals:is_all(Interval).

-spec set_acked(state(), {uid:global_uid(), intervals:interval()}) -> state().
%% TODO find a robust way to check for the same ref but only when not resetting
set_acked(State = #state{acked = {_OldRef, _Interval}}, {NewRef, []}) ->
    State#state{acked = {NewRef, intervals:empty()}};
set_acked(State = #state{acked = {Ref, Interval}}, {Ref, NewInterval}) ->
    State#state{acked = {Ref, intervals:union(Interval, NewInterval)}}.

-spec add_data_to_next_phase(state(), [any()]) -> state().
add_data_to_next_phase(State = #state{phases = Phases, current = Cur}, NewData) ->
    {Round, MoR, Fun, Data} = lists:keyfind(Cur + 1, 1, Phases),
    State#state{phases = lists:keyreplace(Cur + 1, 1, Phases, {Round, MoR, Fun,
                                                            NewData ++ Data})}.

-spec merge_with_default_options(UserOptions::[mr:option()],
                                 DefaultOptions::[mr:option()]) ->
      JobOptions::[mr:option()].
merge_with_default_options(UserOptions, DefaultOptions) ->
    %% TODO merge by hand and skip everything that is not in DefaultOptions 
    lists:keymerge(1, 
                   lists:keysort(1, UserOptions), 
                   lists:keysort(1, DefaultOptions)).

-spec split_slide_state(state(), intervals:interval()) -> {OldState::state(),
                                                         SlideState::state()}.
split_slide_state(#state{phases = Phases} = State, Interval) ->
    {StayingPhases, SildePhases} = lists:foldl(
                    fun({Nr, MoR, Fun, Data}, {Staying, Slide}) ->
                            {New, Old} = lists:partition(
                                           fun({K, _V}) ->
                                                   intervals:in(?RT:hash_key(K),
                                                                Interval)
                                           end, Data),
                            {[{Nr, MoR, Fun, Old} | Staying],
                             [{Nr, MoR, Fun, New} | Slide]}
                    end,
                    {[],[]},
                    Phases),
    {State#state{phases = StayingPhases}, State#state{phases = SildePhases}}.

-spec get_slide_delta(state(), intervals:interval()) ->
    {RemaingState::state(), SlideData::{Round::pos_integer(), data()}}.
get_slide_delta(#state{phases = Phases, current = Cur} = State, Interval) ->
    case lists:keyfind(Cur + 1, 1, Phases) of
        false ->
            {State, []};
        {Nr, MoR, Fun, Data} ->
            {Staying, Moving} = lists:partition(
                                  fun({K, _V}) ->
                                          intervals:in(K, Interval)
                                  end, Data),
        {State#state{phases = lists:keyreplace(Nr, 1, Phases,
                                               {Nr, MoR, Fun, Staying})},
         {Nr, Moving}}
    end.

-spec add_slide_delta(state(), Data::{Round::pos_integer(), [{string(),
                                                              term()}]}) ->
    state().
add_slide_delta(#state{phases = Phases} = State, {Round, SlideData}) ->
    case lists:keyfind(Round, 1, Phases) of
        false ->
            %% no further rounds; slide data should be empty in this case
            State;
        {Round, MoR, Fun, Data} ->
            State#state{phases = lists:keyreplace(Round, 1, Phases,
                                                  {Round, MoR, Fun, SlideData ++
                                                  Data})}
    end.