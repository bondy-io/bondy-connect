#!/usr/bin/env bash
# =============================================================================
# SPDX-FileCopyrightText: 2016 - 2026 Leapsight
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#
# Release gate on the Fly fleet: deploy the working tree, run the perf
# profile, then crash one node and wait for the survivors to reclaim its
# registry state.
#
#   ./harness/fleet-scale/release-gate.sh <RUN>
#
# Writes out/<RUN>_* and stops every machine in both apps on any exit.
#
# Perf: 50k publishers at one PUBLISH per 5 s, 200 subscribers with 2000
# subscriptions each, 120 s ramp, 360 s hold. Stage snapshots are taken at
# ramp end and steady end and differenced by stage-means.py.
#
# Departure: under a seed load that outlasts every poll, the greatest
# machine id is stopped with SIGKILL, so its own session teardown never
# runs (`fly machine stop` without a signal is graceful), and a survivor
# removes it from the cluster. Each survivor is polled with
# probes/rib_poll.erl until the victim owns no cell and no stub names it.
# The check is fail-closed: a probe that errors counts as not gone. After
# 15 polls without that, retirement and reclaim are driven synchronously
# with probes/drive.erl and the result recorded.
# =============================================================================
set -uo pipefail

if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: bash >= 4 required (found ${BASH_VERSION:-?})." >&2
    exit 1
fi
[ $# -eq 1 ] || { echo "usage: $0 <RUN>" >&2; exit 1; }

RUN=$1
FS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$FS/../.." && pwd)"
OUT=$FS/out
PROBES=$FS/probes
APP=bondy-fleet-1
LG_APP=bondy-fleet-lg
export FLY_ORG="${FLY_ORG:-leapsight}"
cd "$ROOT"

ts() { date -u +%H:%M:%SZ; }
say() { echo "[$(ts)] ### $*"; }
machines() { fly machines list -a $APP --json | jq -r '.[]|select(.state=="started")|.id' | sort; }
ip_of() { fly machines list -a $APP --json | jq -r --arg m "$1" '.[]|select(.id==$m)|.private_ip'; }
state_of() { fly machines list -a $APP --json | jq -r --arg m "$1" '.[]|select(.id==$m)|.state'; }
# `fly ssh console` reads stdin, so every call takes it from /dev/null: inside
# a `while read` loop it would otherwise consume the loop's input.
evalf() {
    local M=$1 F=$2 V=${3:-}
    local IP; IP=$(ip_of "$M")
    local B64; B64=$(sed -e "s/@@VICTIM@@/$V/" "$F" | base64 | tr -d '\n')
    fly ssh console -a $APP --machine "$M" \
        -C "sh -c 'echo $B64 | base64 -d > /tmp/probe.erl; env BONDY_ERL_NODENAME=bondy@$IP /bondy/bin/bondy-connect eval \"\$(cat /tmp/probe.erl)\"'" \
        2>&1 < /dev/null | tr -d '\r' | grep -vE '^\s*$|^Connecting to'
}
oneline() { tr -d '\r\n ' ; echo; }
health() {
    say "health ($1)"
    for M in $(machines); do
        local IP; IP=$(ip_of "$M")
        echo "  $M $(fly ssh console -a $APP --machine "$M" \
            --command "env BONDY_ERL_NODENAME=bondy@$IP /bondy/bin/bondy-connect eval {bondy_router_app:is_ready(),bondy_alarm_api:local_alarms()}." \
            2>&1 < /dev/null | tail -1)"
    done
}
# A pass needs both cell maps at zero for the victim and both stub sets
# without it; anything else, including a probe error, is not a pass.
victim_gone() {
    local R=$1
    echo "$R" | grep -qiE 'error|exit|exception' && return 1
    [ "$(echo "$R" | grep -o 'victim_live=>0' | wc -l | tr -d ' ')" -eq 2 ] || return 1
    [ "$(echo "$R" | grep -o 'victim=>false' | wc -l | tr -d ' ')" -eq 2 ] || return 1
    [ "$(echo "$R" | grep -o 'victim=>0,' | wc -l | tr -d ' ')" -eq 2 ] || return 1
    return 0
}
poll_all() { local L=$1 V=$2; shift 2; say "rib poll ($L)"; for M in "$@"; do echo "  $M $(evalf "$M" "$PROBES/rib_poll.erl" "$V" | oneline)"; done; }
counters_all() { local L=$1; shift; say "counters ($L)"; for M in "$@"; do echo "  $M $(evalf "$M" "$PROBES/counters.erl" | oneline)"; done; }
stop_all() {
    say "stopping all machines"
    for A in $APP $LG_APP; do
        for M in $(fly machines list -a $A --json | jq -r '.[]|select(.state!="stopped")|.id'); do
            fly machine stop "$M" -a $A >/dev/null 2>&1 && echo "  stopped $A $M"
        done
    done
}
trap stop_all EXIT
# run_lg <log> <env...>: starts run-fleet-lg.sh with the given load and
# returns once every LG is running; the LG script's pid is left in $LG.
run_lg() {
    local LOG=$1; shift
    ( env SKIP_DEPLOY=1 NODES=9 SUB_LGS=1 SUB_VUS_TOTAL=200 SUBS_PER_USER=2000 \
        VEHICLE_POOL=50000 PUB_INTERVAL_MS=5000 "$@" "$FS/run-fleet-lg.sh" ) >| "$LOG" 2>&1 &
    LG=$!
    until grep -q "waiting for all LGs to finish" "$LOG" 2>/dev/null; do
        kill -0 $LG 2>/dev/null || { say "LG script exited early"; cat "$LOG"; exit 3; }
        sleep 5
    done
}

say "git $(git rev-parse --short HEAD) dirty=$(git status --porcelain | wc -l | tr -d ' ')"
say "deploy $APP (remote build)"
NODES=5 "$FS/run-fleet.sh" || { say "DEPLOY FAILED"; exit 1; }
say "image $(fly status -a $APP 2>/dev/null | grep -oE 'deployment-[A-Z0-9]+' | head -1)"

ALL=($(machines))
say "selftest on ${ALL[0]}"
MISSING=$(evalf "${ALL[0]}" "$PROBES/selftest.erl" | oneline)
[ "$MISSING" = "[]" ] || { say "PROBES CANNOT RUN: missing $MISSING"; exit 2; }

say "tripwires + identity (pre)"
"$FS/check-tripwires.sh"; TW=$?
say "tripwires pre exit=$TW"
[ "$TW" -eq 0 ] || { say "FLEET NOT FIT: stopping before load"; exit 2; }
health pre
"$FS/snapshot-stages.sh" pre >| "$OUT/${RUN}_stages_pre.tsv"

say "starting load (perf)"
run_lg "$OUT/${RUN}_lg.log" PUB_VUS_TOTAL=50000 RAMP=120s HOLD=360s \
    SESSION_MS=600000 MEASURE_AFTER_MS=180000
say "load running; $(grep -E '^ +SUB0' "$OUT/${RUN}_lg.log")"
sleep 180
"$FS/snapshot-stages.sh" ramp_end >| "$OUT/${RUN}_stages_ramp_end.tsv"
say "ramp_end snapshot taken"
sleep 270
"$FS/snapshot-stages.sh" steady_end >| "$OUT/${RUN}_stages_steady_end.tsv"
say "steady_end snapshot taken"
wait $LG
say "load finished"
mkdir -p "$OUT/${RUN}_perf"; cp -f "$OUT"/*.txt "$OUT/${RUN}_perf/"

say "tripwires (post)"
"$FS/check-tripwires.sh"; say "tripwires post exit=$?"
health post
say "stage means (ramp_end -> steady_end)"
python3 "$FS/stage-means.py" "$OUT/${RUN}_stages_ramp_end.tsv" "$OUT/${RUN}_stages_steady_end.tsv"

say "DEPARTURE STEP (crash: SIGKILL)"
VICTIM=${ALL[-1]}; SURV=("${ALL[@]:0:${#ALL[@]}-1}")
VNODE="bondy@$(ip_of "$VICTIM")"
say "victim $VICTIM ($VNODE); survivors ${SURV[*]}"

say "starting load (departure seed)"
run_lg "$OUT/${RUN}_departure_lg.log" PUB_VUS_TOTAL=8000 RAMP=60s HOLD=2400s \
    SESSION_MS=3600000 MEASURE_AFTER_MS=60000
say "seed load running; $(grep -E '^ +SUB0' "$OUT/${RUN}_departure_lg.log")"
sleep 240
poll_all pre_departure "$VNODE" "${ALL[@]}"
counters_all pre_departure "${ALL[@]}"

say "killing victim $VICTIM (stop -s SIGKILL)"
fly machine stop -s SIGKILL "$VICTIM" -a $APP; say "kill exit=$?"
sleep 20
say "victim state: $(state_of "$VICTIM")"
say "leave on ${SURV[0]}"
echo "  $(evalf "${SURV[0]}" "$PROBES/leave.erl" "$VNODE" | oneline)"
T0=$(date +%s); GONE=0
for ((i = 1; i <= 15; i++)); do
    sleep 60
    say "poll $i (+$(( $(date +%s) - T0 ))s)"
    REMAIN=0
    for M in "${SURV[@]}"; do
        R=$(evalf "$M" "$PROBES/rib_poll.erl" "$VNODE" | oneline)
        echo "  $M $R"
        victim_gone "$R" || REMAIN=$((REMAIN + 1))
    done
    [ "$REMAIN" -eq 0 ] && { GONE=1; say "victim state gone on every survivor after +$(( $(date +%s) - T0 ))s (background passes)"; break; }
done
counters_all post_polls "${SURV[@]}"
if [ "$GONE" -eq 0 ]; then
    say "victim state still present after +$(( $(date +%s) - T0 ))s; driving retirement + reclaim synchronously"
    for M in "${SURV[@]}"; do echo "  $M $(evalf "$M" "$PROBES/drive.erl" | oneline)"; done
    sleep 10
    poll_all post_drive "$VNODE" "${SURV[@]}"
fi
say "victim state (end of polls): $(state_of "$VICTIM")"
say "waiting for seed load to end"
wait $LG; say "seed load finished"
mkdir -p "$OUT/${RUN}_departure"; cp -f "$OUT"/*.txt "$OUT/${RUN}_departure/"
poll_all post_load "$VNODE" "${SURV[@]}"
counters_all post_load "${SURV[@]}"
say "tripwires (post-departure, survivors)"
"$FS/check-tripwires.sh"; say "tripwires post-departure exit=$?"
health post_departure
say "DONE gone=$GONE"
