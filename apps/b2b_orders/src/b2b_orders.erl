-module(b2b_orders).
%%% This module represents the backend system for a
%%% manufacturer, that receives and processes orders for a shop
%%% from clients.

%% API
-export([init_budget/3 ,
    place_order/3,
    init_availability/3,
    create_budget_obj/1,
    get_object_of/1,
    get_val/3]).

-define(ITEMS, [{shirt, riak_dt_pncounter, bucket}, {pants, riak_dt_pncounter, bucket}, {dress, riak_dt_pncounter, bucket}]).
-define(UNITCOST, [{shirt, 200}, {pants, 350}, {dress, 400}]).
-define(STOREIDS, [store1]).

init_budget(Node, Clock, Value) ->
    {ok, TxId} = rpc:call(Node, antidote, start_transaction, [Clock, []]),
    lists:foreach(fun(StoreId) ->
                      StoreBudgetObj = create_budget_obj(StoreId),
                      ok = rpc:call(Node, antidote, update_objects, [[{StoreBudgetObj, increment, Value}], TxId])
                  end, ?STOREIDS),
    {ok, CT} = rpc:call(Node, antidote, commit_transaction, [TxId]),
    {ok, CT}.

init_availability(Node, Clock, Value) ->
    {ok, TxId} = rpc:call(Node, antidote, start_transaction, [Clock, []]),
    lists:foreach(fun(Item) ->
                    ok = rpc:call(Node, antidote, update_objects, [[{Item, increment, Value}], TxId])
                  end, ?ITEMS),
    {ok, CT} = rpc:call(Node, antidote, commit_transaction, [TxId]),
    {ok, CT}.

place_order(Node, Clock, {StoreId, Orders}) ->
    StoreOrdersObj = create_orders_obj(StoreId),
    StoreBudgetObj = create_budget_obj(StoreId),
    {ok, TxId} = rpc:call(Node, antidote, start_transaction, [Clock, []]),
    {ok, [CurrBudget]} = rpc:call(Node, antidote, read_objects, [[StoreBudgetObj], TxId]),
    {ok, [_OrdersHistory]} = rpc:call(Node, antidote, read_objects, [[StoreOrdersObj], TxId]),

    {OrderTotalCost, InStock} =
    lists:foldl(fun(Order, {Total, _Available}) ->
                    {Item, OrderedCount, _} = Order,
                    {ItemId, _, _} = Item,
                    CPU = proplists:get_value(ItemId, ?UNITCOST),
                    {Total + (CPU * OrderedCount), true}
                 end, {0, true}, Orders),
    Res =
    if
        InStock andalso OrderTotalCost =< CurrBudget ->
            ok = rpc:call(Node, antidote, update_objects, [[{StoreBudgetObj, decrement, OrderTotalCost}], TxId]),
            ok;
        true -> %%rejected
            ok = rpc:call(Node, antidote, update_objects,
              [[{StoreBudgetObj, decrement, 1}, {StoreBudgetObj, increment, 1}], TxId])
    end,
    {ok, CT} = rpc:call(Node, antidote, commit_transaction, [TxId]),
    case Res of
        ok -> {ok, {TxId, CT}};
        rejected -> {rejected, {notxn, Clock}}
    end.

get_val(Node, Obj, Clock) ->
    {ok, Tx} = rpc:call(Node, antidote, start_transaction, [Clock, []]),
    {ok, [Res]} = rpc:call(Node, antidote, read_objects, [[Obj], Tx]),
    {ok, _CT1} = rpc:call(Node, antidote, commit_transaction, [Tx]),
    Res.
%%%=======================================
%%% Internal functions
%%%=======================================

create_orders_obj(StoreId) ->
    {list_to_atom(atom_to_list(StoreId) ++ "_orders"), antidote_crdt_gset, bucket}.

create_budget_obj(all) ->
    [create_budget_obj(StoreId) || StoreId <- ?STOREIDS];

create_budget_obj(StoreId) ->
    {list_to_atom(atom_to_list(StoreId) ++ "_budget"), antidote_crdt_counter, bucket}.

get_object_of(ItemType) ->
    lists:keyfind(ItemType, 1, ?ITEMS).
