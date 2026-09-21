`Gno.land` · `Smart Contracts` · `Infrastructure`

# service_registry

On-chain service discovery for Gno.land.

## Problem

There is no standard way to find out what contracts exist on Gno.land, what they do, or who maintains them. A developer building a DEX aggregator has no way to discover available token contracts. A DAO toolkit can't find registered governance realms. A frontend can't enumerate available oracles.

Every project maintains its own documentation, its own README, its own "list of contracts" — none of which are queryable on-chain. Composability requires discovery, and discovery requires a registry.

## Solution

`service_registry` is a shared realm where developers register their contracts with a name, package path, type, description, and optional metadata. Any realm, frontend, or tool can query the registry to discover what services are available and how to integrate with them.

```
RegisterService(cross(cur), "my_token", "gno.land/r/demo/my_token", "ERC20-style fungible token on Gno", "token", "symbol=GNT,decimals=6")
```

Once registered, the service is discoverable:

```
Resolve("my_token")        // the package path — the primary integration query
GetService("my_token")     // full details
ListServices()             // all registered names
ListByType("token")        // filter by type
```

## Read this before you integrate

`Resolve` is the whole point of the registry, and it has a contract. The same three points
are carried verbatim as a doc block on `Resolve` in the source.

1. **A resolution is an attestation, not a proof.** This realm records that some address
   claimed a name for some package path. It does **not** verify that the path exists, that
   it is deployed, or that the registrant controls it. (Contrast `r/demo/defi/grc20reg`,
   which proves control by requiring the registered token object to originate from the
   calling realm. No equivalent proof exists for a bare path string, and requiring one
   would mean only realms — never their human operators — could ever register a name.)
2. **A name is not an authorization.** Never grant a privilege, route a payment, or admit a
   caller because `Resolve` returned its path. Resolution answers *"where does this name
   point"*, never *"may this caller act"*. Derive authority from your own crossing
   entrypoint's `cur.Previous().Address()`, or from an explicit access-control realm such
   as [permission_registry](https://github.com/SillyZir/permission_registry).
3. **The target can change.** The owner may repoint a name at any time via `UpdateService`,
   and ownership itself is transferable. Treat a resolution as valid only for the
   transaction that read it. The `ServiceUpdated` event carries **both** the old and the new
   package path precisely so a repoint is observable in the transaction log rather than
   something you have to poll for.

## Why this matters

- **Developers** can discover existing contracts before building something that already exists
- **Aggregators** can enumerate all services of a given type (tokens, oracles, DEXes)
- **Frontends** can auto-populate available integrations without hardcoding addresses
- **DAOs** can maintain a catalog of all contracts they control
- **Ecosystem tools** can build dashboards, explorers, and analytics from a single source

Without a registry, the ecosystem is a dark forest where every contract is invisible unless you already know its address.

## How it works

Services are stored in a map keyed by a unique lowercase name. Each entry has:

- **Name** — unique identifier (lowercase alphanumeric + underscores, ≤ 64 chars)
- **Owner** — the address that controls the entry, derived from `cur.Previous().Address()`, never a parameter
- **Registrant** — the *original* registrant, immutable through ownership transfers
- **PkgPath** — the realm the service lives at (`gno.land/r/...` or `gno.land/p/...`) — resolve it with `Resolve(name)`
- **Type** — category string (e.g., `"token"`, `"dex"`, `"oracle"`, `"dao"`, `"nft"`)
- **Description** — what the service does
- **Metadata** — freeform string for additional context (symbols, config)

Only the owner can update or deregister their service. Ownership transfer is a **two-step
handoff**: the owner nominates, the nominee accepts.

The realm is fully permissionless — there is no admin, no pause, no upgrade hook and no
privilege for the deployer. It handles no funds; coins attached to any call are rejected,
which reverts the transfer.

## Anti-squat design

A shared permissionless namespace is only useful if one funded key cannot take all of it.

- **`MaxServicesPerOwner = 20`** — one address may hold at most 20 names at a time. A
  namespace sweep therefore costs 50 distinct funded addresses instead of one. This does
  not *eliminate* sybil exhaustion — no permissionless namespace can, short of a fee, a
  stake, or an allowlist — but it removes the trivial single-key attack.
- **`MaxServices = 1000`** — a pure global state bound, not the anti-squat defense.
- **90-day reservation** — a deregistered name stays reserved for its former owner **and**
  its original registrant. Integrators who still resolve it cannot be silently redirected
  by a squatter. The reservation is finite, so tombstones cannot lock the namespace
  forever, and a lapsed one is reclaimed the moment it is consulted.
- **Registrant survives a hostile recycle** — an in-window re-registration preserves the
  original registrant, so a hostile transferee cannot deregister-and-re-register to stamp
  themselves and erase the original project's reclaim right.

## Usage

### Register

```
RegisterService(cross(cur), "gnot_swap", "gno.land/r/demo/gnot_swap", "AMM DEX for GNOT pairs", "dex", "router=g1abc...,fee=30bp")
```

### Update

```
UpdateService(cross(cur), "gnot_swap", "gno.land/r/demo/gnot_swap", "AMM DEX for GNOT and GRC20 pairs", "dex", "router=g1abc...,fee=25bp")
```

### Query

```
Resolve("gnot_swap")
// gno.land/r/demo/gnot_swap

GetService("gnot_swap")
// Name: gnot_swap
// Owner: g1xyz...
// PkgPath: gno.land/r/demo/gnot_swap
// Type: dex
// Description: AMM DEX for GNOT and GRC20 pairs
// Metadata: router=g1abc...,fee=25bp
```

### Discover by type

```
ListByType("token")
// returns: "gnot, wrapped_btc, usdc_gno"
```

### Transfer ownership (two steps)

```
TransferOwnership(cross(cur), "gnot_swap", g1new_owner...)   // owner nominates
AcceptOwnership(cross(cur), "gnot_swap")                     // nominee consents
```

Nomination changes nothing — the sitting owner keeps full control until the nominee
accepts. This is deliberate: `address.IsValid()` only checks bech32 form, so a one-step
transfer to a well-formed but unowned address would brick the entry permanently, and
because a bricked entry can never be deregistered it can never enter the reservation
window either — the **name** would become a permanent hole in a shared namespace.

To withdraw a nomination:

```
CancelOwnershipTransfer(cross(cur), "gnot_swap")
// or equivalently: TransferOwnership(cross(cur), "gnot_swap", "")
```

### Deregister

```
Deregister(cross(cur), "gnot_swap")
```

The name stays reserved for its former owner and its original registrant for 90 days, so
integrators who still resolve the name can never be redirected by a squatter in that
window. Any pending nomination dies with the entry.

## Events

Every state transition emits an event, so consumers and indexers can watch rather than poll:

| Event | Fields |
|-------|--------|
| `ServiceRegistered` | `name`, `pkgpath`, `type`, `owner`, `registrant` |
| `ServiceUpdated` | `name`, **`oldpkgpath`**, **`pkgpath`**, `type`, `owner` |
| `OwnershipTransferProposed` | `name`, `owner`, `pending` |
| `OwnershipTransferred` | `name`, `from`, `to` |
| `OwnershipTransferCancelled` | `name`, `owner` |
| `ServiceDeregistered` | `name`, `owner`, `registrant` |

`ServiceUpdated` carrying both paths is the mechanism that makes a bait-and-switch repoint
detectable.

## Integrating from another realm

```go
import "gno.land/r/service_registry"

func FindOracle(cur realm) string {
    // TryResolve never panics — prefer it inline so a missing entry
    // cannot brick your own realm.
    path, ok := service_registry.TryResolve("price_oracle")
    if !ok {
        panic("price_oracle is not registered")
    }
    // `path` is where the oracle CLAIMS to live. It is not proof, and it
    // is not authorization — see "Read this before you integrate".
    return path
}
```

## API

| Function | Access | Description |
|----------|--------|-------------|
| `RegisterService(cross(cur), name, pkgpath, desc, type, meta)` | Anyone | Register a service. Caller becomes owner. Subject to the per-owner and global caps. |
| `UpdateService(cross(cur), name, pkgpath, desc, type, meta)` | Owner | Update path, description, type, and metadata. May repoint — emits old and new path. |
| `TransferOwnership(cross(cur), name, newOwner)` | Owner | **Nominate** a new owner. `""` clears a pending nomination. |
| `AcceptOwnership(cross(cur), name)` | Nominee | Complete the handoff. Nominee's quota is checked here, at consent. |
| `CancelOwnershipTransfer(cross(cur), name)` | Owner | Withdraw a pending nomination. |
| `Deregister(cross(cur), name)` | Owner | Remove the entry; the name enters a 90-day reservation. |
| `Resolve(name)` | Anyone | The package path. Panics on unknown names. |
| `TryResolve(name)` | Anyone | `(path, ok)` — never panics. |
| `GetOwner(name)` | Anyone | Current owner address. |
| `GetPendingOwner(name)` | Anyone | Nominated owner, or `"none"`. |
| `GetService(name)` | Anyone | Full service details, sanitized for display. |
| `ListServices()` | Anyone | All registered names, in registration order. |
| `ListByType(type)` | Anyone | Filter by service type. |
| `ServiceCount()` | Anyone | `(count, limit)` — global headroom. |
| `OwnerServiceCount(owner)` | Anyone | `(count, limit)` — per-owner headroom. |
| `Render(path)` | Anyone | Markdown table, bounded to 25 rows. Never panics. |

`ListServices` and `ListByType` are deliberately **not** truncated — an integrator
enumerating the registry needs the complete set, and a query caller pays for its own read.
`Render` **is** bounded, because it is reachable by any viewer through gnoweb, so its cost
would otherwise land on third parties rather than on whoever grew the state.

## Name and path rules

Service names must be non-empty, at most 64 characters, and contain only lowercase letters,
digits and underscores. Names are unique and first-come-first-served.

Examples: `my_token`, `dao_treasury_v2`, `price_oracle`

Package paths are validated structurally, per element — `gno.land/r/...` or
`gno.land/p/...`, each element non-empty, starting with a lowercase letter and containing
only `[a-z0-9_]`. This refuses traversal (`..`), doubled slashes, trailing slashes, hyphens
and non-`r`/`p` roots, all of which are lookalike-squat or allowlist-bypass material.

All free text (`Description`, `Metadata`) is escaped through
`gno.land/p/nt/markdown/sanitize/v0` before it reaches any rendered surface, so a
registrant cannot inject a working markdown link or image into the registry's own page.

## Query on Gno.land

```
gnokey query vm/qeval --data 'gno.land/r/service_registry.Resolve("my_token")' --remote <rpc>
gnokey query vm/qeval --data 'gno.land/r/service_registry.ListByType("token")' --remote <rpc>
```

Visit `/r/service_registry` on any Gno.land node to browse registered services.

## Provenance

- [`DISCOVERY.md`](DISCOVERY.md) — the committed, reproducible discovery record: what was
  searched, what related implementations exist on-chain and off, how each was classified,
  which were reused and why, and the limits of the search. It does **not** claim
  ecosystem-wide uniqueness.

## Stack

- [Gno](https://gno.land) — Go-like smart contract language
- [Gno.land](https://gno.land) — Layer 1 blockchain

## Part of the Gno Infrastructure Stack

| Realm | Layer |
|-------|-------|
| [fee_split](https://github.com/SillyZir/fee-split) | Revenue & value flow |
| [permission_registry](https://github.com/SillyZir/permission_registry) | Access control |
| **service_registry** | **Discovery** |
| [upgrade_registry](https://github.com/SillyZir/upgrade_registry) | Upgrade tracking |
| [timelock_guardian](https://github.com/SillyZir/timelock_guardian) | Security |

---
