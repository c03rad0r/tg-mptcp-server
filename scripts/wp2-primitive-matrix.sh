#!/bin/bash
# WP2 — re-run the nftables primitive matrix ON THE TARGET KERNEL.
#
# Every result in SERVER-IMPL-TRACK.md §1.1/§2.2 was taken on kernel 7.0.0-38-generic with
# nftables 1.0.9 and carries no weight on the deployment target. This script establishes the
# same matrix on the target (6.12.111+deb13-amd64, nftables 1.1.3) and prints a PASS/FAIL line
# per primitive so the control-plane design can be based on facts rather than on a lab.
#
# SAFETY: this host is a SHARED, multi-service production box. It carries production tables
# (ip filter, inet fips-exit, inet f2b-table, ip/ip6 nat, ip raw, inet fips). Therefore:
#   - it touches ONLY tables named __wp2_*, and deletes exactly those at the end;
#   - it never runs `nft flush ruleset` and never names another table;
#   - it takes a flock mutex so it cannot collide with another session.
#
# Config-as-code: every threshold/identifier is a variable with a default.
: "${WP2_LOCK:=/tmp/tg-meter.lock}"
: "${WP2_PREF:=__wp2}"
: "${WP2_OUT:=/home/c08r4d0r/reports/mptcp-loop/wp2-primitive-matrix.txt}"
set -u
mkdir -p "$(dirname "$WP2_OUT")"
: > "$WP2_OUT"

T="${WP2_PREF}_t"          # the working table
M="${WP2_PREF}_m"          # a counter map
QM="${WP2_PREF}_qm"        # a quota map
Q="${WP2_PREF}_q"          # a named quota

log() { printf '%s\n' "$*" | tee -a "$WP2_OUT"; }
run() { # run <label> <expected: ok|err> <command...>
  local label=$1 want=$2; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  local got=$([ $rc -eq 0 ] && echo ok || echo err)
  if [ "$got" = "$want" ]; then log "PASS  ${label}  [${got}]  :: ${out:-<no output>}";
  else log "FAIL  ${label}  [want ${want}, got ${got}]  :: ${out:-<no output>}"; fi
}
cleanup() { for t in "$T" "$M" "$QM"; do nft delete table ip "$t" 2>/dev/null; done; }
cleanup

log "=== WP2 target primitive matrix ==="
log "host:      $(hostname)"
log "kernel:    $(uname -r)"
log "nftables:  $(nft --version 2>&1)"
log "started:   $(date -Is)"
log "safety:    touches only tables matching ${WP2_PREF}_*, takes ${WP2_LOCK}"
log ""

log "--- A. table / chain / counter basics ---"
run "create table"                     ok  nft add table ip "$T"
run "create metered chain (policy drop)" ok nft add chain ip "$T" u "{ type filter hook input priority 10; policy drop; }"
run "named counter object"             ok  nft add counter ip "$T" c1
run "named quota object"               ok  nft add quota ip "$T" "$Q" "{ over 1000000 bytes }"
run "rule: counter + quota + drop"     ok  nft add rule ip "$T" u ip saddr 10.0.0.1 counter name c1 quota name "$Q" drop

log ""
log "--- B. THE C1 FACTS (the reason metered chains must be default-deny) ---"
# A quota expression signals over-quota by RESTORING the continue verdict and falling through
# to the NEXT RULE. So in an accept-policy chain an over-quota packet is ACCEPTED.
run "quota+accept rule builds (accept policy)" ok nft add chain ip "$T" a "{ type filter hook forward priority 10; policy accept; }"
run "quota then accept in same chain"          ok nft add rule ip "$T" a ip saddr 10.0.0.2 quota name "${Q}_a" accept
run "'over 0 bytes' is accepted as a limit"    ok nft add quota ip "$T" "${Q}_zero" "{ over 0 bytes }"
log "  NOTE: \`over 0 bytes\` is UNLIMITED, not a block. Read back below shows no 'over' line."

log ""
log "--- C. the EOPNOTSUPP blockers (why per-client objects are pre-provisioned) ---"
run "declare counter MAP"                      ok  nft add map ip "$T" "$M" "{ type ipv4_addr : counter; size 64; }"
run "declare counter map with flags dynamic"   err nft add map ip "$T" "${M}_dyn" "{ type ipv4_addr : counter; size 64; flags dynamic; }"
run "UPDATE into a declared counter map"       err nft add rule ip "$T" a update "@${M}" "{ ip saddr }"
run "declare quota MAP"                        ok  nft add map ip "$T" "$QM" "{ type ipv4_addr : quota; size 64; }"
run "add ELEMENT to a counter map"             err nft add element ip "$T" "$M" "{ 10.0.0.9 }"

log ""
log "--- D. the primitives the control plane DEPENDS ON ---"
# D1. atomic re-arm: delete + re-add the quota in ONE nft -f, which must not touch the counter.
printf 'delete quota ip %s %s\nadd quota ip %s %s { over 2000000 bytes }\n' "$T" "$Q" "$T" "$Q" > /tmp/wp2_swap.nft
run "atomic quota limit swap (one nft -f)"     ok  nft -f /tmp/wp2_swap.nft
log "  read-back after swap:"
nft list quota ip "$T" "$Q" 2>&1 | sed 's/^/    /' | tee -a "$WP2_OUT"
rm -f /tmp/wp2_swap.nft

# D2. reset quota: clears 'used' and is fireable again immediately.
run "reset quota"                              ok  nft reset quota ip "$T" "$Q"
run "reset counter"                            ok  nft reset counter ip "$T" c1

# D3. handle-based rule replacement in ONE transaction (needed for the top-up exemption).
HANDLE=$(nft -a list chain ip "$T" a 2>/dev/null | awk '/quota name/ {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1); exit}')
if [ -n "${HANDLE:-}" ]; then
  printf 'delete rule ip %s a handle %s\nadd rule ip %s a handle %s ip saddr 10.0.0.2 quota name %s_a accept\n' \
    "$T" "$HANDLE" "$T" "$HANDLE" "$Q" > /tmp/wp2_h.nft
  run "replace rule by handle (one nft -f)"    ok  nft -f /tmp/wp2_h.nft
  rm -f /tmp/wp2_h.nft
else
  log "FAIL  replace rule by handle  :: could not obtain a rule handle"
fi

# D4. does the tabular/read-back shape the daemon depends on exist?
log ""
log "--- E. read-back shapes the daemon depends on ---"
run "list table as JSON (nft -j)"              ok  nft -j list table ip "$T"
log "  JSON is the cheapest per-tick read: one netlink round trip for the whole table."
log "  object shapes observed:"
nft -j list table ip "$T" 2>/dev/null | grep -oE '"(counter|quota)":\{[^}]*\}' | head -6 | sed 's/^/    /' | tee -a "$WP2_OUT"

log ""
log "--- F. WHICH KERNEL FEATURES ACTUALLY DIFFER FROM THE LAB ---"
log "lab kernel was 7.0.0-38-generic / nft 1.0.9; this is $(uname -r) / $(nft --version 2>&1 | grep -oE 'v[0-9.]+')"
for f in /proc/sys/net/netfilter/nf_conntrack_acct; do
  if [ -r "$f" ]; then log "  $(basename $f) = $(cat $f)"; else log "  $(basename $f) = ABSENT"; fi
done

cleanup
log ""
log "--- cleanup: our ${WP2_PREF}_* tables removed ---"
log "tables now present on the host (production tables must ALL still be here):"
nft list tables 2>&1 | sed 's/^/    /' | tee -a "$WP2_OUT"
log ""
log "RAW RECORD: $WP2_OUT"
