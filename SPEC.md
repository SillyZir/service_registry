# service_registry — Technical Specification

## Overview

`service_registry` is a Gno realm that provides a shared directory of on-chain services. Developers register contracts with structured metadata, and any realm or tool can query the registry to discover and integrate available services.

## Data Model

### Service

```
type Service struct {
    Name        string       // unique lowercase identifier
    Owner       std.Address  // controls updates and deregistration
    Description string       // what the service does
    ServiceType string       // category: "token", "dex", "oracle", "dao", etc.
    Metadata    string       // freeform additional context
}
```

### Storage

```
services map[string]*Service   // name → service entry
names    []string              // insertion-ordered name list
```

The `names` slice maintains registration order for deterministic iteration in `Render` and `ListServices`.

## Authentication

All write operations use `std.PreviousRealm().Address()` to identify the caller. No address parameters are accepted for authentication — the caller identity is derived from the transaction context and cannot be spoofed.

| Operation | Caller requirement |
|-----------|--------------------|
| RegisterService | Anyone (caller becomes owner) |
| UpdateService | Must be service owner |
| TransferOwnership | Must be service owner |
| Deregister | Must be service owner |
| GetService | Anyone (read-only) |
| ListServices | Anyone (read-only) |
| ListByType | Anyone (read-only) |

## Name Validation

Service names are validated on registration:
- Must be non-empty
- Must contain only lowercase letters (`a-z`), digits (`0-9`), and underscores (`_`)
- Must be unique (first-come-first-served)

This prevents namespace collisions, injection via special characters, and case-sensitivity confusion.

## Invariants

1. **Unique names**: `RegisterService` panics if the name is taken.
2. **Non-empty required fields**: name, description, and service type must all be non-empty.
3. **Owner-only mutations**: only `service.Owner` can update, transfer, or deregister.
4. **Ordered listing**: `names` slice reflects registration order. Deregistration removes the entry and compacts the slice.
5. **No orphan state**: `Deregister` removes from both `services` map and `names` slice atomically.

## Operations

### RegisterService

```
validate name (non-empty, valid chars, unique)
validate description, serviceType (non-empty)
services[name] = &Service{..., Owner: caller()}
names = append(names, name)
```

### UpdateService

```
svc = mustGet(name)
assert caller() == svc.Owner
svc.Description = description
svc.ServiceType = serviceType
svc.Metadata = metadata
```

Name and owner are immutable through UpdateService. Owner can only change via TransferOwnership.

### Deregister

```
svc = mustGet(name)
assert caller() == svc.Owner
delete(services, name)
remove name from names slice
```

Deregistration is permanent. The name becomes available for re-registration by anyone.

### ListByType

Linear scan over `names`, filtering by `svc.ServiceType`. Returns comma-separated matches or `"none"`.

For the current expected scale (hundreds to low thousands of services), linear scan is adequate. If the registry grows to tens of thousands, a secondary index `map[string][]string` (type → names) would be warranted.

## Render

Produces a markdown table with columns: Name, Type, Owner, Description (truncated to 60 chars). Uses `strings.Builder` only — no `ufmt`, no format specifiers that could fail at runtime.

Render checks for nil maps and nil entries at every level. It never panics regardless of internal state.

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Register with uppercase name | Panics: "must be lowercase alphanumeric" |
| Register with spaces in name | Panics: same validation |
| Update non-existent service | Panics: "service not found" |
| Update by non-owner | Panics: "only the owner can update" |
| Deregister then re-register same name | Allowed — name is freed on deregister |
| GetService on deregistered name | Panics: "service not found" |
| ListByType with no matches | Returns "none" |
| Empty metadata | Allowed — metadata is optional |
| Very long description | Stored as-is; Render truncates display to 60 chars |

## Limitations

- No full-text search. Queries are by exact name or type.
- No pagination for `ListServices` or `ListByType`. All results returned at once.
- No versioning. Service entries are mutable via `UpdateService`, with no history.
- No event emission. Consumers must poll to detect new registrations.
- Metadata is unstructured. The registry does not validate or parse it.
