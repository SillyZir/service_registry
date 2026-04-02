`Gno.land` · `Smart Contracts` · `Infrastructure`

# service_registry

On-chain service discovery for Gno.land.

## Problem

There is no standard way to find out what contracts exist on Gno.land, what they do, or who maintains them. A developer building a DEX aggregator has no way to discover available token contracts. A DAO toolkit can't find registered governance realms. A frontend can't enumerate available oracles.

Every project maintains its own documentation, its own README, its own "list of contracts" — none of which are queryable on-chain. Composability requires discovery, and discovery requires a registry.

## Solution

`service_registry` is a shared realm where developers register their contracts with a name, type, description, and optional metadata. Any realm, frontend, or tool can query the registry to discover what services are available and how to integrate with them.

```
RegisterService(cross, "my_token", "ERC20-style fungible token on Gno", "token", "symbol=GNT,decimals=6")
```

Once registered, the service is discoverable:

```
GetService("my_token")     // full details
ListServices()             // all registered names
ListByType("token")        // filter by type
```

## Why this matters

- **Developers** can discover existing contracts before building something that already exists
- **Aggregators** can enumerate all services of a given type (tokens, oracles, DEXes)
- **Frontends** can auto-populate available integrations without hardcoding addresses
- **DAOs** can maintain a catalog of all contracts they control
- **Ecosystem tools** can build dashboards, explorers, and analytics from a single source

Without a registry, the ecosystem is a dark forest where every contract is invisible unless you already know its address.

## How it works

Services are stored in a map keyed by a unique lowercase name. Each entry has:

- **Name** — unique identifier (lowercase alphanumeric + underscores)
- **Owner** — the address that registered it (determined by `std.PreviousRealm()`, not a parameter)
- **Type** — category string (e.g., `"token"`, `"dex"`, `"oracle"`, `"dao"`, `"nft"`)
- **Description** — what the service does
- **Metadata** — freeform string for additional context (addresses, symbols, config)

Only the owner can update or deregister their service. Ownership can be transferred.

## Usage

### Register

```
RegisterService(cross, "gnot_swap", "AMM DEX for GNOT pairs", "dex", "router=g1abc...,fee=30bp")
```

### Update

```
UpdateService(cross, "gnot_swap", "AMM DEX for GNOT and GRC20 pairs", "dex", "router=g1abc...,fee=25bp")
```

### Query

```
GetService("gnot_swap")
// Name: gnot_swap
// Owner: g1xyz...
// Type: dex
// Description: AMM DEX for GNOT and GRC20 pairs
// Metadata: router=g1abc...,fee=25bp
```

### Discover by type

```
ListByType("token")
// returns: "gnot, wrapped_btc, usdc_gno"
```

### Transfer ownership

```
TransferOwnership(cross, "gnot_swap", g1new_owner...)
```

### Deregister

```
Deregister(cross, "gnot_swap")
```

## Integrating from another realm

```go
import "gno.land/r/service_registry"

func FindOracle() string {
    oracles := service_registry.ListByType("oracle")
    if oracles == "none" {
        panic("no oracle services registered")
    }
    // parse first oracle name, query its details
    return service_registry.GetService(strings.Split(oracles, ", ")[0])
}
```

## API

| Function | Access | Description |
|----------|--------|-------------|
| `RegisterService(cross, name, desc, type, meta)` | Anyone | Register a service. Caller becomes owner. |
| `UpdateService(cross, name, desc, type, meta)` | Owner | Update description, type, and metadata. |
| `TransferOwnership(cross, name, newOwner)` | Owner | Hand off control. |
| `Deregister(cross, name)` | Owner | Remove permanently. |
| `GetService(name)` | Anyone | Full service details. |
| `ListServices()` | Anyone | All registered names. |
| `ListByType(type)` | Anyone | Filter by service type. |
| `Render(path)` | Anyone | Markdown table of all services. |

## Name rules

Service names must be:
- Lowercase letters, digits, and underscores only
- Non-empty
- Unique (first-come-first-served)

Examples: `my_token`, `dao_treasury_v2`, `price_oracle`

## Query on Gno.land

```
gnokey query vm/qeval --data 'gno.land/r/service_registry.ListByType("token")' --remote <rpc>
gnokey query vm/qeval --data 'gno.land/r/service_registry.GetService("my_token")' --remote <rpc>
```

Visit `/r/service_registry` on any Gno.land node to browse all registered services.

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
