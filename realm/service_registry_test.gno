package service_registry

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	owner    = testutils.TestAddress("owner")
	attacker = testutils.TestAddress("attacker")
	newOwner = testutils.TestAddress("newowner")
)

const goodPath = "gno.land/r/demo/oracle"

// resetState resets all package-level state between tests.
func resetState() {
	services = make(map[string]*Service)
	names = []string{}
	retired = make(map[string]*Reservation)
}

func register(name string) {
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross, name, goodPath, "a price oracle", "oracle", "")
}

// ---------- RegisterService ----------

func TestRegister_Basic(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	svc := services["price_oracle"]
	uassert.Equal(t, string(owner), string(svc.Owner))
	uassert.Equal(t, goodPath, svc.PkgPath)
	uassert.Equal(t, "oracle", svc.ServiceType)
}

func TestRegister_DuplicateRejected(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"service already registered: price_oracle",
		func() { RegisterService(cross, "price_oracle", goodPath, "mine now", "oracle", "") },
	)
}

func TestRegister_NameValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	for _, bad := range []string{"", "Upper", "has space", "semi;colon", strings.Repeat("a", MaxNameLen+1)} {
		uassert.AbortsContains(t,
			"name must be",
			func() { RegisterService(cross, bad, goodPath, "d", "oracle", "") },
		)
	}
}

func TestRegister_PkgPathValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, "pkgpath must not be empty",
		func() { RegisterService(cross, "svc", "", "d", "oracle", "") })
	uassert.AbortsContains(t, "pkgpath must start with",
		func() { RegisterService(cross, "svc", "example.com/r/x", "d", "oracle", "") })
	uassert.AbortsContains(t, "pkgpath must be gno.land/r/",
		func() { RegisterService(cross, "svc", "gno.land/", "d", "oracle", "") })
	uassert.AbortsContains(t, "invalid pkgpath element",
		func() { RegisterService(cross, "svc", "gno.land/r/x|y", "d", "oracle", "") })
	uassert.AbortsContains(t, "pkgpath exceeds",
		func() {
			RegisterService(cross, "svc", "gno.land/r/"+strings.Repeat("a", MaxPkgPathLen), "d", "oracle", "")
		})
}

func TestRegister_FieldValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	uassert.AbortsWithMessage(t, "description must not be empty",
		func() { RegisterService(cross, "svc", goodPath, "", "oracle", "") })
	uassert.AbortsContains(t, "description exceeds",
		func() {
			RegisterService(cross, "svc", goodPath, strings.Repeat("d", MaxDescriptionLen+1), "oracle", "")
		})
	uassert.AbortsWithMessage(t, "service type must not be empty",
		func() { RegisterService(cross, "svc", goodPath, "d", "", "") })
	uassert.AbortsContains(t, "service type must be",
		func() { RegisterService(cross, "svc", goodPath, "d", "Bad|Type", "") })
	uassert.AbortsContains(t, "metadata exceeds",
		func() { RegisterService(cross, "svc", goodPath, "d", "oracle", strings.Repeat("m", MaxMetadataLen+1)) })
}

// ---------- Deregister + squat protection ----------

func TestDeregister_NameStaysReservedForOwner(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	testing.SetRealm(testing.NewUserRealm(owner))
	Deregister(cross, "price_oracle")
	uassert.PanicsWithMessage(t,
		"service not found: price_oracle",
		func() { Resolve("price_oracle") },
	)

	// the squat the audit found: attacker re-registers the freed name
	// and inherits every integrator still resolving it — must be blocked
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"name is reserved for its former owner: price_oracle",
		func() { RegisterService(cross, "price_oracle", "gno.land/r/evil/oracle", "trust me", "oracle", "") },
	)

	// the former owner can re-register it
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross, "price_oracle", goodPath, "back again", "oracle", "")
	uassert.Equal(t, goodPath, Resolve("price_oracle"))
}

func TestDeregister_OwnerOnly(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"only the owner can deregister",
		func() { Deregister(cross, "price_oracle") },
	)
}

// ---------- UpdateService / TransferOwnership ----------

func TestUpdate_OwnerOnly(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"only the owner can update this service",
		func() { UpdateService(cross, "price_oracle", "gno.land/r/evil/oracle", "hijacked", "oracle", "") },
	)

	testing.SetRealm(testing.NewUserRealm(owner))
	UpdateService(cross, "price_oracle", "gno.land/r/demo/oracle_v2", "v2", "oracle", "k=v")
	uassert.Equal(t, "gno.land/r/demo/oracle_v2", Resolve("price_oracle"))
}

func TestTransferOwnership(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"only the owner can transfer ownership",
		func() { TransferOwnership(cross, "price_oracle", attacker) },
	)

	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t,
		"invalid new owner address: junk",
		func() { TransferOwnership(cross, "price_oracle", address("junk")) },
	)
	TransferOwnership(cross, "price_oracle", newOwner)
	uassert.Equal(t, string(newOwner), string(GetOwner("price_oracle")))

	// the new owner controls the entry now
	testing.SetRealm(testing.NewUserRealm(newOwner))
	UpdateService(cross, "price_oracle", goodPath, "under new management", "oracle", "")
}

// ---------- queries ----------

func TestResolve_UnknownPanics(cur realm, t *testing.T) {
	resetState()

	uassert.PanicsWithMessage(t,
		"service not found: ghost",
		func() { Resolve("ghost") },
	)
}

func TestListServices_And_ByType(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross, "alpha", goodPath, "d", "oracle", "")
	RegisterService(cross, "beta", goodPath, "d", "dex", "")
	RegisterService(cross, "gamma", goodPath, "d", "oracle", "")

	uassert.Equal(t, "alpha, beta, gamma", ListServices())
	uassert.Equal(t, "alpha, gamma", ListByType("oracle"))
	uassert.Equal(t, "none", ListByType("bridge"))
}

func TestGetService_Summary(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	out := GetService("price_oracle")
	uassert.True(t, strings.Contains(out, "PkgPath: "+goodPath), "summary must include pkgpath")
	uassert.True(t, strings.Contains(out, string(owner)), "summary must include owner")
}

// ---------- render ----------

func TestRender_EmptyState(cur realm, t *testing.T) {
	resetState()
	uassert.Equal(t, "# Service Registry\n\nNo services registered.\n", Render(""))
}

func TestRender_SanitizesInjection(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross, "sneaky", goodPath,
		"desc` | fake | row\ninjected", "oracle", "")

	out := Render("")
	uassert.False(t, strings.Contains(out, "desc`"), "backticks must be sanitized")
	uassert.False(t, strings.Contains(out, "| fake |"), "pipes must be sanitized")
	uassert.False(t, strings.Contains(out, "\ninjected"), "newlines must be sanitized")
}

func TestRender_ListsEntries(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	out := Render("")
	uassert.True(t, strings.Contains(out, "price_oracle"), "render must list the service")
	uassert.True(t, strings.Contains(out, goodPath), "render must show the pkgpath")
}

// ---------- re-audit regressions (2026-09-02) ----------

// skipSeconds advances chain time (5s per height).
func skipSeconds(sec int64) {
	testing.SkipHeights((sec + 4) / 5)
}

func TestReservation_ExpiresAndFreesTheName(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")
	testing.SetRealm(testing.NewUserRealm(owner))
	Deregister(cross, "price_oracle")

	// re-audit P1: eternal tombstones let an attacker lock the namespace
	// forever; within the window the name stays reserved...
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.AbortsWithMessage(t,
		"name is reserved for its former owner: price_oracle",
		func() { RegisterService(cross, "price_oracle", "gno.land/r/evil/oracle", "d", "oracle", "") },
	)

	// ...but after ReservationPeriod it frees for anyone
	skipSeconds(ReservationPeriod + 10)
	RegisterService(cross, "price_oracle", "gno.land/r/other/oracle", "d", "oracle", "")
	uassert.Equal(t, "gno.land/r/other/oracle", Resolve("price_oracle"))
}

func TestReservation_OriginalRegistrantCanReclaim(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	// re-audit P2: hostile transferee deregisters — the ORIGINAL
	// registrant can still reclaim during the reservation window
	testing.SetRealm(testing.NewUserRealm(owner))
	TransferOwnership(cross, "price_oracle", attacker)
	testing.SetRealm(testing.NewUserRealm(attacker))
	Deregister(cross, "price_oracle")

	testing.SetRealm(testing.NewUserRealm(owner))
	RegisterService(cross, "price_oracle", goodPath, "reclaimed", "oracle", "")
	uassert.Equal(t, string(owner), string(services["price_oracle"].Owner))
}

func TestPkgPath_StructuralValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(owner))

	// re-audit P3: traversal, doubled slashes, trailing slash, hyphens,
	// and non-r/p roots must all be refused
	bad := []string{
		"gno.land/r/../../etc/passwd",
		"gno.land//r//demo//oracle",
		"gno.land/r/demo/oracle/",
		"gno.land/r/de-mo/oracle",
		"gno.land/x/demo/oracle",
		"gno.land/.",
	}
	for _, p := range bad {
		uassert.AbortsContains(t, "pkgpath",
			func() { RegisterService(cross, "svc", p, "d", "oracle", "") })
	}
	// legitimate r/ and p/ paths still pass
	RegisterService(cross, "svc_r", "gno.land/r/demo/oracle_v2", "d", "oracle", "")
	RegisterService(cross, "svc_p", "gno.land/p/nt/avl", "d", "oracle", "")
}

func TestTryResolve(cur realm, t *testing.T) {
	resetState()
	register("price_oracle")

	got, ok := TryResolve("price_oracle")
	uassert.True(t, ok, "known name must resolve")
	uassert.Equal(t, goodPath, got)

	_, ok = TryResolve("ghost")
	uassert.False(t, ok, "unknown name must return ok=false, never panic")
}
