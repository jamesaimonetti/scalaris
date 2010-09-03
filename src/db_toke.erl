%  @copyright 2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

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

%% @author Nico Kruber <kruber@zib.de>
%% @doc In-process Database using toke
%% @end
-module(db_toke).
-author('kruber@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").

-behaviour(db_beh).

-opaque(db() :: {Table::atom(), RecordChangesInterval::intervals:interval(), ChangedKeysTable::tid() | atom()}).

% Note: must include db_beh.hrl AFTER the type definitions for erlang < R13B04
% to work.
-include("db_beh.hrl").

-define(CKETS, ets).

-include("db_common.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% public functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Initializes a new database (will launch a process for it); returns the
%%      a reference to the DB.
new(Id) ->
    Dir = lists:flatten(io_lib:format("~s/~s", [config:read(db_directory),
                                  atom_to_list(node())])),
    file:make_dir(Dir),
    FileName = lists:flatten(io_lib:format("~s/db_~p.tch", [Dir, Id])),
    {ok, DB} = toke_drv:start_link(),
    case toke_drv:new(DB) of
        ok ->
            RandomName = randoms:getRandomId(),
            CKDBname = list_to_atom(string:concat("db_ck_", RandomName)), % changed keys
            case toke_drv:open(DB, FileName, [read,write,create,truncate]) of
                ok     -> {DB, intervals:empty(), ?CKETS:new(CKDBname, [ordered_set, private | ?DB_ETS_ADDITIONAL_OPS])};
                Error2 -> log:log(error, "[ TOKE ] ~p", [Error2]),
                          erlang:error({toke_failed, Error2})
            end;
        Error1 ->
            log:log(error, "[ TOKE ] ~p", [Error1]),
            erlang:error({toke_failed, Error1})
    end.

%% @doc Deletes all contents of the given DB.
close({DB, _CKInt, CKDB}) ->
    toke_drv:close(DB),
    toke_drv:delete(DB),
    toke_drv:stop(DB),
    ?CKETS:delete(CKDB).

%% @doc Gets an entry from the DB. If there is no entry with the given key,
%%      an empty entry will be returned. The first component of the result
%%      tuple states whether the value really exists in the DB.
get_entry2({DB, _CKInt, _CKDB}, Key) ->
    case toke_drv:get(DB, erlang:term_to_binary(Key)) of
        not_found -> {false, db_entry:new(Key)};
        Entry     -> {true, erlang:binary_to_term(Entry)}
    end.

%% @doc Inserts a complete entry into the DB.
set_entry(State = {DB, CKInt, CKDB}, Entry) ->
    Key = db_entry:get_key(Entry),
    case intervals:in(Key, CKInt) of
        false -> ok;
        _     -> ?CKETS:insert(CKDB, {Key})
    end,
    ok = toke_drv:insert(DB, erlang:term_to_binary(Key),
                         erlang:term_to_binary(Entry)),
    State.

%% @doc Updates an existing (!) entry in the DB.
update_entry(State, Entry) ->
    set_entry(State, Entry).

%% @doc Removes all values with the given entry's key from the DB.
delete_entry(State = {DB, CKInt, CKDB}, Entry) ->
    Key = db_entry:get_key(Entry),
    case intervals:in(Key, CKInt) of
        false -> ok;
        _     -> ?CKETS:insert(CKDB, {Key})
    end,
    toke_drv:delete(DB, erlang:term_to_binary(Key)),
    State.

%% @doc Returns the number of stored keys.
get_load({DB, _CKInt, _CKDB}) ->
    % TODO: not really efficient (maybe store the load in the DB?)
    toke_drv:fold(fun (_K, _V, Acc) -> Acc + 1 end, 0, DB).

%% @doc Adds all db_entry objects in the Data list.
add_data(State = {DB, CKInt, CKDB}, Data) ->
    % check once for the 'common case'
    case intervals:is_empty(CKInt) of
        true -> ok;
        _    -> [?CKETS:insert(CKDB, {db_entry:get_key(Entry)}) ||
                   Entry <- Data,
                   intervals:in(db_entry:get_key(Entry), CKInt)]
    end,
    % -> do not use set_entry (no further checks for changed keys necessary)
    lists:foldl(
      fun(DBEntry, _) ->
              ok = toke_drv:insert(DB,
                                   erlang:term_to_binary(db_entry:get_key(DBEntry)),
                                   erlang:term_to_binary(DBEntry))
      end, null, Data),
    State.

%% @doc Splits the database into a database (first element) which contains all
%%      keys in MyNewInterval and a list of the other values (second element).
%%      Note: removes all keys not in MyNewInterval from the list of changed
%%      keys!
split_data(State = {DB, _CKInt, CKDB}, MyNewInterval) ->
    % first collect all toke keys to remove from my db (can not delete while doing fold!)
    F = fun(_K, DBEntry_, HisList) ->
                DBEntry = erlang:binary_to_term(DBEntry_),
                case intervals:in(db_entry:get_key(DBEntry), MyNewInterval) of
                    true -> HisList;
                    _    -> [DBEntry | HisList]
                end
        end,
    HisList = toke_drv:fold(F, [], DB),
    % delete empty entries from HisList and remove all entries in HisList from the DB
    HisListFilt =
        lists:foldl(
          fun(DBEntry, L) ->
                  toke_drv:delete(DB, erlang:term_to_binary(db_entry:get_key(DBEntry))),
                  ?CKETS:delete(CKDB, db_entry:get_key(DBEntry)),
                  case db_entry:is_empty(DBEntry) of
                      false -> [DBEntry | L];
                      _     -> L
                  end
          end, [], HisList),
    {State, HisListFilt}.

%% @doc Gets all custom objects (created by ValueFun(DBEntry)) from the DB for
%%      which FilterFun returns true.
get_entries({DB, _CKInt, _CKDB}, FilterFun, ValueFun) ->
    F = fun (_Key, DBEntry_, Data) ->
                 DBEntry = erlang:binary_to_term(DBEntry_),
                 case FilterFun(DBEntry) of
                     true -> [ValueFun(DBEntry) | Data];
                     _    -> Data
                 end
        end,
    toke_drv:fold(F, [], DB).

%% @doc Deletes all objects in the given Range or (if a function is provided)
%%      for which the FilterFun returns true from the DB.
delete_entries(State = {DB, CKInt, CKDB}, FilterFun) when is_function(FilterFun) ->
    % first collect all toke keys to delete (can not delete while doing fold!)
    F = fun(KeyToke, DBEntry_, ToDelete) ->
                DBEntry = erlang:binary_to_term(DBEntry_),
                case FilterFun(DBEntry) of
                    false -> ToDelete;
                    _     ->
                        Key = db_entry:get_key(DBEntry),
                        case intervals:in(Key, CKInt) of
                            true -> ?CKETS:insert(CKDB, {Key});
                            _    -> ok
                        end,
                        [KeyToke | ToDelete]
                end
        end,
    KeysToDelete = toke_drv:fold(F, [], DB),
    % delete all entries with these keys
    [toke_drv:delete(DB, KeyToke) || KeyToke <- KeysToDelete],
    State;
delete_entries(State, Interval) ->
    delete_entries(State, fun(E) ->
                                  intervals:in(db_entry:get_key(E), Interval)
                          end).

%% @doc Returns all DB entries.
get_data({DB, _CKInt, _CKDB}) ->
    toke_drv:fold(fun (_K, DBEntry, Acc) ->
                           [erlang:binary_to_term(DBEntry) | Acc]
                  end, [], DB).
