%%% File    : inotify_server.erl
%%% Author  : Defnull <define.null@gmail.com>
%%% Created : Среда, Апрель 11 2012 by Defnull
%%% Description : 

-module(inotify_server).
-behaviour(gen_server).
-compile({parse_transform, sheriff}).

%% API
-export([start_link/0,
         add_watch/3,
         remove_watch/1,
         get_state/0
        ]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("inotify.hrl").

-define(SERVER, ?MODULE). 
-define(PORT_TIMEOUT, 1000).
-define(INOTIFY_BIN, "inotify").

-export_type([inotify_event/0,
              inotify_handler/0
             ]).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Be carefull natural inotify either creates a new watch item, or modifies an existing watch!
-spec add_watch(string(), inotify_mask() | [inotify_mask()], inotify_handler() | {atom(), atom()} | pid()) -> ok | {error, any()}.
add_watch(Filename, Mask, Callback) when is_function(Callback) ->
    case sheriff:check(Mask, inotify_mask) of
        true ->
            gen_server:call(?MODULE, {add_watch, Filename, Mask, Callback});
        false ->
            {error, badmask}
    end;        
add_watch(Filename, Mask, Callback) when is_pid(Callback) ->
    Fun = fun(Event) -> Callback ! {self(), Event} end,
    add_watch(Filename, Mask, Fun);
add_watch(Filename, Mask, {M,F}) when is_atom(M) and is_atom(F) ->
    Fun = fun(Event) -> M:F(Event) end,                  
    add_watch(Filename, Mask, Fun).

-spec add_watch_impl(string(), [inotify_mask()], inotify_handler(), any()) -> {reply, any(), any()}. 
add_watch_impl(Filename, Mask, Callback, #state{port = Port,
                                                notify_instance = FD,
                                                watches = Watches} = State) ->
    try
        {ok, WD} = sync_call_command(Port, {add, FD, Filename, Mask}),
        Watches2 = dict:store(WD, #watch{filename = Filename, eventhandler = Callback}, Watches),
        {reply, {ok, WD}, State#state{watches = Watches2}}
    catch _:Error ->
            {reply, {error, Error}, State}
    end.

remove_watch(Filename) ->
    gen_server:call(?MODULE, {remove_watch, Filename}).

remove_watch_impl(Filename, #state{port = Port, notify_instance = FD, watches = Watches} = State) ->
    try
        case search_for_watch(Filename, Watches) of
            undefined ->
                {reply, {error, not_watched}, State};
            WD ->
                {ok, _} = sync_call_command(Port, {remove, FD, WD}),
                Watches2 = dict:erase(WD, Watches),
                {reply, ok, State#state{watches = Watches2}}
        end
    catch _:Error ->
            {reply, {error, Error}, State}
    end.

get_state() ->
    gen_server:call(?MODULE, state).

get_state(State) ->
    {reply, State, State}.

get_data({event, WD, Mask, Cookie, Name}, #state{watches = Watches} = State) ->
    Filename = search_for_filename(WD, Watches),
    get_data(WD, #inotify_event{filename = Filename,
                                mask = Mask,
                                cookie = Cookie,
                                name = Name},
             State).
get_data(WD, Event, #state{watches = Watches} = State) ->
    case dict:is_key(WD, Watches) of
        true ->
            #watch{filename = Filename, eventhandler = EventHandler} = dict:fetch(WD, Watches),
            try apply(EventHandler, [Event])
            catch ErrorType:Error ->
                    log({callback_failed, Filename, ErrorType, Error})                        
            end;
        false ->
            log({unhandle_event, Event})
    end,
    {noreply, State}.

search_for_watch(Filename, Watches) ->
    case [ WD || {WD, #watch{filename=Fname}} <- dict:to_list(Watches), Filename =:= Fname ] of
        [] ->
            undefined;
        [WD] ->
            WD
    end.

search_for_filename(WD, Watches) ->
    try
        Watch = dict:fetch(WD, Watches),
        Watch#watch.filename
    catch
        error:badarg ->
            undefined            
    end.

inotify_bin() ->       
     filename:join([code:priv_dir(inotify), ?INOTIFY_BIN]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    Port = erlang:open_port({spawn, inotify_bin()}, [{packet, 2}, binary, exit_status]),
    {ok, FD} = sync_call_command(Port, {open}),
    {ok, #state{port = Port,
                notify_instance = FD,
                watches = dict:new()
               }}.

handle_call({add_watch, Filename, Mask, Callback}, _From, State) ->
    add_watch_impl(Filename, Mask, Callback, State);

handle_call({remove_watch, Filename}, _From, State) ->
    remove_watch_impl(Filename, State);

handle_call(state, _From, State) ->
    get_state(State);

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, Msg}}, #state{port = Port} = State) ->
    get_data(binary_to_term(Msg), State);

handle_info({Port, {exit_status, Status}}, #state{port = Port}) ->
    exit({exit_status, Status});

handle_info(_Info, State) ->
    io:format("Info: ~p~n", [_Info]),
    {noreply, State}.

terminate(_Reason, #state{port = Port, notify_instance = FD } = _State) ->
    sync_call_command(Port, {close, FD}),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

log(Msg) ->
    error_logger:error_msg("~p~n", [Msg]).

sync_call_command(Port, Msg) ->
    try
        erlang:port_command(Port, term_to_binary(Msg)),
        receive 
            {Port, {data, Data}} -> 
                binary_to_term(Data)
        after ?PORT_TIMEOUT -> 
                throw(port_timeout)
        end
  catch 
    _:Error -> 
      throw({port_failed, {Error, Port, Msg}})
  end.
