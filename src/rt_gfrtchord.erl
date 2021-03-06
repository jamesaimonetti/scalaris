% @copyright 2013 Zuse Institute Berlin

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

%% @author Magnus Mueller <mamuelle@informatik.hu-berlin.de>
%% @doc A flexible routing table algorithm with node groups as presented in (Nagao, Shudo, 2011).
%%
%% @end
%% @version $Id$

-module(rt_gfrtchord).
-author('mamuelle@informatik.hu-berlin.de').
-vsn('$Id$').

% Additional information appended to an rt_entry()
-record(rt_entry_info, {group = other_dc :: other_dc | same_dc}).
-type rt_entry_info_t() :: #rt_entry_info{}.

% Include after type definitions for R13
-include("rt_frt_common.hrl").

-spec allowed_nodes(RT :: rt()) -> [rt_entry()].
allowed_nodes(RT) ->
    Source = get_source_node(RT),
    SourceId = rt_entry_id(Source),
    Nodes = rt_get_nodes(RT),

    % $E_{\bar{G}}$ and $E_{G}$
    {E_NG, E_G} = lists:partition(fun is_from_other_group/1, Nodes),

    % If $E_G = \emptyset$, we know that we can allow all nodes to be filtered.
    % Otherwise, check if $E_\text{leap} \neq \emptyset$.
    {OnlyNonGroupMembers, {E_a, E_b}} = case E_G of
        [] -> {true, ignore, ignore};
        [First|_] ->
            Predecessor = predecessor_node(RT, Source),
            FirstDist = get_range(SourceId, rt_entry_id(First)),

            % Compute $e_\alpha$, $e_\beta$ and the respective distances
            {{E_alpha, E_alphaDist}, {E_beta, _E_betaDist}} = lists:foldl(
                fun (Node, {{MinNode, MinDist}, {MaxNode, MaxDist}}) ->
                        NodeDist = get_range(SourceId, rt_entry_id(Node)),
                        NewE_alpha = case erlang:min(MinDist, NodeDist) of
                            MinDist -> {MinNode, MinDist};
                            _ -> {Node, NodeDist}
                        end,
                        NewE_beta = case erlang:max(MaxDist, NodeDist) of
                            MinDist -> {MaxNode, MaxDist};
                            _ -> {Node, NodeDist}
                        end,
                        {NewE_alpha, NewE_beta}
                end, {{First, FirstDist}, {First, FirstDist}}, E_G),

            % Is there any non-group entry $n$ such that $d(s, e_\alpha) \leq d(s, n)$ and
            % $n \neq s.pred$? The following line basically computes $E_leap$ and checks
            % if that set is empty.
            {lists:any(fun(P) when P =:= Predecessor -> false;
                         (N) -> get_range(SourceId, rt_entry_id(N)) >= E_alphaDist andalso
                            not is_sticky(N) andalso not is_source(N)
                      end, E_NG),
                  {E_alpha, E_beta}}
    end,

    if OnlyNonGroupMembers -> [N || N <- E_NG, not is_sticky(N),
                                               not is_source(N)];
       not OnlyNonGroupMembers andalso E_a =/= ignore andalso E_b =/= ignore ->
           [N || N <- Nodes, not is_sticky(N), not is_source(N),
                                               N =/= E_a,
                                               N =/= E_b]
    end.

-spec rt_entry_info(Node :: node:node_type(), Type :: entry_type(),
                    PredId :: key(), SuccId :: key()) -> rt_entry_info_t().
rt_entry_info(Node, _Type, _PredId, _SuccId) ->
    #rt_entry_info{group=case comm:get_ip(node:pidX(Node)) =:= comm:get_ip(comm:this()) of
            true -> same_dc;
            false -> other_dc
        end}.

%% @doc Check if the given node belongs to another group of nodes
-spec is_from_other_group(rt_entry()) -> boolean().
is_from_other_group(Node) ->
    (get_custom_info(Node))#rt_entry_info.group =:= same_dc.

%% @doc Checks whether config parameters of the rt_gfrtchord process exist and are
%%      valid.
-spec frt_check_config() -> boolean().
frt_check_config() -> true.
