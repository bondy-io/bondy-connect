Realm = <<"com.leapsight.fleet">>,
Victim = <<"@@VICTIM@@">>,
Tab = fun(registration) -> bondy_namespace_catalog:table(bondy_rib_registrations);
         (subscription) -> bondy_namespace_catalog:table(bondy_rib_subscriptions) end,
CountOf = fun(registration, #{count := C}) when is_integer(C) -> C;
             (subscription, C) when is_integer(C) -> C end,
OwnerOf = fun(<<131, _/binary>> = Raw) ->
                 {_, _, _, N} = binary_to_term(Raw, [safe]), N;
             (K) ->
                 [_, Raw] = binary:split(K, <<0>>),
                 {_, _, _, N} = binary_to_term(Raw, [safe]), N end,
Cells = fun(Type) ->
    {ok, Acc} = bondy_db:fold(
        Tab(Type), Realm, <<>>, infinity,
        fun({K, V, _H}, #{total := T, live := L, victim := VC, victim_live := VL} = A) ->
            IsLive = CountOf(Type, V) > 0,
            IsVictim = OwnerOf(K) =:= Victim,
            A#{total => T + 1,
               live => L + length([x || IsLive]),
               victim => VC + length([x || IsVictim]),
               victim_live => VL + length([x || IsVictim, IsLive])}
        end,
        #{total => 0, live => 0, victim => 0, victim_live => 0}),
    Acc end,
Stubs = fun(Type) ->
    Ns = bondy_registry_rib:realm_nodestrings(Type, Realm),
    #{nodes => length(Ns), victim => lists:member(Victim, Ns)} end,
{ok, Members} = partisan_peer_service:members(),
#{node => binary_to_list(bondy_config:nodestring()),
  members => length(Members),
  reg => Cells(registration),
  sub => Cells(subscription),
  reg_stubs => Stubs(registration),
  sub_stubs => Stubs(subscription)}.
