%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
-module(lorawan_admin).

-export([handle_authorization/2, get_filters/1, paginate/3]).
-export([parse_admin/1, build_admin/1]).

-include_lib("lorawan_server_api/include/lorawan_application.hrl").
-include("lorawan.hrl").

handle_authorization(Req, State) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, User, Pass} ->
            case user_password(User) of
                Pass -> {true, Req, State};
                _ -> {{false, <<"Basic realm=\"lorawan-server\"">>}, Req, State}
            end;
        _ ->
            {{false, <<"Basic realm=\"lorawan-server\"">>}, Req, State}
    end.

user_password(User) ->
    case mnesia:dirty_read(users, User) of
        [] -> undefined;
        [U] -> U#user.pass
    end.

get_filters(Req) ->
    case cowboy_req:match_qs([{'_filters', [], <<"{}">>}], Req) of
        #{'_filters' := Filter} ->
            jsx:decode(Filter, [{labels, atom}])
    end.

paginate(Req, State, List) ->
    case cowboy_req:match_qs([{'_page', [], <<"1">>}, {'_perPage', [], undefined}], Req) of
        #{'_perPage' := undefined} ->
            {jsx:encode(List), Req, State};
        #{'_page' := Page0, '_perPage' := PerPage0} ->
            {Page, PerPage} = {binary_to_integer(Page0), binary_to_integer(PerPage0)},
            Req2 = cowboy_req:set_resp_header(<<"X-Total-Count">>, integer_to_binary(length(List)), Req),
            {jsx:encode(lists:sublist(List, 1+(Page-1)*PerPage, PerPage)), Req2, State}
    end.

parse_admin(List) ->
    lists:map(
        fun ({Key, null}) -> {Key, undefined};
            ({Key, Value}) when Key == netid -> {Key, lorawan_mac:hex_to_binary(Value)};
            ({Key, Value}) when Key == mac; Key == netid; Key == mask;
                                Key == deveui; Key == appeui; Key == appkey; Key == link;
                                Key == devaddr; Key == nwkskey; Key == appskey -> {Key, lorawan_mac:hex_to_binary(Value)};
            ({Key, Value}) when Key == gpspos -> {Key, parse_latlon(Value)};
            ({Key, Value}) when Key == adr_use; Key == adr_set -> {Key, parse_adr(Value)};
            ({Key, Value}) when Key == txdata -> {Key, ?to_record(txdata, parse_admin(Value))};
            ({Key, Value}) when Key == last_join; Key == last_rx; Key == devstat_time;
                                Key == datetime -> {Key, iso8601:parse(Value)};
            ({Key, Value}) when Key == devstat -> {Key, parse_devstat(Value)};
            (Else) -> Else
        end,
        List).

build_admin(List) ->
    lists:foldl(
        fun ({Key, undefined}, A) -> [{Key, null} | A];
            ({Key, Value}, A) when Key == netid -> [{Key, lorawan_mac:binary_to_hex(Value)} | A];
            ({Key, Value}, A) when Key == mac; Key == netid; Key == mask;
                                Key == deveui; Key == appeui; Key == appkey; Key == link;
                                Key == devaddr; Key == nwkskey; Key == appskey;
                                Key == data;
                                Key == frid -> [{Key, lorawan_mac:binary_to_hex(Value)} | A];
            ({Key, Value}, A) when Key == gpspos -> [{Key, build_latlon(Value)} | A];
            ({Key, Value}, A) when Key == adr_use; Key == adr_set -> [{Key, build_adr(Value)} | A];
            ({Key, Value}, A) when Key == txdata -> [{Key, build_admin(?to_proplist(txdata, Value))} | A];
            ({Key, Value}, A) when Key == last_join; Key == last_rx; Key == devstat_time;
                                Key == datetime -> [{Key, iso8601:format(Value)} | A];
            ({Key, Value}, A) when Key == devstat -> [{Key, build_devstat(Value)} | A];
            (Else, A) -> [Else | A]
        end,
        [], List).

parse_latlon(List) ->
    {proplists:get_value(lat, List), proplists:get_value(lon, List)}.

build_latlon({Lat, Lon}) ->
    [{lat, Lat}, {lon, Lon}].

parse_adr(List) ->
    {proplists:get_value(power, List), proplists:get_value(datr, List),
        case proplists:get_value(chans, List, null) of
            null -> undefined;
            Val -> binary_to_integer(Val, 2)
        end}.

build_adr({TXPower, DataRate, Chans}) ->
    [{power, TXPower}, {datr, DataRate}, {chans,
        case Chans of
            undefined -> null;
            Val when is_integer(Val) -> integer_to_binary(Val, 2)
        end}].

parse_devstat(List) ->
    {proplists:get_value(battery, List), proplists:get_value(margin, List)}.

build_devstat({Battery, Margin}) ->
    [{battery, Battery}, {margin, Margin}].

% end of file
