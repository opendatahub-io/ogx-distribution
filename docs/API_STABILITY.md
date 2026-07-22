---
title: RHOAI API Stability (Downstream)
description: How upstream OGX API stability applies to Red Hat OpenShift AI releases
---

# RHOAI API Stability — Downstream

This document is the RHOAI counterpart to upstream OGX's
[API Stability Leveling](docs/docs/concepts/apis/api_leveling.mdx). It only
covers what is *different* downstream. Anything not mentioned here follows
upstream verbatim.

## RHOAI cadence

Each RHOAI minor ships on a fixed train:

- **EA1** (e.g. `3.5-EA1`) — first Early Access drop, bulk of feature work.
- **EA2** (e.g. `3.5-EA2`) — second Early Access drop, stabilization.
- **GA** (e.g. `3.5.0`, `3.5.1`, …) — supported release; z-stream patches follow.

EA releases are unsupported (no CVE backports, no SLA). GA is when Red Hat
support applies.

## Z / Y / X are RHOAI versions

Upstream defines z/y/x against OGX SemVer. Downstream, the same terms apply to
the **RHOAI** version on the cluster:

- z-stream: `3.5.0 → 3.5.1`
- y-stream: `3.5 → 3.6`
- x-stream: `2.x → 3.0`

A single RHOAI y-stream may pull in multiple upstream y-streams. The contract
customers see is anchored to the RHOAI version, not the vendored OGX version.

## Policy delta vs upstream

1. **`/v1` is stable — including across EA drops.** EA is a support
   phase, not a contract phase. "No support" does not mean "no contract." A
   `/v1` route that exists in `3.5-EA1` exists with the same surface in
   `3.5-EA2`, `3.5.0`, `3.6`, and beyond. Same for `ogx_api.provider`. The
   normal way to break `/v1` is a RHOAI x-stream, and the upstream deprecation
   timeline still applies.

   **Upstream-forced escape hatch.** We vendor OGX and are to some extent at the
   mercy of upstream. If upstream lands a breaking change to a `/v1` route, we
   would otherwise have to carry a cherry-pick indefinitely to preserve the
   downstream contract. To avoid that, a `/v1` route (or `ogx_api.provider`
   surface) *may* be dropped in a RHOAI y-stream **only if** it was clearly
   marked deprecated in the previous y-stream and the deprecation was called out
   in that release's RHOAI release notes. This is an exception for
   upstream-driven breakage, not license to break `/v1` downstream at will; the
   deprecation window in §4 still governs the minimum lifetime.

2. **`/v1alpha` and `/v1beta` may churn freely between EA drops.** Upstream
   allows breakage on these surfaces with proper labeling; downstream EA is
   where most of that churn lands. By GA, the surfaces shipped in that RHOAI
   minor must be settled and stay settled across the minor's z-streams (per
   upstream's GA rules).

3. **What can change at each release boundary:**

   | Boundary | `/v1alpha` | `/v1beta` | `/v1` | `ogx_api.provider` | Config schema | On-disk storage |
   |---|---|---|---|---|---|---|
   | EA1 → EA2 (same minor) | any change | any change | additive only | additive only | any change | any change |
   | EA2 → GA (same minor) | any change | any change | additive only | additive only | any change, must auto-migrate by GA | any change, must auto-migrate by GA |
   | z-stream (`3.5.0 → 3.5.1`) | any change | additive only | additive only | additive only | frozen | frozen |
   | y-stream (`3.5 → 3.6`) | any change | datatype changes allowed with release-note callout; routes stay mounted | additive only; *upstream-forced* removal allowed if deprecated in prior y-stream (see §1) | additive only; same upstream-forced exception | additive only; renames require deprecate-then-remove | auto-migrating only |
   | x-stream (`2.x → 3.0`) | any change | any change | breaking allowed (deprecation timeline still applies) | breaking allowed *only if* the RHOAI x-stream coincides with an `ogx-api` major bump | breaking allowed with migration guide | breaking allowed with migration tool |

   "Additive only" = new optional fields with safe defaults, new routes, new
   enum members on outputs. No removals, renames, or type narrowing.

4. **Deprecation windows are counted in RHOAI minors.** A `/v1` deprecation
   announced in `3.5` cannot be removed before `3.7`. The one exception is the
   upstream-forced escape hatch in §1: when upstream removes a `/v1` surface and
   carrying a cherry-pick indefinitely is impractical, the route may be dropped
   one minor after it was marked deprecated (deprecate in `3.5`, remove in `3.6`).

5. **Breaking changes to `/v1beta` must be called out in RHOAI release notes
   independently of upstream.** The upstream `BREAKING CHANGE` label is
   necessary but not sufficient.
