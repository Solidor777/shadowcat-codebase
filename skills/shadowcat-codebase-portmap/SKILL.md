---
name: shadowcat-codebase-portmap
description: "Use when touching Shadowcat's automatic router port forwarding: the `portmap` module (NAT-PMP and PCP wire codec, UPnP IGD discovery and SOAP client, the protocol ladder, `PortMapRuntime` and its single enable decision, the status) and the admin route `http::port_forward` (`GET`/`PUT /api/admin/portmap`). Covers src/server/src/portmap/ and src/server/src/http/port_forward.rs. Invoke shadowcat-codebase-core first; for the bootstrap and config layering that start it invoke shadowcat-codebase-server-ops."
---

# Shadowcat — Router Port Forwarding

Orientation for how the server asks a home router to forward its listening port to the internet.

## Purpose

When enabled, the server obtains, renews and deletes one TCP mapping for its listening port, trying
NAT-PMP, then PCP, then UPnP IGD. Admins see the result and flip the toggle through one admin route.
The module parses bytes from unauthenticated LAN peers, so it is written to be unable to panic.

## Key files & seams

- `portmap::codec` — fixed-size NAT-PMP and PCP wire codec (bounds-checked reads only).
- `portmap::client` — the NAT-PMP/PCP UDP exchanges (`natpmp_map`, `pcp_map`, deletes, `RetryPolicy`).
- `portmap::ssdp`, `portmap::soap`, `portmap::igd` — UPnP discovery, the bounded XML/HTTP/SOAP
  plumbing, and `IgdGateway` (`external_address`, mapping add with a lease, `delete_mapping`).
  `soap::is_lan_address` is the LAN test (RFC 1918, link-local, unique-local; loopback and public
  addresses fail).
- `portmap::mapping` — `acquire` (the ladder), renew, `delete`, `Targets` (where protocols talk;
  tests point it at fakes), `Failure` (a machine `reason` key plus a sentence).
- `portmap::runtime` — `PortMapRuntime` (`AppState.portmap`): `activate` after the listener binds,
  `apply` on a toggle, `status`, `shutdown` after the HTTP drain; `effective_enabled`;
  `read_stored_toggle`/`write_stored_toggle` over the stored setting named by `STORED_TOGGLE_KEY`.
- `portmap::status` — `PortMapStatus`, `PortMapState`, `PortMapProtocol`, `is_public_address`.
- `http::port_forward` — the admin route.

## Hard invariants

- **Nothing in the module can panic on network input.** The lint block in `portmap` denies
  `unwrap`, `expect`, `panic!`, slice indexing and unchecked arithmetic outside tests. Adding a
  construct it rejects is a defect, not a lint to silence.
- **At most one mapping is held, and the slot equals what the router holds.** `Shared::slot` is
  written with no await after the router's grant (`mapping::acquire` makes the grant its last
  await), so aborting the task at any await never strands an unrecorded mapping, and `shutdown`
  deletes exactly the recorded one.
- **One enable decision**: `effective_enabled` (the `port_forward` config key when set, else the
  stored toggle) is called by the runtime, the route and the status. A config key locks the toggle
  (`locked_by_config`).
- **UPnP endpoints are trusted only when they are the device that answered discovery and sit on a
  LAN address** (`soap::is_lan_address`; `IgdError::Untrusted` surfaces as `portmap::mapping::Failure::reason` as the machine key untrusted_endpoint). A URL naming another
  host never gets a request.
- **A permanent lease (`lease_secs` 0, used after the router answers with the permanent-lease-only
  error) is still deleted at shutdown.**
- **The status is admin-only**: it carries the router's external address, which no player route
  may expose (`AdminUser` on both route methods).
- **A loopback bind never maps** (`PortMapState::UnreachableBind`); a router external address that
  is not publicly routable reports `MappedNotPublic`, not `Mapped`.

## Gotchas

- Docs-ratchet applies: every item, public or private, needs a doc with an example; rustdoc
  rejects a bare text-fenced example block that is meant to compile, so use the fence forms the
  other modules use.
- `PortMapRuntime::disabled()` is the runtime tests and doc examples build into `AppState`; it never
  starts a task.
- Renewal runs at half the lease with back-off between failed attempts; a status read does not
  talk to the router.

## Pointers

- Generated API: `/api/rust/shadowcat/portmap/`, `/api/rust/shadowcat/http/port_forward/`.
- Config and CLI layering that start the runtime: `shadowcat-codebase-server-ops`.
- Relationships: `graphify query "portmap port forwarding NAT-PMP PCP UPnP runtime"`.
