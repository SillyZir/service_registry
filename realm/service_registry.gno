package service_registry

import (
	"std"
	"strconv"
	"strings"
)

// Service represents a registered on-chain service.
type Service struct {
	Name        string
	Owner       std.Address
	Description string
	ServiceType string // e.g. "token", "dex", "oracle", "dao", "nft", "bridge"
	Metadata    string // freeform key=value pairs or JSON blob
}

var (
	services map[string]*Service
	names    []string // insertion-ordered list for deterministic iteration
)

func init() {
	services = make(map[string]*Service)
	names = []string{}
}

func caller() std.Address {
	return std.PreviousRealm().Address()
}

// ---------- write operations ----------

// RegisterService adds a new service to the registry. The caller becomes
// the owner. Name must be unique, non-empty, and alphanumeric with
// underscores (a simple namespace to prevent collisions).
func RegisterService(_ realm, name, description, serviceType, metadata string) {
	if name == "" {
		panic("name must not be empty")
	}
	if !isValidName(name) {
		panic("name must be lowercase alphanumeric with underscores only")
	}
	if description == "" {
		panic("description must not be empty")
	}
	if serviceType == "" {
		panic("service type must not be empty")
	}
	if _, exists := services[name]; exists {
		panic("service already registered: " + name)
	}

	services[name] = &Service{
		Name:        name,
		Owner:       caller(),
		Description: description,
		ServiceType: serviceType,
		Metadata:    metadata,
	}
	names = append(names, name)
}

// UpdateService modifies a service's description, type, and metadata.
// Only the registered owner can update. Name cannot be changed.
func UpdateService(_ realm, name, description, serviceType, metadata string) {
	svc := mustGet(name)
	if caller() != svc.Owner {
		panic("only the owner can update this service")
	}
	if description == "" {
		panic("description must not be empty")
	}
	if serviceType == "" {
		panic("service type must not be empty")
	}

	svc.Description = description
	svc.ServiceType = serviceType
	svc.Metadata = metadata
}

// TransferOwnership hands control of a service entry to a new address.
func TransferOwnership(_ realm, name string, newOwner std.Address) {
	svc := mustGet(name)
	if caller() != svc.Owner {
		panic("only the owner can transfer ownership")
	}
	if newOwner == "" {
		panic("new owner must not be empty")
	}
	svc.Owner = newOwner
}

// Deregister removes a service from the registry permanently.
// Only the owner can deregister.
func Deregister(_ realm, name string) {
	svc := mustGet(name)
	if caller() != svc.Owner {
		panic("only the owner can deregister")
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

// GetService returns a formatted summary of a registered service.
func GetService(name string) string {
	svc := mustGet(name)

	var b strings.Builder
	b.WriteString("Name: " + svc.Name + "\n")
	b.WriteString("Owner: " + string(svc.Owner) + "\n")
	b.WriteString("Type: " + svc.ServiceType + "\n")
	b.WriteString("Description: " + svc.Description + "\n")
	if svc.Metadata != "" {
		b.WriteString("Metadata: " + svc.Metadata + "\n")
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

	b.WriteString("| Name | Type | Owner | Description |\n")
	b.WriteString("|------|------|-------|-------------|\n")

	for _, name := range names {
		svc := services[name]
		if svc == nil {
			continue
		}
		desc := svc.Description
		if len(desc) > 60 {
			desc = desc[:57] + "..."
		}
		b.WriteString("| " + svc.Name + " | " + svc.ServiceType + " | `" + string(svc.Owner) + "` | " + desc + " |\n")
	}

	b.WriteString("\n")
	return b.String()
}

// ---------- helpers ----------

func mustGet(name string) *Service {
	svc, ok := services[name]
	if !ok {
		panic("service not found: " + name)
	}
	return svc
}

func isValidName(name string) bool {
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
			return false
		}
	}
	return true
}
