-module( bot ).

-behaviour( gen_server ).
-export( [ init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3 ] ).

-export( [ 
	start_link/3,
	join/2,
	part/2,
	part/3
] ).

-record( state, {
	pid,
	nick,
	owner,
	server_pid
} ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Module API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%==============================================================================
%% start_link/3
%%==============================================================================
start_link( Host, Owner, Nick ) ->
	gen_server:start_link( ?MODULE, [ Host, Owner, Nick ], [] ).

%%==============================================================================
%% join/2
%%==============================================================================
join( Bot, Channel ) ->
	gen_server:cast( Bot, { join, Channel } ).

%%==============================================================================
%% part/2
%%==============================================================================
part( Bot, Channel ) ->
	gen_server:cast( Bot, { part, Channel, "" } ).

%%==============================================================================
%% part/3
%%==============================================================================
part( Bot, Channel, Message ) ->
	gen_server:cast( Bot, { part, Channel, Message } ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%==============================================================================
%% init/1
%%==============================================================================
init( [ Host, Owner, Nick ] ) ->
	Server = server:start_link( self(), Host, Nick ),
	State = #state{
		owner = Owner,
		nick = Nick,
		pid = self(),
		server_pid = Server
	},
	{ ok, State }.

%%==============================================================================
%% handle_call/3
%%==============================================================================
handle_call( _Request, _From, State ) ->
	{ reply, ok, State }.

%%==============================================================================
%% handle_cast/2
%%==============================================================================
%% Join a channel
%%------------------------------------------------------------------------------
handle_cast( { join, Channel }, State ) ->
	case irc:join( Channel ) of
		{ error, Reason } -> io:format( "Join Error: ~p~n", [ Reason ] );
		Irc               -> State#state.server_pid ! { send, Irc }
	end,
	{ noreply, State };
%%------------------------------------------------------------------------------
%% Part a channel
%%------------------------------------------------------------------------------
handle_cast( { part, Channel, Message }, State ) ->
	case irc:part( Channel, Message ) of
		{ error, Reason } -> io:format( "Part Error: ~p~n", [ Reason ] );
		Irc               -> State#state.server_pid ! { send, Irc }
	end,
	{ noreply, State };
%%------------------------------------------------------------------------------
%% Send a PRIVMSG to a recipient
%%------------------------------------------------------------------------------
handle_cast( { privmsg, Recipient, Message }, State ) ->
	State#state.server_pid ! { send, irc:privmsg( Recipient, Message ) },
	{ noreply, State };
%%------------------------------------------------------------------------------
%% Received PRIVMSG from Owner to Bot
%%------------------------------------------------------------------------------
handle_cast( { irc, Packet = { { [ Nick | _ ], "PRIVMSG", To, _ }, [ $- | _ ] }, _ }, State ) 
when Nick == State#state.owner, To == State#state.nick ->
	echo( Packet ),
	spawn( fun() -> handle_command( State, Packet ) end ),
	{ noreply, State };
%%------------------------------------------------------------------------------
%% Catch all IRC packets
%%------------------------------------------------------------------------------
handle_cast( { irc, Packet, _Line }, State ) ->
	echo( Packet ),
	{ noreply, State };
%%------------------------------------------------------------------------------
%% Got a line from the server
%%------------------------------------------------------------------------------
handle_cast( { incoming_line, Line }, State ) ->
	process_flag( trap_exit, true ),
	spawn_link( fun() -> gen_server:cast( State#state.pid, { irc, irc:parse( Line ), Line } ) end ),
	{ noreply, State };
%%------------------------------------------------------------------------------
%% A linked process exited normally
%%------------------------------------------------------------------------------
handle_cast( { 'EXIT', _, normal }, State ) ->
	{ noreply, State };
%%------------------------------------------------------------------------------
%% A linked process exited for some reason
%%------------------------------------------------------------------------------
handle_cast( { 'EXIT', Pid, Reason }, State ) ->
	echo( { "~p crashed because ~p~n", [ Pid, Reason ] } ),
	{ noreply, State };
%%------------------------------------------------------------------------------
%% Server Disconnected
%%------------------------------------------------------------------------------
handle_cast( { _, disconnected }, State ) ->
	echo( "Server Disconnected~n" ),
	{ stop, server_disconnected, State };

%%------------------------------------------------------------------------------
%% Catch all casts
%%------------------------------------------------------------------------------
handle_cast( Message, State ) ->
	echo( { [ "Unknown Cast: ~p~n" ], [ Message ] } ),
	{ noreply, State }.

%%==============================================================================
%% handle_info/2
%%==============================================================================
handle_info( _Info, State ) ->
	{ noreply, State }.

%%==============================================================================
%% terminate/2
%%==============================================================================
terminate( _Reason, _State ) -> 
	ok.

%%==============================================================================
%% code_changed/3
%%==============================================================================
code_change( _OldVsn, State, _Extra ) -> 
	{ ok, State }.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Private Functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%==============================================================================
%% handle_command/2
%%==============================================================================
handle_command( State, { { [ Nick | _ ], _, _, _ }, "-" ++ Body } ) ->
	case string:tokens( Body, " " ) of
	
		%% Echo
		[ "echo" | Tail ] ->
			State#state.server_pid ! { send, irc:privmsg( Nick, string:join( Tail, " " ) ) };
		
		%% Join a channel
		[ "join", Channel ] -> bot:join( State#state.pid, Channel );
			
		%% Part a channel
		[ "part", Channel ] -> bot:part( State#state.pid, Channel );
		
		%% Inject Raw IRC
		[ "raw" | Tail ] ->
			Irc = lists:concat( [ string:join( Tail, " " ), "\r\n" ] ),
			State#state.server_pid ! { send, Irc };
		
		%% Anything else
		Unknown ->
			io:format( ">>> Unknown Command: ~s~n", [ Unknown ] )
	end.

%%==============================================================================
%% echo/1
%%==============================================================================
%% IRC Packet
%%------------------------------------------------------------------------------
echo( { { [ Nick | _ ], Type, To, Args }, Body } ) ->
	Message = case Type of
		"001"     -> { "Welcome: ~s~n",                    [ Body ]                      };
		"002"     -> { "Host: ~s~n",                       [ Body ]                      };
		"003"     -> { "History: ~s~n",                    [ Body ]                      };
		"004"     -> { "???: ~s~n",                        [ string:join( Args, ", " ) ] };
		"005"     -> { "Options: Boring!~n",               []                            };
		"042"     -> { "Unique ID: ~s~n",                  [ Args ]                      };
		"252"     -> { "Operators Online: ~s~n",           [ Args ]                      };
		"251"     -> { "Info: ~s~n",                       [ Body ]                      };
		"254"     -> { "Active Channels: ~s~n",            [ Args ]                      };
		"255"     -> { "Info: ~s~n",                       [ Body ]                      };
		"265"     -> { "Local Load: ~s~n",                 [ Body ]                      };
		"266"     -> { "Global Load: ~s~n",                [ Body ]                      };
		"372"     -> { "MOTD: ~s~n",                       [ Body ]                      };
		"375"     -> { "MOTD: ---Message of the Day---~n", []                            };
		"376"     -> { "MOTD: ---Message of the Day---~n", []                            };
		"396"     -> { "Host Mask: ~s~n",                  [ Args ]                      };
		"433"     -> { "Error: Nickname in use~n",         []                            };
		"451"     -> { "Notice: ~s~n",                     [ Body ]                      };
		"NOTICE"  -> { "Notice: ~s~n",                     [ Body ]                      };
		"MODE"    -> { "Mode: ~s~n",                       [ string:join( Args, ", " ) ] };
		"PRIVMSG" -> { "Privmsg: (~s -> ~s) ~s~n",         [ Nick, To, Body ]            };
		_        -> none
	end,
	case Message of
		{ Format, Params } -> echo( { lists:concat( [ "IRC: ", Format ] ), Params } );
		_                  -> no_message
	end;
%%------------------------------------------------------------------------------
%% Nothing
%%------------------------------------------------------------------------------
echo( nothing ) ->
	ok;
%%------------------------------------------------------------------------------
%% Format and Arguments
%%------------------------------------------------------------------------------
echo( { Format, Args } ) ->
	io:format( lists:concat( [ "Bot> ", Format ] ), Args );
%%------------------------------------------------------------------------------
%% Just Format
%%------------------------------------------------------------------------------
echo( Format ) ->
	io:format( lists:concat( [ "Bot> ", Format ] ) ).