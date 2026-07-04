# Secret rotation workflow

How leaked-or-rotation-due secrets in this repo are handled today, and
the planned migration to ExternalSecret + 1Password Connect.

> **See also: `shared-homelab-secrets`.** For "small, low-cardinality
> secrets that would otherwise live inline in git" (app db passwords,
> encryption keys, PATs) the current end-state is a single shared
> Secret fanned out by emberstack/reflector, not one ExternalSecret per
> app. See the **Shared-secrets pattern** section at the bottom of this
> file. The per-Secret ExternalSecret pattern described below still
> applies for secrets with distinct rotation lifecycles or
> distinct-per-consumer scopes (`gateway-api-key-inbox`,
> `cloudflared-tunnel-token`, Google OAuth clients, Dex clients, etc.).

The reference case throughout is **`gateway/gateway-api-key`** — the
shared X-API-Key Secret consumed by the `inbox-apikey` SecurityPolicy
on the `inbox` listener of Gateway `public`. The same pattern applies
to every other Secret whose body has historically lived inline in a
manifest (firefly.`APP_KEY`, plane.`SECRET_KEY`, duitku.`FIREFLY_PAT`,
etc.).

---

## State today (interim)

- ESO + 1Password Connect are installed and the `1password`
  ClusterSecretStore is `Ready=True` against vault `quanianitis.com`
  (see `cluster-secretstore.yaml`).
- Most application Secrets are still declared inline in git as `kind:
  Secret` with `stringData`. **Any value committed to this repo must
  be considered public** — `github.com/ian-cq/homelab` is a public
  repo, history is forever, `git rm` does not unleak anything.
- For Secrets whose inline value has leaked and been rotated, the
  in-cluster Secret is created **out-of-band via `kubectl create`** and
  the git manifest is removed. The live Secret carries
  `argocd.argoproj.io/sync-options: Prune=false` so Argo does not
  delete it when the manifest disappears from source.

This file documents that interim workflow and the path to the
end-state (ExternalSecret-managed everything).

---

## Rotation procedure (manual / interim)

Run from any shell that has both `op` (1Password CLI, signed in to the
account that holds vault `quanianitis.com`) and `kubectl` pointed at
this cluster.

### 1. Mint a new key

```sh
NEW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")')
```

`token_urlsafe(32)` → 256 bits of entropy, ~43 chars,
URL/header-safe. Adjust if the consumer needs a different shape.

### 2. Store the new value in 1Password

Create the item the first time:

```sh
op item create \
  --category=password \
  --vault=quanianitis.com \
  --title='gateway-api-key-inbox' \
  --tags='homelab,k8s,gateway,api-key' \
  "cf-worker[password]=$NEW" \
  notesPlain='Shared X-API-Key for the inbox listener of Gateway public.
Consumed by SecurityPolicy gateway/inbox-apikey via Secret
gateway/gateway-api-key (key: cf-worker). Mirror the value into the
Cloudflare Email Worker with `wrangler secret put GATEWAY_API_KEY`.
Rotation: see infra/kustomize/external-secrets/SECRET_ROTATION.md.'
```

For subsequent rotations, edit the existing item instead of creating a
new one (keeps the item UUID stable for the future ExternalSecret):

```sh
op item edit gateway-api-key-inbox \
  --vault quanianitis.com \
  "cf-worker[password]=$NEW"
```

If you want to keep the previous value as a second client during a
graceful rotation, add a second field instead of overwriting:

```sh
op item edit gateway-api-key-inbox \
  --vault quanianitis.com \
  "cf-worker-next[password]=$NEW"
```

…and tear it down once the consumer has switched over.

### 3. Apply the new value to the cluster

Pipe directly from 1Password to `kubectl` so the value never lands in
a shell variable, history file, or terminal scrollback:

```sh
op read 'op://quanianitis.com/gateway-api-key-inbox/cf-worker' \
  | kubectl create secret generic gateway-api-key \
      -n gateway \
      --from-file=cf-worker=/dev/stdin \
      --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl annotate secret -n gateway gateway-api-key \
  argocd.argoproj.io/sync-options=Prune=false --overwrite

kubectl label secret -n gateway gateway-api-key \
  app.kubernetes.io/name=gateway \
  app.kubernetes.io/component=api-key-auth \
  --overwrite
```

The `Prune=false` annotation is what makes it safe for the matching
inline manifest to be absent from git: Argo CD will not delete a live
resource that carries it, even when the source-of-truth no longer
declares it. Always re-apply this annotation after any rotation; a
plain `kubectl apply` of a fresh manifest will drop annotations not in
the manifest body.

### 4. Update downstream consumers

For `gateway-api-key-inbox` the only consumer today is the
**Cloudflare Email Worker** in the duitku repo's `worker/`
subdirectory. Push the new value to Cloudflare:

```sh
op read 'op://quanianitis.com/gateway-api-key-inbox/cf-worker' \
  | wrangler secret put GATEWAY_API_KEY
wrangler deploy
```

Verify by tailing Envoy Gateway access logs (`kubectl logs -n gateway
deploy/envoy-...`) — the `x-client-id` header on accepted requests
should report `cf-worker` and 401s on the old key should stop within
seconds of the wrangler deploy completing.

### 5. (Optional) Hard-rotate by removing the old key

If the old value is known-leaked (i.e. it ever appeared in git, in a
log, or in a chat), do **not** keep it around as a graceful-rotation
fallback. Skip step 2's "keep old + add new" variant, overwrite the
single field in 1Password, and re-apply in step 3 with the new value
only. Any client still presenting the old key gets a clean 401 from
Envoy at L7 — that is the desired outcome.

---

## What goes into git (interim)

For every Secret that is rotated out-of-band, the git tree should
contain **none of the secret bytes** and **none of the secret
manifest**. Concretely, for `gateway/gateway-api-key`:

- `infra/kustomize/gateway/api-key-secret.yaml` — **deleted**.
- `infra/kustomize/gateway/kustomization.yaml` — `resources:` no longer
  references the file; an inline comment points readers to this doc.
- `infra/kustomize/gateway/securitypolicy-inbox.yaml` — unchanged, its
  `credentialRefs` still names `gateway-api-key`. The SecurityPolicy
  doesn't care whether the Secret it references was applied from git
  or `kubectl create`; it just needs to resolve at admission time.

That's the entire git surface. The Secret exists in-cluster only.

---

## End-state: ExternalSecret + 1Password Connect

When you are ready to drop the manual `kubectl create` step, replace
it with the ExternalSecret below and commit. ESO will pull from
1Password Connect every `refreshInterval` and reconcile the target
Secret with `creationPolicy: Owner`.

**Prerequisite:** the 1Password item must already exist (step 2
above). ESO does not create items; it only reads them.

Drop this file in alongside the SecurityPolicy:

```yaml
# infra/kustomize/gateway/api-key-externalsecret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: gateway-api-key
  namespace: gateway
  labels:
    app.kubernetes.io/name: gateway
    app.kubernetes.io/component: api-key-auth
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: 1password
  target:
    name: gateway-api-key      # name of the Secret ESO will manage
    creationPolicy: Owner
  data:
    - secretKey: cf-worker
      remoteRef:
        key: gateway-api-key-inbox   # 1Password item title
        property: cf-worker          # field label inside the item
```

And add it to `infra/kustomize/gateway/kustomization.yaml`:

```yaml
resources:
  - certificate.yaml
  - gateway.yaml
  - gatewayclass.yaml
  - securitypolicy.yaml
  - securitypolicy-inbox.yaml
  - api-key-externalsecret.yaml   # replaces the inline Secret + manual kubectl create
```

### Cut-over checklist

ESO with `creationPolicy: Owner` will **not** adopt a Secret that
already exists and is not owned by an ExternalSecret. Before pushing
the ExternalSecret manifest:

1. Confirm the 1Password item holds the **same value** currently in
   the cluster Secret. If they differ, the cut-over will rotate the
   key as a side effect.
   ```sh
   diff <(op read 'op://quanianitis.com/gateway-api-key-inbox/cf-worker') \
        <(kubectl get secret -n gateway gateway-api-key \
            -o jsonpath='{.data.cf-worker}' | base64 -d)
   ```
2. Delete the live Secret so ESO can re-create it with itself as
   owner. This causes a brief auth gap on the inbox listener (~seconds
   while ESO reconciles); schedule accordingly.
   ```sh
   kubectl delete secret -n gateway gateway-api-key
   ```
3. Push the commit that adds `api-key-externalsecret.yaml` and lets
   Argo sync. Verify:
   ```sh
   kubectl get externalsecret -n gateway gateway-api-key
   kubectl get secret         -n gateway gateway-api-key \
     -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
   # expect: ExternalSecret
   ```
4. The `Prune=false` annotation is no longer needed once ESO owns the
   Secret (ESO will recreate on delete). Leave it; it's harmless and
   helpful as a belt-and-braces measure.

### Why we don't migrate straight to step 4 today

- Most of the leaked-then-rotated Secrets here (`gateway-api-key`,
  duitku.`FIREFLY_PAT`, firefly.`APP_KEY`, plane.`SECRET_KEY`) do
  **not** yet have 1Password items. Step 2 has to happen for each one
  before the ExternalSecret is meaningful.
- The Argo CD `.status.terminatingReplicas` ComparisonError (see
  `~/claude-agent/AGENTS.md` § "Lessons from prior sessions") currently
  pins several Applications at `Sync=Unknown`. Until that's cleared,
  hand-applied changes via `kubectl apply` are the only reliable way
  to mutate cluster state, and there's no point introducing an
  ExternalSecret whose `target` Secret Argo can't see anyway.

Migrate Secret-by-Secret as each one is rotated. Tracking list:

| Namespace / Secret              | Field(s)       | 1Password item                 | Status |
| ------------------------------- | -------------- | ------------------------------ | ------ |
| `gateway/gateway-api-key`       | `cf-worker`    | `gateway-api-key-inbox`        | LEGACY; kubectl-managed; scheduled for removal once `gateway-homelab-auth` ESO migration completes Phase 4 (see row below) |
| `gateway/gateway-homelab-auth`  | `apikey-gateway` (K8s) ← `apikey-gateway` (1P) | `gateway-homelab-auth` | ESO manifest committed. Phase 2 populated (1P field `apikey-gateway` set out-of-band). Phase 3 will add this Secret to `inbox-apikey.credentialRefs` alongside the legacy Secret, once ES sync is verified. Phase 4 drops the legacy Secret. |
| `duitku/gateway-api-key`        | `cf-worker`    | `gateway-api-key-inbox` (same) | rotated; kubectl-managed; remove once `gateway` ns Secret is the only one referenced |
| `duitku/duitku` → `FIREFLY_PAT` | `FIREFLY_PAT`  | TODO                           | leaked inline (empty default), needs rotation when populated |
| `firefly/...` → `APP_KEY`       | `APP_KEY`      | TODO                           | leaked inline             |
| `plane/...` → `SECRET_KEY`      | `SECRET_KEY`   | TODO                           | leaked inline             |

Update this table as items are migrated.

---

## Hard rules

- **Never** commit a rotated value to git, even temporarily, even in a
  commit you plan to amend or force-push. Public repo history is
  immutable in the threat model that matters.
- **Never** echo a secret value to stdout or write it to a file outside
  the in-cluster Secret. Pipe `op read` → `kubectl` → done.
- **Always** re-apply the `Prune=false` annotation after a
  `kubectl apply` rotation. A vanilla apply drops annotations not in
  the manifest body, which would let Argo prune the Secret on the next
  sync of the parent application.
- If you `kubectl delete` a Secret that is referenced by an Envoy
  Gateway SecurityPolicy `credentialRef`, the listener will reject
  every request until the Secret reappears. Recreate within the same
  shell, do not leave a gap.
- **EG `credentialRefs` fails Invalid → fails OPEN.** Do not list a
  Secret in `SecurityPolicy.spec.apiKeyAuth.credentialRefs` before
  that Secret exists in the cluster. EG marks the whole SP
  `Accepted=False reason=Invalid` on any missing ref, and an Invalid
  SP results in unauthenticated traffic reaching the backend on every
  listener the SP targets — not a 401. The "list both Secrets during
  cut-over" pattern therefore only works after the new Secret has
  materialised (Phase 3, not Phase 1, in the migration in
  `infra/kustomize/gateway/externalsecret-homelab-auth.yaml`).
  Observed experimentally in commit `ba5027a` (subsequently reverted).

---

## Shared-secrets pattern (`shared-homelab-secrets`)

For secrets that are (a) small, (b) low-cardinality, and (c) don't
have their own rotation cadence — the app-DB-password / encryption-key
/ personal-access-token flavour — we fan out a **single** Secret to
**every** namespace instead of writing one ExternalSecret per app.

### Topology

```
1Password item                       ExternalSecret               reflector
"shared-homelab-secrets"     ─→      shared-homelab-secrets  ─→   shared-homelab-secrets
(vault: quanianitis.com)             (ns: external-secrets)       (ns: *  — every namespace)
one item, many fields                one manifest, dataFrom.extract
```

- **1Password item:** exactly one, title `shared-homelab-secrets`,
  vault `quanianitis.com`. Each secret is a **field on the item**.
  Field label → Secret data key verbatim. Prefer kebab-case labels
  (`firefly-db-password`, `n8n-encryption-key`) — they survive env-var
  translation and don't collide across apps.
- **ExternalSecret:** `infra/kustomize/external-secrets/shared-homelab-secrets.yaml`.
  Uses **explicit `data:` blocks** (not `dataFrom.extract`) so only the
  fields listed in the manifest are projected into the reflected
  Secret. This prevents 1Password built-in fields on
  `--category=login` items (`username`, `password`, `notesPlain`) from
  being fanned out to every namespace. Adding a new key therefore
  requires an edit to this manifest — deterministic, and safer than
  auto-projecting arbitrary 1P fields. Refresh interval is 1h; force a
  refresh with
  `kubectl annotate externalsecret -n external-secrets shared-homelab-secrets
  force-sync=$(date +%s) --overwrite`.
- **Reflector:** `infra/kustomize/reflector/` (chart
  `emberstack/reflector` v10.0.55, deployed to ns `reflector` by the
  `reflector` Argo Application). The source Secret carries
  `reflector.v1.k8s.emberstack.com/reflection-{allowed,auto-enabled}=true`
  and empty `-namespaces` (= all namespaces), so a mirror named
  `shared-homelab-secrets` shows up in every namespace, including
  future ones as they are created.

### Consumer contract

Every workload that needs a shared secret does:

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: shared-homelab-secrets
        key: firefly-db-password
```

**Do not** `envFrom: secretRef: name: shared-homelab-secrets` — that
dumps every key in the shared Secret into the container's env, which
leaks unrelated app secrets across process boundaries. Use explicit
per-key `secretKeyRef` blocks.

### Adding a new shared secret

1. Add the field to the 1P item:
   ```sh
   op item edit shared-homelab-secrets \
     --vault quanianitis.com \
     "new-key-label[password]=<value>"
   ```
2. Add a matching `data:` entry to
   `infra/kustomize/external-secrets/shared-homelab-secrets.yaml`:
   ```yaml
   - secretKey: new-key-label
     remoteRef:
       key: shared-homelab-secrets
       property: new-key-label
   ```
   Commit and push. Argo reconciles; the ExternalSecret picks up the
   new field on the next refresh (≤1h — force with the annotate
   command above). The reflected Secret then carries the new key in
   every namespace.
3. Reference the key from the consumer manifest via `secretKeyRef`.

### 1Password item schema (Phase 2 migration target)

The `shared-homelab-secrets` item **must** hold these fields before
the Phase 2 commit is pushed (see checklist below). Values with
`(leaked)` are known-public in this repo's git history and MUST be
rotated when copied into 1Password, not copy-pasted.

| Field label                 | Current source                                    | Notes |
| --------------------------- | ------------------------------------------------- | ----- |
| `n8n-encryption-key`        | `n8n/n8n-app.N8N_ENCRYPTION_KEY` (leaked)         | 48-char hex. **DO NOT rotate** — rotating invalidates every stored credential in the n8n DB. Copy the current value in as-is and rotate only via the n8n CLI export/import flow. |
| `n8n-db-password`           | `n8n/n8n-postgres.POSTGRES_PASSWORD` (leaked)     | Rotate: mint new value, update in 1P, apply, restart postgres + n8n pods (postgres will accept the new password because it's set via `POSTGRES_PASSWORD` env at container start — you need to `ALTER USER` inside the DB too, or wipe the PVC if the app data is disposable). |
| `firefly-app-key`           | `firefly/firefly-app.APP_KEY` (leaked)            | 32-char hex, exactly. Firefly re-encrypts nothing on rotation; changing it invalidates any encrypted-at-rest attachments. Prefer to keep the existing value. |
| `firefly-static-cron-token` | `firefly/firefly-app.STATIC_CRON_TOKEN` (leaked)  | 32-char hex. Safe to rotate; the cron pod picks it up on next schedule. |
| `firefly-db-password`       | `firefly/firefly-postgres.POSTGRES_PASSWORD` (leaked) | Same caveat as `n8n-db-password`. |
| `duitku-firefly-pat`        | `duitku/duitku.FIREFLY_PAT` (empty in git)        | Populate with a real Firefly III Personal Access Token (Firefly UI → Profile → OAuth → Personal Access Tokens). |

Non-secret fields (`POSTGRES_DB`, `POSTGRES_USER`) do **not** go in
1Password. They move to a plain `ConfigMap` alongside the workload as
part of Phase 2.

### Phase 2 migration checklist (blocked on populating 1P item)

Phase 1 (this commit) lands the reflector, the shared ExternalSecret,
and the required namespace — nothing that breaks anything. The
ExternalSecret will report `SecretSyncedError` until the 1P item
exists; that is expected and safe.

Phase 2 is a follow-up commit that:

1. **Prereq (Ian, out-of-band):** create the 1P item with the schema
   above. Verify:
   ```sh
   op item get shared-homelab-secrets --vault quanianitis.com \
     --fields label=n8n-encryption-key,label=n8n-db-password,label=firefly-app-key,label=firefly-static-cron-token,label=firefly-db-password,label=duitku-firefly-pat
   ```
2. **Force-sync the ExternalSecret** and confirm the target Secret
   materialises in `external-secrets`:
   ```sh
   kubectl annotate externalsecret -n external-secrets shared-homelab-secrets \
     force-sync=$(date +%s) --overwrite
   kubectl get secret -n external-secrets shared-homelab-secrets \
     -o jsonpath='{.data}' | jq 'keys'
   ```
3. **Confirm the reflector fan-out**:
   ```sh
   kubectl get secret -A --field-selector metadata.name=shared-homelab-secrets
   # expect: one row per namespace
   ```
4. **Rewire consumers** (single git commit):
   - `infra/charts/n8n/n8n.yaml`: replace
     `envFrom: - secretRef: {name: n8n-app}` with explicit
     `env: - name: N8N_ENCRYPTION_KEY / DB_POSTGRESDB_PASSWORD`
     `valueFrom.secretKeyRef.name: shared-homelab-secrets` +
     matching `key`.
   - `infra/charts/n8n/postgres.yaml`: same, plus move `POSTGRES_DB`
     and `POSTGRES_USER` to a new ConfigMap `n8n-postgres` (env-only,
     no secrets).
   - `infra/charts/firefly/firefly.yaml`, `.../postgres.yaml`,
     `.../cron.yaml`: same pattern (`firefly-app-key`,
     `firefly-static-cron-token`, `firefly-db-password`, ConfigMap for
     `POSTGRES_DB`/`POSTGRES_USER`).
   - `infra/charts/duitku/sweep.yaml`: change the `secretKeyRef.name`
     from `duitku` to `shared-homelab-secrets`, `key` from
     `FIREFLY_PAT` to `duitku-firefly-pat`.
5. **Delete the leaked inline manifests** in the *same* commit
   (Argo will prune the in-cluster Secrets on the next sync; the
   consumers by then already reference `shared-homelab-secrets`):
   - `infra/charts/n8n/secret.yaml`
   - `infra/charts/firefly/secret.yaml`
   - `infra/charts/duitku/secret.yaml`
   - remove them from each `kustomization.yaml`.
6. **Post-migration verification**:
   ```sh
   kubectl rollout status -n n8n deploy/n8n
   kubectl rollout status -n n8n deploy/n8n-postgres
   kubectl rollout status -n firefly deploy/firefly
   kubectl rollout status -n firefly deploy/firefly-postgres
   kubectl get cronjobs -A | grep -E "firefly|duitku"
   ```
7. **After confirmed healthy: rotate the leaked values** by editing
   the fields in 1Password and force-syncing the ExternalSecret. Then
   restart the affected pods so they pick up the new values. (Do not
   rotate `n8n-encryption-key` or `firefly-app-key` — see schema
   notes.)

### What stays out of the shared secret

These have their own lifecycle and remain managed separately:

- `cloudflared/cloudflared-tunnel-token` (per-tunnel, already ESO)
- `plane/plane-*-secrets` (generated by the plane Helm chart at install)
- `argocd/*`, `cilium-system/*`, `envoy-gateway-system/*`,
  `kube-system/*` (system-owned bootstrap secrets)
- `external-secrets/1password` (ESO's own auth to 1P — chicken-and-egg)

---

## Shape-projection sub-pattern (for consumers with hard-coded key names)

Some consumers hard-code the *Secret name* AND the *data key names*
they read from — Envoy Gateway `SecurityPolicy` OIDC (expects literal
`client-id` / `client-secret`), the plane Helm chart (expects literal
`POSTGRES_PASSWORD`), Grafana (expects literal `admin-password`), etc.
Those generic key names collide across multiple OIDC clients / DBs, so
we cannot point the consumer directly at the cluster-wide reflected
`shared-homelab-secrets` Secret.

**The rule is one 1P item per concern, not one per app.** Group
related credentials into the same item; give each item its own thin
ExternalSecret. Today:

| 1P item                    | Vault             | Concern                                           |
| -------------------------- | ----------------- | ------------------------------------------------- |
| `shared-homelab-secrets`   | quanianitis.com   | App-level cross-cutting (DB pwds, encryption keys, PATs). Reflected cluster-wide. |
| `gateway-homelab-auth`     | quanianitis.com   | North-south gateway auth (OIDC clients, HMAC).    |
| `1password-server-token`   | quanianitis.com   | ESO's own auth to 1P Connect (bootstrap, do not touch). |

New concerns get new items — do not overload `shared-homelab-secrets`
with things that have a different rotation cadence or blast radius
from app-DB-password refreshes.

Two projection strategies:

- **Item has exactly the shape the consumer expects** → use explicit
  `data:` blocks that project only the consumer-required keys. Avoid
  `dataFrom.extract`: 1P login-category items carry built-in
  `username`/`password`/`notesPlain` fields that would otherwise leak
  into the projected Secret. See
  `infra/kustomize/dex/externalsecret-envoy-client.yaml` — the
  `gateway-homelab-auth` item holds `client-id` and `client-secret`
  fields plus login-category cruft; only the two named fields are
  projected.

- **Item aggregates multiple consumers** (e.g. `shared-homelab-secrets`
  with `dex-envoy-client-id` alongside `n8n-db-password`) → use
  explicit `data:` blocks with `remoteRef.property` to remap the
  1P field label to the consumer-expected key name. Field labels on
  the item stay app-prefixed (`dex-envoy-*`, `plane-*`, `grafana-*`)
  to avoid collisions.

Consumers that follow this sub-pattern today:

| Namespace / Secret         | Shape (consumer expects)     | 1P item                | 1P fields consumed |
| -------------------------- | ---------------------------- | ---------------------- | ------------------ |
| `gateway/dex-client-envoy` | `client-id`, `client-secret` | `gateway-homelab-auth` | `client-id`, `client-secret` (explicit `data:`) |
| `gateway/gateway-homelab-auth` | any K8s data-key is a valid X-API-Key credential (see `inbox-apikey` SP); the audit trail records the matched key name via `forwardClientIDHeader: x-client-id`. Today: `apikey-gateway`. | `gateway-homelab-auth` | `apikey-gateway` → K8s data key `apikey-gateway` (1:1, no remap). The label describes the gateway credential itself, not any single consumer — the same value protects the `inbox` and `ray-api` listeners. Additional distinct credentials get their own `apikey-<name>` field + matching K8s data key. |

More entries land here as the plane / grafana / google-oauth-client
migrations happen.
