% @copyright 2013-2014 Zuse Institute Berlin,

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
%% @doc    DB back-end using tokyo cabinet via toke.
%%         Two keys K and L are considered equal if they match, i.e. K =:= L
%%
%%         To use this backend you have to install
%%         Tokyo Cabinet [http://fallabs.com/tokyocabinet] and
%%         Toke [http://hg.opensource.lshift.net/toke/] (a simple Erlang
%%         wrapper for Tokyo Cabinets hash API tchdb*).
%%         For development Tokyo Cabinet V1.4.48-1 and the at-the-time
%%         latest commit to the toke-repository (f178e55bb6b5) was used.
%%
%%         After building and installing Tokyo Cabinet and toke
%%         rerun configure with --enable-toke. configure assumes that you
%%         installed toke in your erlang's lib directory, i.e.
%%         `<erlang_dir>/lib/toke' or `<erlang_dir>/lib/toke-<version>'. If you
%%         used a different directory, e.g. /home/scalaris/apps/toke, you have
%%         to provide the path to configure:
%%
%%         `./configure --enable-toke=/home/scalaris/apps/toke/'
%%
%%         Rerun make and you can use db_toke.
%% @end
%% @version $Id$
-module(db_toke).
-author('fajerski@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").

-behaviour(db_backend_beh).

-define(TRACE(_X, _Y), ok).
%% -define(TRACE(X, Y), ct:pal(X, Y)).

-define(IN(E), erlang:term_to_binary(E, [{minor_version, 1}])).
-define(OUT(E), erlang:binary_to_term(E)).

%% primitives
-export([new/1, open/1, close/1, close_and_delete/1,
         put/2, get/2, delete/2]).
%% db info
-export([get_name/1, get_load/1]).

%% iteration
-export([foldl/3, foldl/4, foldl/5]).
-export([foldr/3, foldr/4, foldr/5]).

-type db() :: {DB::pid(), FileName::nonempty_string()}.
-type key() :: db_backend_beh:key(). %% '$end_of_table' is not allowed as key() or else iterations won't work!
-type entry() :: db_backend_beh:entry().

-ifdef(with_export_type_support).
-export_type([db/0]).
-endif.

%% @doc Creates new DB handle named DBName.
-spec new(DBName::nonempty_string()) -> db().
new(DBName) ->
    Dir = util:make_filename(atom_to_list(node())),
    FullDir = [config:read(db_directory), "/", Dir],
    _ = case file:make_dir(FullDir) of
        ok -> ok;
        {error, eexist} -> ok;
        {error, Error} -> erlang:exit({db_toke, 'cannot create dir', FullDir, Error})
    end,
    {_Now_Ms, _Now_s, Now_us} = Now = os:timestamp(),
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:now_to_local_time(Now),
    FileBaseName = util:make_filename(
                     io_lib:format("db_~s_~B~B~B-~B~B~B\.~B.tch",
                                   [DBName, Year, Month, Day, Hour, Minute, Second, Now_us])),
    FullFileName = lists:flatten([FullDir, "/", FileBaseName]),
    new_db(FullFileName, [read, write, create, truncate]).

%% @doc Open a previously existing database.
-spec open(DBName::nonempty_string()) -> db().
open(FileName) ->
    new_db(FileName, [read, write]).

-spec new_db(FileName::string(),
             TokeOptions::[read | write | create | truncate | no_lock |
                           lock_no_block | sync_on_transaction]) -> db().
new_db(FileName, TokeOptions) ->
    DB = case toke_drv:start_link() of
        {ok, Pid} -> Pid;
        ignore ->
            log:log(error, "[ Node ~w:db_toke ] process start returned
                    'ignore'", [self()]),
            erlang:error({toke_failed, drv_start_ignore});
        {error, Error} ->
            log:log(error, "[ Node ~w:db_toke ] ~.0p", [self(), Error]),
            erlang:error({toke_failed, Error})
    end,
    case toke_drv:new(DB) of
        ok ->
            case toke_drv:open(DB, FileName, TokeOptions) of
                ok -> {DB, FileName};
                Error2 ->
                    log:log(error, "[ Node ~w:db_toke ] ~.0p", [self(), Error2]),
                    erlang:error({toke_failed, Error2})
            end;
        Error1 ->
            log:log(error, "[ Node ~w:db_toke ] ~.0p", [self(), Error1]),
            erlang:error({toke_failed, Error1})
    end.

%% @doc Closes the DB named DBName
-spec close(DB::db()) -> true.
close({DB, _FileName}) ->
    toke_drv:close(DB),
    toke_drv:delete(DB),
    toke_drv:stop(DB).

%% @doc Closes and deletes the DB named DBName
-spec close_and_delete(DB::db()) -> true.
close_and_delete({_DB, FileName} = State) ->
    close(State),
    case file:delete(FileName) of
        ok -> ok;
        {error, Reason} ->
            log:log(error, "[ Node ~w:db_toke ] deleting ~.0p failed: ~.0p",
                    [self(), FileName, Reason])
    end.


%% @doc Saves arbitrary tuple Entry in DB DBName and returns the new DB.
%%      The key is expected to be the first element of Entry.
-spec put(DB::db(), Entry::entry()) -> db().
put({DB, _FileName} = State, Entry) ->
    toke_drv:insert(DB, ?IN(element(1, Entry)), ?IN(Entry)),
    State.

%% @doc Returns the entry that corresponds to Key or {} if no such tuple exists.
-spec get(DB::db(), Key::key()) -> entry() | {}.
get({DB, _FileName}, Key) ->
    case toke_drv:get(DB, ?IN(Key)) of
        not_found -> {};
        Entry -> ?OUT(Entry)
    end.

%% @doc Deletes the tuple saved under Key and returns the new DB.
%%      If such a tuple does not exists nothing is changed.
-spec delete(DB::db(), Key::key()) -> db().
delete({DB, _FileName} = State, Key) ->
    toke_drv:delete(DB, ?IN(Key)),
    State.

%% @doc Returns the name of the DB specified in @see new/1.
-spec get_name(DB::db()) -> nonempty_string().
get_name({_DB, FileName}) ->
    FileName.

%% @doc Returns the current load (i.e. number of stored tuples) of the DB.
-spec get_load(DB::db()) -> non_neg_integer().
get_load({DB, _FileName}) ->
    %% TODO: not really efficient (maybe store the load in the DB?)
    toke_drv:fold(fun (_K, _V, Load) -> Load + 1 end, 0, DB).

%% @doc Equivalent to toke_drv:fold(Fun, Acc0, DB).
%%      Returns a potentially larger-than-memory dataset. Use with care.
-spec foldl(DB::db(), Fun::fun((Key::key(), AccIn::A) -> AccOut::A), Acc0::A) -> Acc1::A.
foldl(State, Fun, Acc) ->
    foldl_helper(State, Fun, Acc, all, -1).

%% @equiv foldl(DB, Fun, Acc0, Interval, get_load(DB))
%% @doc   Returns a potentially larger-than-memory dataset. Use with care.
-spec foldl(DB::db(), Fun::fun((Key::key(), AccIn::A) -> AccOut::A), Acc0::A,
                               Interval::db_backend_beh:interval()) -> Acc1::A.
foldl(State, Fun, Acc, Interval) ->
    foldl_helper(State, Fun, Acc, Interval, -1).

%% @doc foldl iterates over DB and applies Fun(Entry, AccIn) to every element
%%      encountered in Interval. On the first call AccIn == Acc0. The iteration
%%      stops as soon as MaxNum elements have been encountered.
%%      Returns a potentially larger-than-memory dataset. Use with care.
-spec foldl(DB::db(), Fun::fun((Key::key(), AccIn::A) -> AccOut::A), Acc0::A,
                               Intervall::db_backend_beh:interval(), MaxNum::non_neg_integer()) -> Acc1::A.
foldl(State, Fun, Acc, Interval, MaxNum) ->
    %% HINT
    %% Fun can only be applied in a second pass. It could do a delete (or other
    %% write op) and toke can not handle writes whiles folding.
    %% Since we reversed the order while accumulating reverse it by using lists
    %% fold but "from the other side"
    foldl_helper(State, Fun, Acc, Interval, MaxNum).

%% @private this helper enables us to use -1 as MaxNum. MaxNum == -1 signals that all
%%          data is to be retrieved.
-spec foldl_helper(DB::db(), Fun::fun((Key::key(), AccIn::A) -> AccOut::A), Acc0::A,
                               Intervall::db_backend_beh:interval(), MaxNum::integer()) -> Acc1::A.
foldl_helper({DB, _FileName}, Fun, Acc, Interval, MaxNum) ->
    Keys = get_all_keys(DB, Interval, MaxNum),
    lists:foldr(Fun, Acc, Keys).

%% @doc makes a foldr over the whole dataset.
%%      Returns a potentially larger-than-memory dataset. Use with care.
-spec foldr(DB::db(), Fun::fun((Key::key(), AccIn::A) -> AccOut::A), Acc0::A) -> Acc1::A.
foldr(State, Fun, Acc) ->
    foldr_helper(State, Fun, Acc, all, -1).

%% @equiv foldr(DB, Fun, Acc0, Interval, get_load(DB))
%% @doc   Returns a potentially larger-than-memory dataset. Use with care.
-spec foldr(DB::db(), Fun::fun((Key::key(), AccIn::A) -> AccOut::A), Acc0::A,
                               Interval::db_backend_beh:interval()) -> Acc1::A.
foldr(State, Fun, Acc, Interval) ->
    foldr_helper(State, Fun, Acc, Interval, -1).

%% @doc foldr iterates over DB and applies Fun(Entry, AccIn) to every element
%%      encountered in Interval. On the first call AccIn == Acc0. The iteration
%%      stops as soon as MaxNum elements have been encountered.
%%      Returns a potentially larger-than-memory dataset. Use with care.
-spec foldr(DB::db(), Fun::fun((Key::key(), AccIn::A) -> AccOut::A), Acc0::A,
                               Intervall::db_backend_beh:interval(), MaxNum::non_neg_integer()) -> Acc1::A.
foldr(State, Fun, Acc, Interval, MaxNum) ->
    foldr_helper(State, Fun, Acc, Interval, MaxNum).

%% @private this helper enables us to use -1 as MaxNum. MaxNum == -1 signals that all
%%          data is to be retrieved.
-spec foldr_helper(DB::db(), Fun::fun((Key::key(), AccIn::A) -> AccOut::A), Acc0::A,
                               Intervall::db_backend_beh:interval(), MaxNum::integer()) -> Acc1::A.
foldr_helper({DB, _FileName}, Fun, Acc, Interval, MaxNum) ->
    %% first only retrieve keys so we don't have to load the whole db into memory
    Keys = get_all_keys(DB, Interval, -1),
    CutData = case MaxNum of
                  N when N < 0 ->
                      Keys;
                  _ ->
                      lists:sublist(Keys, MaxNum)
              end,
    %% see HINT in foldl/5
    %% now retrieve actual data
    lists:foldl(Fun, Acc, CutData).

%% @private get_all_keys/3 retrieves all keys in DB that fall into Interval but
%%          not more than MaxNum. If MaxNum == -1 all Keys are retrieved. If
%%          MaxNum is positive it starts from the left in term order.
-spec get_all_keys(pid(), db_backend_beh:interval(), -1 | non_neg_integer()) ->
    [key()].
get_all_keys(DB, Interval, MaxNum) ->
    Keys = toke_drv:fold(fun(Key, _Entry, AccIn) ->
                              [?OUT(Key) | AccIn]
                         end, [], DB),
    {_, In} = lists:foldl(fun(_, {0, _} = AccIn) ->
                                  AccIn;
                             (Key, {Max, KeyAcc} = AccIn) ->
                          case is_in(Interval, Key) of
                              true ->
                                  {Max - 1, [Key | KeyAcc]};
                              _ ->
                                  AccIn
                          end
                end, {MaxNum, []}, lists:sort(Keys)),
    In.


is_in({Key}, OtherKey) -> Key =:= OtherKey;
is_in(all, _Key) -> true;
is_in({'(', L, R, ')'}, Key) -> Key > L andalso Key < R;
is_in({'(', L, R, ']'}, Key) -> Key > L andalso ((Key < R) orelse (Key =:= R));
is_in({'[', L, R, ')'}, Key) -> ((Key > L) orelse (Key =:= L)) andalso Key < R;
is_in({'[', L, R, ']'}, Key) -> ((Key > L) orelse (Key =:= L)) andalso
                                          ((Key < R) orelse (Key =:= R)).
