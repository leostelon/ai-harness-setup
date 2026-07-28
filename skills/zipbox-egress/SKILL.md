---
name: zipbox-egress
description: Understand how this sandbox reaches third-party APIs — the metered secret-injection proxy (tollbooth) vs the transparent first-party MITM — which mode this box is in, how to route through the proxy, and where injected secrets land.
allowed-tools: bash read
---

# Egress: proxy vs MITM

**A sandbox is MITM iff its harness is `ata` OR its `egressMode` is `mitm`;
`egressMode` is the source of truth, and `ata` is a host-side override.**
Everything else this skill says hangs off that one sentence. There are exactly
two egress paths, a box is on exactly one of them, and you rarely pick — the
platform decides from the harness and the tag.

This is also the LLM billing path. Provider-funded model traffic
calls) is a separate system; see the last section. This skill is about how your
**outbound HTTP to third-party data/API providers** is keyed and metered.

## Which mode am I in?

| Harness / tag              | `egressMode` | Egress path      | Metered |
| -------------------------- | ------------ | ---------------- | ------- |
| harness `ata` (trading)    | (overridden) | **MITM**         | yes (see billing model below) |
| tag `tribes.xyz`           | `mitm`       | **MITM**         | yes (see billing model below) |
| everything else (default)  | `proxy`      | **PROXY** (tollbooth) | yes (per-request wallet charge) |

Neither path is free. They meter **differently** — see "Billing model" below.

The mode is derived from the sandbox tag by `egressModeForTag()`
(`packages/sandboxing/src/shared/utils/EgressCatalog.ts:236`) and written into
every desired-VM frame as `sandboxes.egressMode`
(`packages/sandboxing/src/stores/SandboxFleetStore.ts:2632`) — that column is
the source of truth. The host then **hard-overrides to MITM** for
`TRIBES_HARNESS=ata`, regardless of the column
(`apps/sandboxd/src/utils/EgressProxyConfig.ts:43-66`). The whole mechanism is
gated by `HOST_EGRESS_PROXY`; if the host does not run the proxy at all
(`apps/sandboxd/src/common/env.ts:123`), there is no injection and calls go out
raw.

Quick check from inside the box:

```bash
# PROXY mode sets this; MITM mode does NOT.
echo "${ZIPBOX_EGRESS_PROXY_URL:-<unset — likely MITM or no egress proxy>}"
```

## PROXY mode (the tollbooth) — untrusted, metered

In PROXY mode the platform injects `ZIPBOX_EGRESS_PROXY_URL` (typically
`http://172.16.0.1:15808`) into the VM and drops
`/etc/profile.d/zipbox-egress-proxy.sh`
(`apps/microvmd/src/common/vmBridgeEnv.ts:142-155`). You **opt in** by pointing
your HTTP client's proxy at it — nothing is transparently intercepted:

```bash
export HTTPS_PROXY="$ZIPBOX_EGRESS_PROXY_URL"
export HTTP_PROXY="$ZIPBOX_EGRESS_PROXY_URL"
# then call the provider with a PLACEHOLDER where the key goes (see slot table).
curl https://api.example.com/v3/data
```

What happens on the way out:

1. A host-local forwarder (a systemd sibling of `sandboxd`, port `15808` —
   `apps/sandboxd/src/utils/EgressProxyConfig.ts:31`) accepts the connection and
   authenticates the guest **by source IP** — you present no credential.
2. It mints a short-lived host-signed P-256 tollbooth token and forwards the
   request to `apps/api` `/tollbooth/<provider>`.
3. `apps/api` looks up the provider in the shared egress catalog, **injects the
   real API key** into the request, meters the call, and proxies it upstream.

Because it is billed and source-IP-authed, do not try to reach providers that
are not in the catalog through the tollbooth, and do not ship your own keys —
you send a placeholder and the tollbooth swaps in the real one.

## Where the secret lands — the injection slot table

Every catalogued provider declares exactly one slot where its placeholder must
appear. `apps/api` replaces that placeholder with the real key
(`apps/api/src/utils/EgressInjection.ts`, dispatched from
`apps/api/src/services/EgressTollboothService.ts:230-243`).

| Slot (`match.kind`) | Where you put the placeholder            | Injector           |
| ------------------- | ---------------------------------------- | ------------------ |
| `path`              | in the URL path segment                  | `injectPathSecret` |
| `query`             | in a query-string value                  | `injectQuerySecret`|
| `header`            | in the named request header (e.g. `Authorization`, `x-api-key`) | `injectHeaderSecret` |

**Exactly-once rule.** The placeholder must appear **exactly once** in its slot.
For `path` and `query` the tollbooth rejects the request unless the count is
precisely 1; for `header` a duplicate placeholder is rejected (0 is tolerated as
a raw-key fallback). This is the exfil guard — a guest that echoes the
placeholder into two places, or into a slot it doesn't own, gets refused rather
than leaking an injected key
(`apps/api/src/services/EgressTollboothService.ts:177-202`). The exact
per-provider placeholder strings and slots live in the catalog
(`packages/sandboxing/src/shared/utils/EgressCatalog.ts`); read it for the
provider you're calling.

## MITM mode (iron-proxy) — first-party, transparent

MITM is for first-party harnesses (trading `ata`, `tribes.xyz`). There is **no
`ZIPBOX_EGRESS_PROXY_URL` and no `HTTPS_PROXY` to set** — interception is
transparent:

- The daemon seeds the guest `/etc/hosts` so active-provider hostnames resolve
  to the host bridge, and host `iptables` redirects `:443`/`:80` to the
  in-host iron-proxy (`apps/sandboxd/src/helpers/EgressProxyHost.ts`,
  `apps/sandboxd/src/services/FirecrackerBackend.ts:1988-2043`).
- A per-host CA (`tribes-egress-proxy.crt`) is baked into the guest trust store
  so TLS to those hosts validates; `ensureEgressCa` re-heals it on restored
  disks (`apps/sandboxd/src/helpers/EgressCaHeal.ts:93`).
- It uses the **same provider catalog and the same slot rules** as the
  tollbooth, but injection is additive: iron-proxy injects the **real
  first-party key** locally and forwards **direct upstream** to the provider
  (`apps/sandboxd/src/utils/EgressProxyConfig.ts:92-97`) — it does **not** relay
  through `apps/api`'s per-request tollbooth charge.

So in MITM you just call the provider normally over HTTPS with the placeholder
in its slot — the transparent proxy keys it. Nothing to configure in the guest.
MITM is **not free** — see "Billing model".

## Billing model — both modes are metered, differently

Do not treat MITM as free egress.

- **PROXY (tollbooth) — per-request wallet charge.** Before forwarding,
  `apps/api` reserves a debit on the user's wallet
  (`reserveEgressCharge`, `apps/api/src/controllers/EgressTollboothController.ts:62-71`),
  with the amount from the per-endpoint cost table
  (`resolveEndpointCostUsd`, `apps/api/src/services/EgressTollboothService.ts:212`).
  A non-positive balance gates the call (out-of-credits).
- **MITM — metered, but not via that per-request wallet debit.** The tollbooth
  wallet path explicitly marks `tribes.xyz` egress "zero-rated for now"
  (`apps/api/src/controllers/EgressTollboothController.ts:58`,
  `packages/sandboxing/src/shared/utils/EgressCatalog.ts:233-234`), so no
  per-call debit is applied on the MITM path. That is **not the same as free**:
  iron-proxy forwards using the platform's **real first-party provider keys**
  (real upstream spend the platform bears) and measures traffic on its metrics
  endpoint (`127.0.0.1:19090`, `apps/sandboxd/src/utils/EgressProxyConfig.ts:110`).
  Metered (mechanism: real first-party key spend + iron-proxy metrics; the
  per-call wallet charge is deliberately off on this path — the code comment's
  "for now" signals it is a policy toggle, not free egress).

## Not this: the LLM proxy

The same MITM/HTTP-proxy path meters the agent's **own** model calls and egress
key injection. "The trading harness needs no LLM-proxy indirection" means its
data-provider egress goes through the transparent MITM path, not the
per-request tollbooth — it does **not** mean egress is free (see "Billing
model") and it does **not** mean it skips model metering.

## Related skill

- `zipbox-x.com` (`zipbox-x.com/SKILL.md`) — a worked example of this contract:
  it sends the catalog placeholder in the `Authorization` header slot and is
  billed per resource returned, with the per-endpoint rates written out.

## Related hardening

Tollbooth billing check-then-act (overspend) and the header-slot placeholder
guard are tracked separately — see issues #1868 and #1876. Do not duplicate that
logic here; this skill only documents current behavior.
