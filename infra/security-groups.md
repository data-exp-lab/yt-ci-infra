# Security groups

Two groups, created by `create.sh`. Default egress (all outbound) is left in place on both:
the worker needs outbound HTTPS to poll GitHub and fetch packages; the controller needs it for
the GitHub and OpenStack APIs.

## `yt-controller-sg` (controller, has the floating IP)

| direction | proto | port | from | why |
|-----------|-------|------|------|-----|
| ingress | tcp | 22 | `ADMIN_CIDR` | admin SSH; also the ProxyJump host to reach the worker |
| ingress | tcp | 8080 | `yt-worker-sg` | `GET /runner-config`, the JIT runner handoff, private network only |

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
