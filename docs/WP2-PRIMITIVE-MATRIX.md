# WP2 — nftables primitive matrix on the TARGET kernel

**Status: complete. One design assumption in the plan is REFUTED; the working substitute is
established and verified.**

Target: kernel `6.12.111+deb13-amd64`, nftables `v1.1.3 (Commodore Bullmoose #4)`.
Every earlier result in `SERVER-IMPL-TRACK.md` §1.1/§2.2 was taken on kernel `7.0.0-38-generic`
with nftables `1.0.9`, so none of it carried weight here. This run is the same matrix on the
deployment target.

Run: `flock -n /tmp/tg-meter.lock -c 'sudo -n bash wp2-primitive-matrix.sh'` — under the mutex,
because the host is shared. Raw record: `wp2-primitive-matrix.txt`.

## The finding that changes the design

**`delete quota` is BLOCKED while any rule references it — so the "atomic quota limit swap" the
control plane was designed around does not exist on the target.**

```
A. delete quota while a rule references it     -> Error: Device or resource busy   [BLOCKED]
B. delete+add (limit swap) while referenced    -> Error: Device or resource busy   [BLOCKED]
C. the SAME swap when NOT referenced           -> OK                                [WORKS]
```

**C is why the lab got this wrong.** `SERVER-IMPL-TRACK.md` §2.2 recorded "atomic limit change in
ONE transaction — accepted (`SWAP-OK`)" — but that was measured with a quota that **no rule
pointed at**. A metered quota *always* has a rule pointing at it, so the primitive was verified in
a configuration that cannot occur. This is a textbook case of a lab result that does not transfer,
and it is exactly what the re-test existed to catch.

**The working substitute (verified):** re-arm by **replacing the metered RULE by handle, creating a
new quota object in the same `nft -f`**.

```
delete rule ip <t> <chain> handle <H>
add quota ip <t> q_<new> { over <new_limit> bytes }
add rule  ip <t> <chain> handle <H> <match> counter name <c> quota name q_<new> drop
```

Verified: `PATH1_OK`. The rule came back at the same handle referencing the new quota, the
**monotonic counter survives** the rule replacement (it is a separate object), and the whole thing
is one transaction. `reset quota` also works while the quota is referenced.

Consequence for the control-plane design: the re-arm primitive is **rule-replacement**, and the
quota's identity changes on each re-arm. The object the daemon must track is therefore the
**counter** (monotonic, stable across re-arms) plus the chain's rule handle — not a long-lived
quota named per client.

## Full matrix — target kernel

| Primitive | Result | Note |
|---|---|---|
| create table | OK | |
| create metered chain, `policy drop` | OK | the required shape |
| named `counter` object | OK | |
| named `quota` object | OK | |
| rule: counter + quota + drop | OK | |
| quota then `accept` in an accept-policy chain | OK *(builds)* | and it is the C1 hazard: it accepts over-quota traffic |
| `over 0 bytes` accepted as a limit | OK *(builds)* | means **UNLIMITED**, not a block |
| declare counter **map** | OK | |
| declare **map with `flags dynamic`** | **EOPNOTSUPP** | confirms the lab |
| **`update @map { ip saddr }`** | **EOPNOTSUPP** | confirms the lab — no dynamic map writes |
| declare **quota map** | OK | but has no usable element syntax |
| **add element to a counter map** | **EINVAL** | confirms: maps cannot be populated either way |
| delete quota while referenced | **EBUSY** | **NEW — refutes the plan** |
| delete+add (limit swap) while referenced | **EBUSY** | **NEW — refutes the plan** |
| delete+add while *unreferenced* | OK | what the lab measured; not a real configuration |
| **replace rule by handle** (new quota in same tx) | **OK** | **the working re-arm** |
| counter survives a rule replacement | **OK** | |
| `reset quota` while referenced | **OK** | |
| `reset counter` | OK | |
| `nft -j list table` | OK | one netlink round trip for the whole table — the per-tick read |
| `nf_conntrack_acct` | `0` | conntrack accounting is off; per-flow accounting is not free |

Object shapes read back from `nft -j` (what the daemon parses):

```json
{"counter": {"family":"ip","name":"c1","table":"…","handle":2,"packets":0,"bytes":0}}
{"quota":   {"family":"ip","name":"…","table":"…","handle":3,"bytes":1000000,"used":0,"inv":true}}
```

`inv: true` on a quota means inverted: the rule fires while **under** budget. `over 0 bytes` prints
with **no** `over` line, which is why it reads as unlimited rather than as a zero limit.

## Safety

The script touches **only** tables named `__wp2_*`, deletes exactly those, and never runs
`nft flush ruleset`. Production tables were verified intact afterwards:

```
table ip filter   table ip6 filter   table inet f2b-table   table inet fips-exit
table ip nat      table ip6 nat      table ip raw           table inet fips
table ip tgmeter
```

`table ip tgmeter` is the WP1 ceiling from the sibling PR, still standing with `policy drop`.

## What this means for the remaining work packages

- **WP3 (control plane):** the re-arm path is **rule-replacement by handle**, not quota-limit
  swapping. Quota objects are short-lived; quotas are created per arm and the old name is dropped
  with the replaced rule. The durable identity is the **counter**.
- **WP4 (daemon):** journal the counter delta before any mutation (unchanged), and on a re-arm
  write the rule-replacement transaction. `nft -j list table` is the single per-tick read.
- **WP5 (accuracy harness):** unchanged, but it must assert the rule-replacement path, not a
  quota-limit swap, since the latter cannot run on the target at all.
- **The design's honesty note must be updated:** "atomic quota limit swap" appears in the plan as a
  solved problem. It is not solvable on this kernel. The substitute is equivalent in effect
  (budget changes atomically) but differs in mechanism, and the difference matters because it
  changes *which object is stable across re-arms*.

## Reproduce

```
scp wp2-primitive-matrix.sh vps2fips:/tmp/wp2.sh
ssh vps2fips "flock -n /tmp/tg-meter.lock -c 'sudo -n bash /tmp/wp2.sh'"
```

Every identifier and threshold is a variable in the script (`WP2_LOCK`, `WP2_PREF`, `WP2_OUT`),
so it is config-as-code and its thresholds cannot drift silently.
