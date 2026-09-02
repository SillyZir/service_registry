package service_registry

import (
	"chain/runtime"
	"strconv"
	"strings"
	"time"
)

// Service represents a registered on-chain service.
type Service struct {
	Name        string
	Owner       address
	Registrant  address // ORIGINAL registrant; immutable through transfers
	PkgPath     string  // the realm the service lives at — what integrators resolve
	Description string
	ServiceType string // e.g. "token", "dex", "oracle", "dao", "nft", "bridge"
	Metadata    string // freeform key=value pairs or JSON blob
}

// Reservation holds a deregistered name for its former owner AND its
// original registrant, and EXPIRES (re-audit 2026-09-02): an eternal
// reservation let an attacker cycle register/deregister to lock the
// whole namespace forever, and a hostile transferee could strand a
// name against its original registrant permanently.
type Reservation struct {
	Owner      address
	Registrant address
	Expires    time.Time
}

const (
	MaxServices       = 500
	MaxNameLen        = 64
	MaxTypeLen        = 32
	MaxPkgPathLen     = 128
	MaxDescriptionLen = 500
	MaxMetadataLen    = 2000

	pkgPathPrefix = "gno.land/"

	// ReservationPeriod is how long a deregistered name stays reserved.
	// Long enough for integrators to notice the deregistration; finite
	// so tombstones cannot lock the namespace forever.
	ReservationPeriod = int64(90 * 24 * 3600) // 90 days
)

var (
	services map[string]*Service
	names    []string // insertion-ordered list for deterministic iteration
	// retired maps a deregistered name to its time-bounded reservation.
	retired map[string]*Reservation
)

func init() {
	services = make(map[string]*Service)
	names = []string{}
	retired = make(map[string]*Reservation)
}

func caller() address {
	return runtime.PreviousRealm().Address()
}

// ---------- validation helpers ----------

func isValidName(name string) bool {
	if name == "" || len(name) > MaxNameLen {
		return false
	}
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
			return false
		}
	}
	return true
}

func validatePkgPath(pkgPath string) {
	if pkgPath == "" {
		panic("pkgpath must not be empty")
	}
	if len(pkgPath) > MaxPkgPathLen {
		panic("pkgpath exceeds " + strconv.Itoa(MaxPkgPathLen) + " chars")
	}
	if !strings.HasPrefix(pkgPath, pkgPathPrefix) {
		panic("pkgpath must start with " + pkgPathPrefix + " and name a package")
	}
	// structural, per-element validation (re-audit: the old charset check
	// accepted "..", "//", trailing slashes, hyphens, and non-r/p roots —
	// all lookalike-squat or allowlist-bypass material)
	elems := strings.Split(pkgPath[len(pkgPathPrefix):], "/")
	if len(elems) < 2 || (elems[0] != "r" && elems[0] != "p") {
		panic("pkgpath must be gno.land/r/... or gno.land/p/...")
	}
	for _, e := range elems[1:] {
		if e == "" {
			panic("pkgpath contains an empty element")
		}
		if !(e[0] >= 'a' && e[0] <= 'z') {
			panic("invalid pkgpath element: " + e)
		}
		for _, c := range e {
			if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
				panic("invalid pkgpath element: " + e)
			}
		}
	}
}

func validateFields(description, serviceType, metadata string) {
	if description == "" {
		panic("description must not be empty")
	}
	if len(description) > MaxDescriptionLen {
		panic("description exceeds " + strconv.Itoa(MaxDescriptionLen) + " chars")
	}
	if serviceType == "" {
		panic("service type must not be empty")
	}
	if len(serviceType) > MaxTypeLen || !isValidName(serviceType) {
		panic("service type must be lowercase alphanumeric with underscores, max " +
			strconv.Itoa(MaxTypeLen) + " chars")
	}
	if len(metadata) > MaxMetadataLen {
		panic("metadata exceeds " + strconv.Itoa(MaxMetadataLen) + " chars")
	}
}

// sanitize makes attacker-controlled text safe to embed in markdown
// tables and single-line summaries.
func sanitize(s string) string {
	s = strings.ReplaceAll(s, "`", "'")
	s = strings.ReplaceAll(s, "|", "/")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	return s
}

// truncate shortens s to at most n runes without splitting a multibyte
// character.
func truncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n-3]) + "..."
}

func mustGet(name string) *Service {
	svc, ok := services[name]
	if !ok {
		panic("service not found: " + name)
	}
	return svc
}

// ---------- write operations ----------

// RegisterService adds a new service to the registry. The caller becomes
// the owner. Name must be unique, lowercase alphanumeric/underscores.
// pkgPath is the realm the service lives at — the field integrators
// resolve — and must look like a gno.land package path. A name that was
// deregistered stays reserved for its former owner.
func RegisterService(_ realm, name, pkgPath, description, serviceType, metadata string) {
	if !isValidName(name) {
		panic("name must be 1-" + strconv.Itoa(MaxNameLen) +
			" chars, lowercase alphanumeric with underscores only")
	}
	validatePkgPath(pkgPath)
	validateFields(description, serviceType, metadata)
	if _, exists := services[name]; exists {
		panic("service already registered: " + name)
	}
	registrant := caller()
	if res, wasRetired := retired[name]; wasRetired {
		c := caller()
		inWindow := !time.Now().After(res.Expires)
		if c != res.Owner && c != res.Registrant && inWindow {
			panic("name is reserved for its former owner: " + name)
		}
		// round-3 audit: an in-window re-register must PRESERVE the
		// original registrant — otherwise a hostile transferee could
		// deregister and instantly re-register, stamping themselves as
		// registrant and erasing the original project's reclaim right
		if inWindow && res.Registrant != "" {
			registrant = res.Registrant
		}
	}
	if len(services) >= MaxServices {
		panic("global service limit reached")
	}

	services[name] = &Service{
		Name:        name,
		Owner:       caller(),
		Registrant:  registrant,
		PkgPath:     pkgPath,
		Description: description,
		ServiceType: serviceType,
		Metadata:    metadata,
	}
	names = append(names, name)
	delete(retired, name)
}

// UpdateService modifies a service's pkgpath, description, type, and
// metadata. Only the registered owner can update. Name cannot change.
func UpdateService(_ realm, name, pkgPath, description, serviceType, metadata string) {
	svc := mustGet(name)
	if caller() != svc.Owner {
		panic("only the owner can update this service")
	}
	validatePkgPath(pkgPath)
	validateFields(description, serviceType, metadata)

	svc.PkgPath = pkgPath
	svc.Description = description
	svc.ServiceType = serviceType
	svc.Metadata = metadata
}

// TransferOwnership hands control of a service entry to a new address.
func TransferOwnership(_ realm, name string, newOwner address) {
	svc := mustGet(name)
	if caller() != svc.Owner {
		panic("only the owner can transfer ownership")
	}
	if newOwner == "" || !newOwner.IsValid() {
		panic("invalid new owner address: " + string(newOwner))
	}
	svc.Owner = newOwner
}

// Deregister removes a service from the registry. Only the owner can
// deregister. The name stays reserved for the owner — it cannot be
// re-registered by anyone else, so integrators who still resolve it
// can never be redirected by a squatter.
func Deregister(_ realm, name string) {
	svc := mustGet(name)
	if caller() != svc.Owner {
		panic("only the owner can deregister")
	}
	retired[name] = &Reservation{
		Owner:      svc.Owner,
		Registrant: svc.Registrant,
		Expires:    time.Now().Add(time.Duration(ReservationPeriod) * time.Second),
	}
	delete(services, name)

	// Remove from ordered list
	for i, n := range names {
		if n == name {
			names = append(names[:i], names[i+1:]...)
			break
		}
	}
}

// ---------- read-only queries ----------

// Resolve returns the pkgpath a service name points to — the primary
// integration query. Panics on unknown names so a consumer can never
// silently integrate against a missing entry.
func Resolve(name string) string {
	return mustGet(name).PkgPath
}

// TryResolve is the non-panicking variant for consumers that need to
// degrade gracefully when a name disappears (re-audit: a panicking-only
// read path bricks any consumer realm that calls it inline).
func TryResolve(name string) (string, bool) {
	svc, ok := services[name]
	if !ok {
		return "", false
	}
	return svc.PkgPath, true
}

// GetOwner returns the owner address of a service.
func GetOwner(name string) address {
	return mustGet(name).Owner
}

// GetService returns a formatted summary of a registered service.
func GetService(name string) string {
	svc := mustGet(name)

	var b strings.Builder
	b.WriteString("Name: " + svc.Name + "\n")
	b.WriteString("Owner: " + string(svc.Owner) + "\n")
	b.WriteString("PkgPath: " + svc.PkgPath + "\n")
	b.WriteString("Type: " + svc.ServiceType + "\n")
	b.WriteString("Description: " + sanitize(svc.Description) + "\n")
	if svc.Metadata != "" {
		b.WriteString("Metadata: " + sanitize(svc.Metadata) + "\n")
	}
	return b.String()
}

// ListServices returns all registered service names as a comma-separated
// string in registration order.
func ListServices() string {
	if len(names) == 0 {
		return "none"
	}
	return strings.Join(names, ", ")
}

// ListByType returns all service names matching a given type.
func ListByType(serviceType string) string {
	var result []string
	for _, name := range names {
		svc := services[name]
		if svc != nil && svc.ServiceType == serviceType {
			result = append(result, name)
		}
	}
	if len(result) == 0 {
		return "none"
	}
	return strings.Join(result, ", ")
}

// ---------- render ----------

// Render returns a markdown overview. Never panics.
func Render(path string) string {
	if services == nil || len(services) == 0 {
		return "# Service Registry\n\nNo services registered.\n"
	}

	var b strings.Builder
	b.WriteString("# Service Registry\n\n")
	b.WriteString("**Total services:** " + strconv.Itoa(len(services)) + "\n\n")

	b.WriteString("| Name | Type | PkgPath | Owner | Description |\n")
	b.WriteString("|------|------|---------|-------|-------------|\n")

	for _, name := range names {
		svc := services[name]
		if svc == nil {
			continue
		}
		desc := truncate(sanitize(svc.Description), 60)
		b.WriteString("| " + svc.Name + " | " + svc.ServiceType + " | `" +
			svc.PkgPath + "` | `" + string(svc.Owner) + "` | " + desc + " |\n")
	}

	b.WriteString("\n")
	return b.String()
}
