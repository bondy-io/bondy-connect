Victim = '@@VICTIM@@',
{ok, Specs} = partisan_peer_service:members_for_orchestration(),
case [S || #{name := N} = S <- Specs, N =:= Victim] of
    [Spec | _] -> {leave, Victim, partisan_peer_service:leave(Spec)};
    [] -> {not_a_member, Victim, [N || #{name := N} <- Specs]}
end.
