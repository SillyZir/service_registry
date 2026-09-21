# service_registry — Technical Specification

## Overview

`service_registry` is a Gno realm that provides a shared, permissionless directory of
on-chain services. Developers register contracts with a package path and structured
metadata; any realm or tool can query the registry to discover and integrate available
services.

The realm has no admin, no pause, no upgrade hook and no deployer privilege. It handles no
funds.

## Data Model

### Service

```go
type Service struct {
    Name        string   // unique lowercase identifier
    Owner       address  // controls updates, transfer and deregistration
    Registrant  address  // ORIGINAL registrant; immutable through transfers
    PkgPath     string   // the realm the service lives at — what integrators resolve
    Description string   // what the service does
    ServiceType string   // category: "token", "dex", "oracle", "dao", etc.
    Metadata    string   // freeform additional context
}
```

### Reservation

```go
type Reservation struct {
    Owner      address
    Registrant address
    Expires    time.Time
}
```

A deregistered name is held for `ReservationPeriod` (90 days) against both its former owner
and its original registrant. The reservation is **finite** by design: an eternal tombstone
would let an attacker cycle register/deregister to lock the whole namespace forever, and
would strand a name against its original registrant permanently.

### Storage

```go
services      map[string]*Service      // name → service entry
names         []string                 // insertion-ordered name list
retired       map[string]*Reservation  // name → time-bounded reservation
ownerServices map[address]int          // O(1) quota index, kept zero-free
pendingOwners map[string]address       // name → nominated-but-unaccepted owner
```

`names` maintains registration order for deterministic iteration in `Render`,
`ListServices` and `ListByType`. **No map is ranged anywhere in the realm** — `len(services)`
is the only map-wide read — so rendered output is a function of state, never of map layout.

`ownerServices` is pruned to zero-free: an owner that drops to zero holdings is deleted
outright, so the index cannot accumulate dead keys.

## Limits

| Constant | Value | Role |
|----------|-------|------|
| `MaxServices` | 1000 | Global state bound. Kept at 1000 so the linear scans over `names` stay affordable in one transaction. |
| `MaxServicesPerOwner` | 20 | **The anti-squat defense.** Enforced at registration and at transfer *consent*. |
| `MaxNameLen` | 64 | |
| `MaxTypeLen` | 32 | |
| `MaxPkgPathLen` | 128 | |
| `MaxDescriptionLen` | 500 | |
| `MaxMetadataLen` | 2000 | |
| `ReservationPeriod` | 90 days | Post-deregistration hold. |
| `MaxRenderServices` | 25 | Bound on `Render` output. |

## Authentication

Every crossing entrypoint takes `cur realm` and derives the caller **once**, inline, via
`cur.Previous().Address()`. No address parameter is ever treated as an authenticated
identity — `TransferOwnership`'s `newOwner` is a nomination target, and it cannot act until
it authenticates itself in `AcceptOwnership`.

There is no stack-walking helper. `unsafe.PreviousRealm()` is used only by the stray-send
guard, never for identity.

| Operation | Caller requirement |
|-----------|--------------------|
| `RegisterService` | Anyone (caller becomes owner); subject to both caps and to any live reservation |
| `UpdateService` | Must be service owner |
| `TransferOwnership` | Must be service owner |
| `AcceptOwnership` | Must be the nominated owner |
| `CancelOwnershipTransfer` | Must be service owner |
| `Deregister` | Must be service owner |
| all read queries | Anyone |

### Payment posture

The realm holds no banker, exposes no payable path and has no withdrawal function. Every
crossing entrypoint calls `rejectStraySend(cur)` as its first statement, which aborts — and
therefore reverts the transfer — when a user call attaches coins. The guard tests
`cur.Previous().IsUserCall()`, not `IsUser()`: a `MsgRun` ephemeral can consume the
`OriginSend` envelope before forwarding control. It fails open for realm-routed calls,
whose attached send lands on the intermediary realm and never reaches here.

## Validation

### Names and service types

Non-empty, at most `MaxNameLen` / `MaxTypeLen` bytes, and containing only lowercase letters
(`a-z`), digits (`0-9`) and underscores (`_`). Unique, first-come-first-served.

This prevents namespace collisions, case-sensitivity confusion, and injection via special
characters.

### Package paths

Structural, per-element validation — not a flat charset check:

1. Non-empty, at most `MaxPkgPathLen` bytes.
2. Must start with `gno.land/`.
3. The first element after the prefix must be exactly `r` or `p`, and at least one further
   element must follow.
4. Every subsequent element must be non-empty, must begin with a lowercase letter, and may
   contain only `[a-z0-9_]`.

This refuses `..` traversal, doubled slashes, trailing slashes, hyphens and non-`r`/`p`
roots — all lookalike-squat or allowlist-bypass material.

**What it does not do:** it does not verify that the path exists, is deployed, or is
controlled by the registrant. See *Integrator contract* below.

### Free text

`Description` and `Metadata` are stored verbatim and escaped only at the display boundary,
through `gno.land/p/nt/markdown/sanitize/v0` — `TableCell` in `Render`, `InlineText` in
`GetService`. Truncation is applied to the **raw** text *before* escaping, so an escape
sequence can never be severed at a cell boundary. The sanitizer is applied exactly once; it
is not idempotent.

## Integrator contract

Carried as a doc block on `Resolve` in the source, and reproduced in the README.

1. **A resolution is an attestation, not a proof.** The registry records a claim. It does
   not verify existence, deployment, or control of the path. A self-proving model
   (cf. `r/demo/defi/grc20reg`, which requires the registered object to originate from the
   calling realm) is deliberately **not** adopted: it would mean only realms, never their
   operators, could register a name.
2. **A name is not an authorization.** Resolution answers *"where does this name point"*,
   never *"may this caller act"*. A consumer that derives a subject address inside a
   non-crossing helper reproduces Class-2 designation-forgery in itself.
3. **The target can change.** A resolution is valid only for the transaction that read it.

## Operations

### RegisterService

```
rejectStraySend(cur)
c := cur.Previous().Address()
validate name, pkgPath, description, serviceType, metadata
assert name not already registered
registrant := c
if a reservation exists for name:
    if it has lapsed:  delete it (O(1) lazy reclaim)
    else:              assert c is the former owner or the original registrant
                       preserve the original registrant
assert len(services) < MaxServices
assert ownerServices[c] < MaxServicesPerOwner
services[name] = &Service{... Owner: c, Registrant: registrant}
names = append(names, name); ownerServices[c]++
emit ServiceRegistered
```

Preserving the registrant on an in-window re-registration is what stops a hostile
transferee from deregistering and instantly re-registering to stamp themselves as
registrant and erase the original project's reclaim right.

### UpdateService

```
rejectStraySend(cur)
svc := mustGet(name); assert cur.Previous().Address() == svc.Owner
validate pkgPath, description, serviceType, metadata
oldPath := svc.PkgPath
svc.PkgPath, svc.Description, svc.ServiceType, svc.Metadata = ...
emit ServiceUpdated{name, oldpkgpath: oldPath, pkgpath, type, owner}
```

Name, owner and registrant are immutable through `UpdateService`. An update **may repoint**
the name; the event carries both paths so the repoint is observable.

### TransferOwnership / AcceptOwnership / CancelOwnershipTransfer

Ownership moves in two steps.

```
TransferOwnership:  owner-only. "" clears the nomination (emits Cancelled).
                    rejects self-nomination. Writes pendingOwners[name].
                    Changes NOTHING about current control.
AcceptOwnership:    nominee-only. Checks the NOMINEE's quota here, at consent.
                    Moves the quota, clears pendingOwners, emits Transferred.
CancelOwnershipTransfer: owner-only. Requires an open nomination.
```

The one-step form this replaces was a permanent-brick hazard: `address.IsValid()` only
checks bech32 form, so a well-formed but unowned destination committed immediately, after
which the entry could never be updated, transferred or deregistered — and because it could
never be deregistered it could never enter the reservation window either, so the *name*
became a permanent hole in a shared global namespace.

Checking quota at consent rather than at nomination means a nomination can never push an
account past `MaxServicesPerOwner` without that account agreeing to it.

### Deregister

```
rejectStraySend(cur)
svc := mustGet(name); assert cur.Previous().Address() == svc.Owner
retired[name] = &Reservation{svc.Owner, svc.Registrant, now + ReservationPeriod}
delete(services, name); ownerServices[svc.Owner]--
delete(pendingOwners, name)          // a nomination must not outlive its entry
remove name from the names slice
emit ServiceDeregistered
```

The linear removal from `names` is O(`MaxServices`) string compares in a single
transaction — bounded, paid by the deregisterer, and kept linear because `ListServices`
documents registration order as part of its contract.

### ListByType

Linear scan over `names`, filtering by `svc.ServiceType`. Returns comma-separated matches
or `"none"`.

At the declared scale (≤ 1000 services) a linear scan is adequate. A secondary
`map[string][]string` index would be warranted only at tens of thousands.

## Render

Produces a markdown table with columns Name, Type, PkgPath, Owner, Description
(description truncated to 60 runes of raw text before escaping).

`Render` is **bounded to `MaxRenderServices = 25` rows**, and prints the true total in its
header plus an explicit truncation notice naming `ListServices`, `ListByType` and
`GetService` for complete data. The asymmetry with the unbounded list queries is
deliberate: `Render` is reachable by any viewer through gnoweb and `vm/qrender`, so its
cost lands on third parties, whereas a query caller pays for its own read.

Uses `strings.Builder` only — no `ufmt`, no format specifiers that could fail at runtime.
It checks for the empty state and for nil entries, and never panics regardless of internal
state. The `path` argument is never echoed.

## Invariants

1. **Unique names** — `RegisterService` aborts if the name is taken.
2. **Non-empty required fields** — name, pkgPath, description and service type must all be
   non-empty and valid.
3. **Owner-only mutations** — only `service.Owner` can update, nominate, cancel or
   deregister.
4. **Consent-gated ownership** — `Owner` changes only in `AcceptOwnership`, only to the
   address that called it.
5. **Registrant immutability** — `Registrant` is never rewritten by a transfer, and is
   preserved across an in-window re-registration.
6. **Quota consistency** — `ownerServices[a]` equals the number of entries with
   `Owner == a`, for every `a`; owners at zero are absent from the map entirely.
7. **No orphan nominations** — `pendingOwners[name]` exists only while `services[name]`
   exists.
8. **Ordered listing** — `names` reflects registration order; deregistration removes the
   entry and compacts the slice atomically with the map delete.
9. **No value custody** — the realm's balance is only ever changed by direct chain-level
   sends it cannot intercept; no entrypoint accepts coins.

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Register with uppercase name | Aborts: `name must be 1-64 chars, lowercase alphanumeric with underscores only` |
| Register with spaces in name | Aborts: same validation |
| Register a 21st name from one address | Aborts: `address already holds the maximum of 20 services` |
| Register when 1000 entries exist | Aborts: `global service limit reached` |
| Register `gno.land/r/../../etc/passwd` | Aborts: `invalid pkgpath element` |
| Register a name reserved to someone else, in window | Aborts: `name is reserved for its former owner` |
| Register a name whose reservation has lapsed | Allowed for anyone; the new registrant is stamped as `Registrant` and the tombstone is reclaimed |
| Update non-existent service | Aborts: `service not found` |
| Update by non-owner | Aborts: `only the owner can update this service` |
| Nominate yourself | Aborts: `new owner is already the owner` |
| Accept without a nomination | Aborts: `no pending ownership transfer for: <name>` |
| Accept when the nominee is at quota | Aborts: `address already holds the maximum of 20 services`; the entry stays with its owner |
| Deregister with a nomination open | Allowed; the nomination is cleared |
| Attach coins to any entrypoint | Aborts: `this realm does not accept coins` (the transfer reverts) |
| `Resolve` on a deregistered name | Panics: `service not found` |
| `TryResolve` on a deregistered name | Returns `("", false)` — never panics |
| `ListByType` with no matches | Returns `"none"` |
| Empty metadata | Allowed — metadata is optional |
| Description containing `[x](url)` | Stored verbatim; escaped at every display boundary |
| More than 25 services | `Render` shows 25 rows plus a truncation notice with the true total |

## Limitations

Stated plainly rather than designed around:

- **`PkgPath` is an unverified claim.** Structure is validated; existence, deployment and
  control are not. This is the single most important thing an integrator must internalize.
- **Sybil resistance is bounded, not solved.** `MaxServicesPerOwner` raises the cost of
  monopolization from one funded key to fifty. Eliminating it entirely would require a fee,
  a stake, or an allowlist, each of which changes the application's economic and trust model.
- **Expired reservations are not swept.** `retired` grows monotonically with deregistration
  churn. It is never iterated — only keyed lookups and a keyed write — so there is no loop
  to blow up and no gas amplification onto other users, and every byte is paid for by the
  caller's own storage deposit. A lapsed tombstone is reclaimed lazily, in O(1), when it is
  consulted.
- **No full-text search.** Queries are by exact name or type.
- **No pagination** for `ListServices` or `ListByType` — deliberately, so integrators get
  the complete set.
- **No versioning.** Entries are mutable via `UpdateService`, with no on-chain history —
  but every mutation is an event, including the old package path.
- **Metadata is unstructured.** The registry does not validate or parse it.
