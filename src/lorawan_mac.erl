%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
% LoRaWAN 1.0.1 compliant MAC implementation
% Supports Class A devices
%
-module(lorawan_mac).

-export([process_frame/4, process_status/2]).
-export([binary_to_hex/1, hex_to_binary/1]).

-define(MAX_FCNT_GAP, 16384).

-include_lib("lorawan_server_api/include/lorawan_application.hrl").
-include("lorawan.hrl").

process_frame(MAC, RxQ, RF, PHYPayload) ->
    Size = byte_size(PHYPayload)-4,
    <<Msg:Size/binary, MIC:4/binary>> = PHYPayload,
    <<MType:3, _:5, _/binary>> = Msg,
    case mnesia:dirty_read(gateways, MAC) of
        [] ->
            lager:warning("Unknown MAC ~s", [binary_to_hex(MAC)]),
            {error, {unknown_mac, MAC}};
        [G] ->
            process_frame1(G#gateway.netid, MAC, RxQ, RF, MType, Msg, MIC)
    end.

process_status(MAC, S) ->
    case mnesia:dirty_read(gateways, MAC) of
        [] ->
            lager:warning("Unknown MAC ~s", [binary_to_hex(MAC)]),
            {error, {unknown_mac, MAC}};
        [G] ->
            G2 = if
                % store gateway GPS position
                is_number(S#stat.lati), is_number(S#stat.long), is_number(S#stat.alti),
                S#stat.lati /= 0, S#stat.long /= 0, S#stat.alti /= 0 ->
                    G#gateway{ gpspos={S#stat.lati, S#stat.long}, gpsalt=S#stat.alti };
                % position not received
                true -> G
            end,
            mnesia:dirty_write(gateways, G2),
            ok
    end.

process_frame1(NetID, _MAC, RxQ, RF, 2#000, Msg, MIC) ->
    <<_, MACPayload/binary>> = Msg,
    <<AppEUI0:8/binary, DevEUI0:8/binary, DevNonce:2/binary>> = MACPayload,
    {AppEUI, DevEUI} = {reverse(AppEUI0), reverse(DevEUI0)},

    case mnesia:dirty_read(devices, DevEUI) of
        [] ->
            lager:warning("Unknown DevEUI ~s", [binary_to_hex(DevEUI)]),
            {error, {unknown_deveui, DevEUI}};
        [D] when D#device.can_join == false ->
            lager:debug("Join ignored from DevEUI ~s", [binary_to_hex(DevEUI)]),
            ok;
        [D] ->
            case aes_cmac:aes_cmac(D#device.appkey, Msg, 4) of
                MIC ->
                    handle_join(NetID, RxQ, RF, AppEUI, DevEUI, DevNonce, D#device.appkey);
                _MIC2 ->
                    {error, bad_mic}
            end
    end;
process_frame1(_NetID, MAC, RxQ, RF, MType, Msg, MIC) ->
    <<_, MACPayload/binary>> = Msg,
    <<DevAddr0:4/binary, ADR:1, ADRACKReq:1, ACK:1, _RFU:1, FOptsLen:4,
        FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, FPort:8, FRMPayload/binary>> = MACPayload,
    DevAddr = reverse(DevAddr0),

    case check_link(DevAddr, FCnt) of
        {ok, L} ->
            case aes_cmac:aes_cmac(L#link.nwkskey, <<(b0(MType band 1, DevAddr, FCnt, byte_size(Msg)))/binary, Msg/binary>>, 4) of
                MIC ->
                    {ok, L2, FOptsOut} = lorawan_mac_commands:handle(store_adr(L, ADR), FOpts),
                    mnesia:dirty_write(links, L2#link{last_rx=calendar:universal_time()}),
                    Data = cipher(FRMPayload, L#link.appskey, MType band 1, DevAddr, FCnt),
                    store_rxpk(MAC, RxQ, RF, DevAddr, FCnt, L2#link.devstat, reverse(Data)),
                    handle_rxpk(RxQ, MType, DevAddr, L#link.app, L#link.appid, ADRACKReq, ACK, FOptsOut, FPort, reverse(Data));
                _MIC2 ->
                    {error, bad_mic}
            end;
        ignore ->
            ok;
        {error, Error} ->
            {error, Error}
    end.

handle_join(NetID, RxQ, RF, AppEUI, DevEUI, DevNonce, AppKey) ->
    AppNonce = crypto:strong_rand_bytes(3),
    NwkSKey = crypto:block_encrypt(aes_ecb, AppKey,
        padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
    AppSKey = crypto:block_encrypt(aes_ecb, AppKey,
        padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>)),

    {atomic, {DevAddr, App, AppID}} = mnesia:transaction(fun() ->
        [D] = mnesia:read(devices, DevEUI, write),
        NewAddr = if
            D#device.link == undefined;
            byte_size(D#device.link) < 4 ->
                create_devaddr(NetID);
            true ->
                D#device.link
        end,
        ok = mnesia:write(devices, D#device{link=NewAddr, last_join=calendar:universal_time()}, write),

        lager:info("JOIN REQUEST ~w ~w -> ~w",[AppEUI, DevEUI, NewAddr]),
        ok = mnesia:write(links, #link{devaddr=NewAddr, app=D#device.app, appid=D#device.appid, nwkskey=NwkSKey, appskey=AppSKey,
            fcntup=0, fcntdown=0, adr_flag_use=0, adr_flag_set=D#device.adr_flag_set,
            adr_use={1, 0, 7}, adr_set=D#device.adr_set}, write),
        {NewAddr, D#device.app, D#device.appid}
    end),
    mnesia:dirty_delete(pending, DevAddr),
    case lorawan_application_handler:handle_join(DevAddr, App, AppID) of
        ok ->
            {ok, {_RxFreq, RxRate, _RxCoding}} = application:get_env(rx2_rf),
            {ok, JoinDelay1} = application:get_env(join_delay1),
            % transmitting after join accept delay 1
            Time = RxQ#rxq.tmst + JoinDelay1,
            txaccept(Time, RF, RxRate, AppKey, AppNonce, NetID, DevAddr);
        {error, Error} -> {error, Error}
    end.

create_devaddr(NetID) ->
    <<_:17, NwkID:7>> = NetID,
    %% FIXME: verify uniqueness
    <<NwkID:7, 0:1, (crypto:strong_rand_bytes(3))/binary>>.

txaccept(Time, RF, Rx2Rate, AppKey, AppNonce, NetID, DevAddr) ->
    MHDR = <<2#001:3, 0:3, 0:2>>,
    MACPayload = <<AppNonce/binary, NetID/binary, (reverse(DevAddr))/binary, 0:1, 0:3, Rx2Rate:4, 1>>,
    MIC = aes_cmac:aes_cmac(AppKey, <<MHDR/binary, MACPayload/binary>>, 4),

    % yes, decrypt; see LoRaWAN specification, Section 6.2.5
    PHYPayload = crypto:block_decrypt(aes_ecb, AppKey, padded(16, <<MACPayload/binary, MIC/binary>>)),
    {send, Time, RF, <<MHDR/binary, PHYPayload/binary>>}.


check_link(DevAddr, FCnt) ->
    case is_ignored(DevAddr, mnesia:dirty_all_keys(ignored_links)) of
        true ->
            ignore;
        false ->
            check_link_fcnt(DevAddr, FCnt)
    end.

is_ignored(_DevAddr, []) ->
    false;
is_ignored(DevAddr, [Key|Rest]) ->
    [#ignored_link{devaddr=MatchAddr, mask=MatchMask}] = mnesia:dirty_read(ignored_links, Key),
    case match(DevAddr, MatchAddr, MatchMask) of
        true -> true;
        false -> is_ignored(DevAddr, Rest)
    end.

match(<<DevAddr:32>>, <<MatchAddr:32>>, <<MatchMask:32>>) ->
    (DevAddr band MatchMask) == MatchAddr.

check_link_fcnt(DevAddr, FCnt) ->
    case mnesia:dirty_read(links, DevAddr) of
        [] ->
            lager:warning("Unknown DevAddr ~s", [binary_to_hex(DevAddr)]),
            {error, {unknown_devaddr, DevAddr}};
        [L] ->
            case fcnt_gap(L#link.fcntup, FCnt) of
                N when N < ?MAX_FCNT_GAP ->
                    % L#link.fcntup is 32b, but the received FCnt may be 16b only
                    LastFCnt = (L#link.fcntup + N) band 16#FFFFFFFF,
                    {ok, L#link{fcntup = LastFCnt}};
                BigN ->
                    lager:warning("~w has a large FCnt gap: last ~b, current ~b", [DevAddr, L#link.fcntup, FCnt]),
                    {error, {fcnt_gap_too_large, BigN}}
            end
    end.

fcnt_gap(A, B) ->
    A16 = A band 16#FFFF,
    if
        A16 > B -> 16#10000 - A16 + B;
        true  -> B - A16
    end.

store_adr(Link, ADR) -> Link#link{adr_flag_use=ADR}.

store_rxpk(MAC, RxQ, RF, DevAddr, FCnt, DevStat, _Data) ->
    % store #rxframe{frid, mac, rssi, lsnr, freq, datr, codr, devaddr, fcnt}
    mnesia:dirty_write(rxframes, #rxframe{frid= <<(erlang:system_time()):64>>,
        mac=MAC, rssi=RxQ#rxq.rssi, lsnr=RxQ#rxq.lsnr,
        freq=RF#rflora.freq, datr=RF#rflora.datr, codr=RF#rflora.codr,
        devaddr=DevAddr, fcnt=FCnt, devstat=DevStat}),
    ok.

handle_rxpk(RxQ, MType, DevAddr, App, AppID, ADRACKReq, ACK, FOptsOut, Port, Data)
        when MType == 2#010; MType == 2#100 ->
    <<Confirm:1, _:2>> = <<MType:3>>,
    handle_uplink(RxQ, Confirm, DevAddr, App, AppID, ADRACKReq, ACK, FOptsOut, Port, Data).

handle_uplink(RxQ, Confirm, DevAddr, App, AppID, ADRACKReq, ACK, FOptsOut, Port, Data) ->
    {ok, {TxFreq, TxRate, TxCoding}} = application:get_env(rx2_rf),
    {ok, RxDelay2} = application:get_env(rx_delay2),
    % will transmit in the RX2 window
    Time = RxQ#rxq.tmst + RxDelay2,
    RF2 = #rflora{freq=TxFreq, datr=datar_to_bin(TxRate), codr=TxCoding},
    % check whether last transmission was lost
    {LastLost, LostFrame} = check_lost(ACK, DevAddr),
    % check whether the response is required
    ShallReply = if
        Confirm == 1 ->
            % confirmed uplink received
            true;
        ADRACKReq == 1 ->
            % ADR ACK was requested
            lager:debug("ADRACKReq confirmed"),
            true;
        byte_size(FOptsOut) > 0 ->
            % have MAC commands to send
            true;
        true ->
            % else
            false
    end,
    % invoke applications
    case lorawan_application_handler:handle_rx(DevAddr, App, AppID,
            #rxdata{port=Port, data=Data, last_lost=LastLost, shall_reply=ShallReply}) of
        retransmit ->
            {send, Time, RF2, LostFrame};
        {send, TxData} ->
            txpk(Time, RF2, DevAddr, Confirm, FOptsOut, TxData);
        ok when ShallReply ->
            % application has nothing to send, but we still need to repond
            txpk(Time, RF2, DevAddr, Confirm, FOptsOut, #txdata{});
        ok -> ok;
        {error, Error} -> {error, Error}
    end.

check_lost(0, DevAddr) ->
    case mnesia:dirty_read(pending, DevAddr) of
        [] -> {false, undefined};
        [Msg] -> {true, Msg#pending.phypayload}
    end;
check_lost(1, DevAddr) ->
    ok = mnesia:dirty_delete(pending, DevAddr),
    {false, undefined}.

inc_fcntdown(DevAddr) ->
    mnesia:transaction(fun() ->
        [D] = mnesia:read(links, DevAddr, write),
        FCnt =  (D#link.fcntdown + 1) band 16#FFFFFFFF,
        NewD = D#link{fcntdown=FCnt},
        mnesia:write(links, NewD, write),
        NewD
    end).

txpk(Time, RF, DevAddr, ACK, FOpts, #txdata{confirmed=false} = TxData) ->
    {send, Time, RF, encode_txpk(2#011, DevAddr, ACK, FOpts, TxData)};
txpk(Time, RF, DevAddr, ACK, FOpts, #txdata{confirmed=true} = TxData) ->
    PHYPayload = encode_txpk(2#101, DevAddr, ACK, FOpts, TxData),
    mnesia:dirty_write(pending, #pending{devaddr=DevAddr, phypayload=PHYPayload}),
    {send, Time, RF, PHYPayload}.

encode_txpk(MType, DevAddr, ACK, FOpts, #txdata{port=FPort, data=Data, pending=FPending}) ->
    {atomic, L} = inc_fcntdown(DevAddr),
    FHDR = <<(reverse(DevAddr)):4/binary, (get_adr_flag(L)):1, 0:1, ACK:1, (bool_to_bit(FPending)):1, (byte_size(FOpts)):4,
        (L#link.fcntdown):16/little-unsigned-integer, FOpts/binary>>,
    MACPayload = case FPort of
        undefined ->
            <<FHDR/binary>>;
        Num when Num > 0 ->
            FRMPayload = cipher(Data, L#link.appskey, 1, DevAddr, L#link.fcntdown),
            <<FHDR/binary, FPort:8, (reverse(FRMPayload))/binary>>
    end,
    Msg = <<MType:3, 0:3, 0:2, MACPayload/binary>>,
    MIC = aes_cmac:aes_cmac(L#link.nwkskey, <<(b0(1, DevAddr, L#link.fcntdown, byte_size(Msg)))/binary, Msg/binary>>, 4),
    <<Msg/binary, MIC/binary>>.

bool_to_bit(true) -> 1;
bool_to_bit(false) -> 0.

get_adr_flag(#link{adr_flag_set=undefined}) -> 0;
get_adr_flag(#link{adr_flag_set=ADR}) -> ADR.


cipher(Bin, Key, Dir, DevAddr, FCnt) ->
    cipher(Bin, Key, Dir, DevAddr, FCnt, 1, <<>>).

cipher(<<Block:16/binary, Rest/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    cipher(Rest, Key, Dir, DevAddr, FCnt, I+1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) -> Acc;
cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

ai(Dir, DevAddr, FCnt, I) ->
    <<16#01, 0,0,0,0, Dir, (reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

binxor(<<>>, <<>>, Acc) -> Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).

reverse(Bin) -> reverse(Bin, <<>>).
reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) ->
    reverse(Rest, <<H/binary, Acc/binary>>).

padded(Bytes, Msg) ->
    case bit_size(Msg) rem (8*Bytes) of
        0 -> Msg;
        N -> <<Msg/bitstring, 0:(8*Bytes-N)>>
    end.

datar_to_bin(0) -> <<"SF12BW125">>;
datar_to_bin(1) -> <<"SF11BW125">>;
datar_to_bin(2) -> <<"SF10BW125">>;
datar_to_bin(3) -> <<"SF9BW125">>;
datar_to_bin(4) -> <<"SF8BW125">>;
datar_to_bin(5) -> <<"SF7BW125">>;
datar_to_bin(6) -> <<"SF7BW250">>.

% stackoverflow.com/questions/3768197/erlang-ioformatting-a-binary-to-hex
% a little magic from http://stackoverflow.com/users/2760050/himangshuj
binary_to_hex(Id) ->
    << <<Y>> || <<X:4>> <= Id, Y <- integer_to_list(X,16)>>.

hex_to_binary(Id) ->
    <<<<Z>> || <<X:8,Y:8>> <= Id,Z <- [binary_to_integer(<<X,Y>>,16)]>>.

% end of file
