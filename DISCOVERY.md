# service_registry — discovery & reuse record

Provenance record for the mandatory pre-implementation duplication search.
Written before any port or remediation work, so the reuse decisions below can be
audited against what was actually searched rather than reconstructed afterwards.

- **Search date:** 2026-09-21
- **Application:** `service_registry` (SillyZir/service_registry @ `8f77853a77f595184e3fd35d53f222a13d898fa7`)
- **Target chain:** pearl-1 (`gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/service_registry`). Never mainnet.
- **What this application claims to be:** a global, human-readable
  `name → gno package path` directory, so an integrator can call
  `Resolve("mytoken")` and get `gno.land/r/.../mytoken` instead of hard-coding it.

---

## 1. Sources searched

### 1a. Pearl-1 on-chain enumeration (authoritative for the deploy target)

Full package enumeration, not a sampled or curated list:

```
curl -s 'https://rpc.pearl.testnets.gno.land/abci_query?path="vm/qpaths"&data=0x'
```

- **Height:** 604980
- **Result:** 680 paths — **190 `gno.land/p/`**, **440 `gno.land/r/`**, 50 stdlib.
- Saved locally as `/tmp/pkgs5b.txt` for the sweeps below. Reproduce with the
  command above; the chain moves, so a re-run will return a superset.

Keyword sweeps run over the full enumeration:

| Pattern | Hits |
|---|---|
| `registr\|servic\|discover\|resolv\|naming\|/names\|director\|catalog\|/index\|lookup\|dns\|alias` | 6 |
| `nslogic\|nsdata\|/ns` (second pass — see §4, search-blindness note) | 34 |

### 1b. Cosmic Bull catalog

`pearl/INFRASTRUCTURE.md` — the portfolio catalog of every `/p/` primitive and
`/r/` application Cosmic Bull has deployed, including the retroactive
discovery analysis of 2026-09-20. Grepped for
`registr|discover|service|resolv|naming|directory|catalog|index|lookup`:
no service-discovery or name-resolution component is catalogued.

### 1c. Cosmic Bull `/p/` and `/r/` sources (local, whole-tree)

Every `.gno` file under `pearl/p/` and `pearl/r/` (22 files, 11 packages:
`p/coinio`, `p/feeledger`, `r/bounties`, `r/coindemo`, `r/feesplit`, `r/grants`,
`r/market`, `r/permission_registry`, `r/timelock_guardian`, `r/upgrade_registry`,
`r/vault`) grepped for `Resolve|PkgPath|registry|directory|lookup|discover`, then
the three hits read at the exported-API level.

### 1d. Public Gno ecosystem — pinned examples tree

`gnolang/gno@v0.0.0-20260827075919-c4c72fdd288c` (the chain-matched toolchain
commit), `examples/` **including `examples/quarantined/`**, searched by directory
name and by exported-symbol grep.

### 1e. Public GitHub

- `gh search repositories "gno service registry"` — 2 results.
- `gh search code "RegisterService" extension:gno` — 0 results.
- `gh search code "service registry" language:Go extension:gno` — 0 results.
- `gh search code "Resolve pkgPath registry" extension:gno` — 85 results, triaged.
- `gh search code "repo:gnolang/tx-exports Resolve name registry"` — 359 results
  (the deployed-source mirror of pearl/sapphire/mainnet), triaged by path.
- `gh repo list SillyZir --limit 100` — five Gno application repos total
  (`fee_split`, `timelock_guardian`, `upgrade_registry`, `permission_registry`,
  `service_registry`); no second service-discovery repo.

---

## 2. Relevant implementations found

| # | Implementation | Where | What it actually is |
|---|---|---|---|
| 1 | `r/docs/registry` | pinned examples, **quarantined** — *not deployed on pearl-1* (0 hits in the 680-path enumeration) | Package doc literally reads *"Package registry is a service registry."* Entries keyed **`owner:name`** in an avl tree; `Register/Update/Deactivate/Delete`, `Lookup(owner, name)`, `GetAllServices`. Field is a free-text `Endpoint` (500 chars), never validated. |
| 2 | `r/demo/defi/grc20reg` | **live on pearl-1** | GRC20 token registry keyed `rlmPath.symbol`. Registration is **self-proving**: it takes a `*grc20.Token` and rejects a token whose realm differs from the caller's (`TestRegisterRejectsTokenFromDifferentRealm`), plus an overwrite/alias guard. |
| 3 | `ns*` suite — `nsdata`, `nslogic`, `nsview`, `nsmarket`, `nsvote`, `nsnft`, `nsskin` (v1–v5, three deployer addresses) | **live on pearl-1**, 34 paths | A mature ENS-style **domain/name service**: `domain` + `label*domain` records, expiry terms, grace periods, renewal streaks, GRC-721 name tokens, a marketplace, DAO voting, TTL fields, and an admin/recovery/guardian governance layer with a timelock. Resolves a *name* to an **owner address + profile `extra` key/values**. Storage/logic/view are split across swappable realms behind `assertIsTrustedLogic`. |
| 4 | `r/sys/names` | **live on pearl-1** (system realm) | Not a directory. It is the **deploy-authority verifier**: given (address, namespace) it answers whether that address may `MsgAddPackage` there, via personal-address namespaces or an `r/sys/users` registered name. Plus a GovDAO-gated pause. |
| 5 | `r/sys/users` | pinned examples / system realm | Official **username → address** registry; the identity layer `r/sys/names` consults. Maps people, not services. |
| 6 | `r/g1mjc0v90.../name_service` | **live on pearl-1** | 609-byte toy. `type Registry map[string]string`; `Register(name, owner string)` takes the owner **as a string parameter with no caller authentication**; `Resolve(name) string`; `Render`. No ownership enforcement, no transfer, no pkgpath semantics. |
| 7 | `r/samcrew/agent_registry_v2` | **live on pearl-1** | AI-agent marketplace (26.5 KB): credits, earnings, reviews, pause, admin, AVL-backed. Its `Agent` record carries `Endpoint` + `Transport` (`stdio`/`sse`/`streamable-http`) — **off-chain MCP endpoints**, not gno package paths. Notably carries `MaxAgentsPerCreator` and `ReviewRenderMax`. |
| 8 | `r/leon/hor` (Hall of Realms) | pinned examples, quarantined — not on pearl-1 | Realms **self-register** (`Register(cur realm, title, description)`, keyed on the caller's own pkgpath) to be showcased; upvote/downvote ranking. A showcase, not a resolver. |
| 9 | Cosmic Bull `r/upgrade_registry` | **live on pearl-1** (own portfolio) | Contract **migration chain**, keyed by contract **address**, self-registering (`Register` records the caller's own address as the proof of control), with two-step ownership and `GetLatest` chain-walking. Answers "what superseded this address", not "what does this name point at". |
| 10 | Cosmic Bull `r/permission_registry` | **live on pearl-1** (own portfolio) | Multi-tenant ACL: `resource → permission → holder`. Shares the tenancy/quota/reservation shape but stores no locator and performs no resolution. |
| 11 | `p/nt/markdown/sanitize/v0` | **live on pearl-1** | Ecosystem markdown sanitizer, per-lexical-slot (`InlineText`, `TableCell`, `URL`, …). Already used by Cosmic Bull `r/grants`. |
| 12 | `Familyalligatoridaesnowyorchid856/service_registry` | GitHub | Same name and near-identical description. **Not an independent implementation** — `gh api .../commits` shows its first three commits are authored by **SillyZir** with identical commit messages. It is a detached copy of this application's own lineage (GitHub does not flag it as a fork; `parent: none`). Recorded for completeness, not treated as prior art. |

---

## 3. Classification and reuse decisions

Classes per the standing discovery gate: EXACT DUPLICATE / REUSABLE EXISTING
PRIMITIVE / RELATED IMPLEMENTATION / COSMIC BULL EXISTING PRIMITIVE /
GENUINELY NEW.

| # | Implementation | Classification | Decision and reason |
|---|---|---|---|
| 1 | `r/docs/registry` | **RELATED IMPLEMENTATION — closest match found** | **Not reused.** Different key space, which is the whole difference: it keys `owner:name`, so names are per-owner and a global `Resolve("name")` is not expressible — there is no unique name, no squatting surface, and correspondingly no reservation, transfer, or registrant concept. Its `Endpoint` is unvalidated free text, not a gno package path. It is a *teaching example* in the quarantined tree and is not deployed on pearl-1, so it is not importable from the target chain either. **Two things ARE adopted from it** — see the reuse decisions below. |
| 2 | `grc20reg` | **RELATED IMPLEMENTATION** | **Not reused** (GRC20-specific; keyed by token symbol; requires a `*grc20.Token` object). Its *self-proving registration* is adopted as the **benchmark this application is measured against** in the audit — grc20reg proves the registrant controls the path; `service_registry` accepts a `pkgPath` string on trust. That gap is carried into the security audit as an explicit finding rather than glossed over. |
| 3 | `ns*` suite | **RELATED IMPLEMENTATION — largest neighbor** | **Not reused.** Three concrete reasons: (a) *different resolution target* — it resolves a name to an owner address and profile fields, with any locator only expressible as an untyped `extra` key, whereas a package path is this application's entire typed reason to exist; (b) *foreign governance* — `nsdata` writes are gated by `assertIsTrustedLogic`, and the realm is controlled by a third party's admin/recovery/guardian keys with a settable timelock, so depending on it would place Cosmic Bull's registry under an external operator's control and its paid-term expiry model; (c) *economic model* — it is a paid, expiring, NFT-backed namespace; this application is a free permanent-until-deregistered directory. Recorded as the honest answer to "does a name service already exist on pearl-1": **yes, and it is substantial** — it just answers a different question. |
| 4, 5 | `r/sys/names`, `r/sys/users` | **RELATED IMPLEMENTATION (system layer)** | **Not reused, and deliberately not depended on.** They govern *deploy authority* and *human identity*. A service directory sits above both. Noted for the audit: a registered `pkgPath` element charset must not be confused with `r/sys/names`' namespace authorization — passing this realm's validation grants nothing on-chain. |
| 6 | `name_service` | **RELATED IMPLEMENTATION (name collision, no substance)** | **Not reused.** Its `Register(name, owner string)` takes identity as a parameter — the designation-forgery shape. Nothing here is safe to build on. |
| 7 | `agent_registry_v2` | **RELATED IMPLEMENTATION** | **Not reused** (off-chain endpoints, payments, reviews — a marketplace, not a resolver). Its `MaxAgentsPerCreator` and `ReviewRenderMax` are independent ecosystem confirmation of the two bounds Cosmic Bull added to `permission_registry` (per-tenant quota, render cap); both are carried into this application's audit as expected defenses. |
| 8 | `r/leon/hor` | **RELATED IMPLEMENTATION** | **Not reused** (ranking showcase, quarantined, not on pearl-1). Its `init()`-time self-registration is a second precedent for the self-proving pattern in #2. |
| 9 | `upgrade_registry` | **COSMIC BULL EXISTING PRIMITIVE — complementary, not overlapping** | **Not reused as a dependency.** Address-keyed migration chains vs name-keyed path resolution: the two compose (resolve a name here, follow its successor chain there) but neither subsumes the other. A hard dependency would couple two independently-deployed realms for no shared state. |
| 10 | `permission_registry` | **COSMIC BULL EXISTING PRIMITIVE — pattern source, not dependency** | **Not reused as a dependency** (no shared state; a service directory needs no ACL). **Reused as a remediation template**: its audited fixes for per-tenant quota (R1), crossing-entrypoint caller identity (Y1), bounded `Render` (Y3), two-step ownership handoff (Y4), stray-send rejection (Y5), and the explicit integrator-contract block (Y7) are the same six shapes this codebase presents. Reusing the *reasoning* and not re-deriving it is the point of this record. |
| 11 | `p/nt/markdown/sanitize/v0` | **REUSABLE EXISTING PRIMITIVE** | **REUSED.** The upstream source hand-rolls a four-substitution `sanitize()` (backtick, pipe, CR, LF). The ecosystem sanitizer is per-lexical-slot, maintained upstream, already live on pearl-1, and already a Cosmic Bull dependency in `r/grants`. Adopting it replaces bespoke escaping with the ecosystem primitive — exactly the composition-over-reinvention the gate exists to force. |
| — | `service_registry` itself | **RELATED IMPLEMENTATIONS EXIST; not an exact duplicate** | See §5. |

### Reuse decisions, summarized

**Adopted:**
1. `gno.land/p/nt/markdown/sanitize/v0` replaces the hand-rolled `sanitize()` helper (#11).
2. The `cur.Previous().Address()` crossing-entrypoint identity discipline, as
   written in `r/docs/registry` (#1) and already shipped across four Cosmic Bull
   realms — replacing this codebase's stack-walking `caller()` helper.
3. `permission_registry`'s audited remediation patterns (#10), reused as
   reasoning rather than re-derived.

**Deliberately not adopted, with reasons recorded above:** `r/docs/registry`'s
`owner:name` key space (#1), `grc20reg`'s object-proof registration (#2),
the `ns*` storage layer (#3), `r/sys/*` (#4, #5), and a dependency edge to
either sibling Cosmic Bull registry (#9, #10).

---

## 4. Search-confidence limits

Stated so a later reviewer can judge the coverage rather than assume it.

- **Keyword search is blind by construction.** The first pearl sweep
  (`registr|servic|discover|resolv|naming|...`) **missed the entire 34-path `ns*`
  name-service suite** — the single most relevant neighbor found — because its
  paths abbreviate "name service" to `ns`. It surfaced only via a GitHub
  `tx-exports` search that returned `nslogic/v*/name.gno`, which then prompted a
  second pearl sweep. Any keyword-based enumeration of this chain should be
  assumed to be missing packages whose names are abbreviated or non-English.
- **GitHub code search does not index `.gno` reliably.** `RegisterService
  extension:gno` returned **0** results even though this application's own
  public repo contains that exact symbol. Negative code-search results are
  therefore weak evidence and are not relied on above.
- **Outline-level reads.** `ns*`, `agent_registry_v2`, and `grc20reg` were read
  at outline/symbol level (signatures and doc comments), not as whole files.
  Doc comments are author claims, not verified behavior. `r/docs/registry` and
  `name_service` were read in full.
- **One chain, one commit.** Enumeration covers pearl-1 at height 604980 only;
  mainnet and sapphire were not enumerated. The examples tree is pinned at
  `c4c72fd`. Both move.
- **No exhaustive off-chain sweep.** Private repositories, non-GitHub forges,
  and unpublished work were not and cannot be searched.

---

## 5. Novelty statement

A global, ownership-enforced `name → gno package path` directory — where the
resolved value is a *package path an integrator calls*, registration is
permissionless with per-name uniqueness, ownership is transferable, and a
deregistered name is time-reserved against its former owner and its original
registrant — **was not found as an existing implementation in the searched
sources.**

That statement is deliberately narrow. It is **not** a claim of ecosystem-wide
uniqueness, and it is **not** a claim that nobody has built a registry on
gno.land. The searched sources contain at least eleven registries, directories,
and name services, three of which are live on pearl-1 and one of which (the
`ns*` suite) is considerably more elaborate than this application. What none of
them does is resolve a shared global name to a gno package path. Where an
existing implementation was close, the reason it was not reused is recorded in
§3 rather than asserted.

Per the standing discovery gate, for the specific capability above:
**No relevant existing implementation was found in the searched sources.**
