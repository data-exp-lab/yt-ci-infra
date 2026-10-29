# Networking

Two things decide what can reach what: whether an instance has a public address at all, and
what its security groups admit. Addresses first, then groups.

## Addresses and floating IPs

**Private address.** Every instance on `yt-net` gets one at creation, something like
`10.0.42.7`. It only works inside the allocation's network; nothing on the internet can route
to it.

**Floating IP.** A public, internet-routable address Jetstream2 owns. You allocate one from the
`public` pool and associate it with an instance; the router then forwards packets between the
public address and the instance's private one. "Floating" means it can be moved between
instances, not that it changes on its own. Once associated it stays put across reboots and
shelve/unshelve.

**Outbound needs nothing.** The router also NATs the whole private network, so any instance can
connect out to the internet with or without a floating IP of its own.

**So the only question is who needs inbound.**

- Controller: yes. You SSH to it. It has the one floating IP in the system.
- Worker: no. The Actions runner polls GitHub over outbound connections; GitHub never connects
  to the runner. The controller is reachable over the private network. Package and dataset
  fetches are outbound.

Leaving the floating IP off the worker makes it unreachable from the internet by construction,
independent of security groups or anything the job code does. Shell access is via the
controller as a jump host (`ProxyJump` in `docs/deploy.md`).

Jetstream2 reclaims floating IPs from instances shelved more than 45 days. The worker is
shelved most of its life, so an address on it would also be a liability. The controller is
never shelved, so its address is effectively fixed.

## Security groups

**What a security group is.** A firewall rule set that OpenStack enforces outside the VM, at
the network layer. Traffic the group rejects never reaches the instance, so a misconfigured
service on the box still can't be reached. An instance can carry several groups; the union of
their rules applies.

**Direction.** Each rule is ingress (inbound to the VM) or egress (outbound from it).
Jetstream2's default is all egress allowed, no ingress allowed. That is exactly what the worker
needs, since it only ever connects out, so its group has no rules.

**Source.** An ingress rule names a port and a source. The source is either an IP range (CIDR,
e.g. `1.2.3.4/32` for one address) or another security group. A group as source means "any
instance carrying that group", which survives rebuilds and IP changes. The 8080 rule uses this.

**Why ours looks like this.** The controller has the only public address and two ingress
rules: 22 from your IP, 8080 from the worker group. The worker has no public address and no
ingress rules. The runner-config endpoint on 8080 has no authentication; the security group is
what makes that acceptable.

**The `default` group.** Every project has one and Horizon pre-selects it at launch. Its rules
are shared by every instance in the project, so leave them alone (Jetstream2's own advice) and
don't attach it to ours. Attaching only the groups written here keeps the exposure exactly what
this file says.

## The groups

Two groups, created by `create.sh` or by hand in Horizon (Network → Security Groups). Default egress (all outbound) is left in place on both:
the worker needs outbound HTTPS to poll GitHub and fetch packages; the controller needs it for
the GitHub and OpenStack APIs.

## `yt-controller-sg` (controller, has the floating IP)

| direction | proto | port | from | why |
|-----------|-------|------|------|-----|
| ingress | tcp | 22 | `ADMIN_CIDR` | admin SSH; also the ProxyJump host to reach the worker |
| ingress | tcp | 8080 | `yt-worker-sg` | `GET /runner-config`, the JIT runner handoff, private network only |

Horizon "Add Rule" dialog, field by field:

| field | SSH rule | token-port rule |
|-------|----------|-----------------|
| Rule | SSH | Custom TCP Rule |
| Direction | Ingress | Ingress |
| Open Port / Port | (fixed, 22) | Port, `8080` |
| Remote | CIDR | Security Group |
| CIDR / Security Group | `<your ip>/32` | `yt-worker-sg` |

If a GitHub webhook is ever added: ingress tcp 443 from GitHub's published hook ranges
(`gh api meta --jq .hooks`), and Caddy in front of the controller for TLS. Not in v1.

## `yt-worker-sg` (worker, no floating IP)

No ingress rules. The worker only ever makes outbound connections: to the controller on 8080,
to GitHub over 443, to package indexes. SSH reaches it only via `ProxyJump` through the
controller, which works because both sit on `yt-net`. Add an ingress 22 rule from
`yt-controller-sg` if you want that:

```
openstack security group rule create yt-worker-sg --proto tcp --dst-port 22 --remote-group yt-controller-sg
```

## Why the 8080 rule is remote-group and not remote-ip

The runner-config endpoint has no authentication; anyone who can reach it can mint a runner
registration for the repo. Scoping it to the worker's security group (rather than an IP that
could be reassigned) is what makes that acceptable. Do not open it to `0.0.0.0/0`.
