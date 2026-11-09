# pgAdmin in a FlowX dev env: runbook

A browser SQL client inside a dev env namespace, already connected to that env's PostgreSQL.
The DB password is taken from the env's own secret, so nobody types or shares it.

| File | What it is |
|---|---|
| `pgadmin.yaml` | ConfigMap (pre-registered server), Deployment (pgAdmin 4 `8.14`), Service. Template, filled by `deploy.sh`. |
| `ingress.yaml` | Optional public URL. Template, filled by `deploy.sh --ingress`. |
| `deploy.sh` | Detects the Postgres password secret, creates a random login secret, applies, waits until ready. |
| `remove.sh` | Deletes everything labelled `app=pgadmin` (or only the ingress). |

Currently deployed: `dev-pr3241` (FlowX 3.4.8), with ingress `https://pgadmin-pr3241.dev3.flowxai.dev` (2026-11-06).

## 1. Before you start

- **Cluster access with write rights.** Group `gke-devenv-rw@flowx.ai` (read-only `gke-devenv-ro` can't create objects).
  ```sh
  gcloud auth login            # if kubectl says "Reauthentication failed"
  gcloud container clusters get-credentials dev-cls3 --zone europe-west4 --project prj-dev-d-flowxai-dev-75c3
  ```
- The namespace of the env: `dev-pr<PR number>`, e.g. `dev-pr3241`.
- Ask the env owner first. pgAdmin connects as the Postgres **superuser**: whoever uses it can change or drop any data.

## 2. Deploy

```sh
cd pgadmin
./deploy.sh dev-pr3241                                              # port-forward access only
./deploy.sh dev-pr3241 --ingress pgadmin-pr3241.dev3.flowxai.dev    # plus a public URL
```

What it does:
1. Reads which secret holds the Postgres password from pod `postgresql-0` (env `POSTGRES_PASSWORD`).
   On FlowX 3.x bases that is `postgresql-generic` / `postgresql-password`.
   If the pod reads the password from a file instead (some 5.x bases), the script stops and tells you to pass it:
   `PG_SECRET=<secret> PG_KEY=<key> ./deploy.sh <ns>`.
2. Creates Secret `pgadmin-login` with a random password, once. Redeploys keep it.
3. Applies the manifests and waits for the pod. It prints how to open it and how to read the login password.

Rerunning `deploy.sh` is safe (it's `kubectl apply`).

Host names on dev3 follow `<name>-pr<PR>.dev3.flowxai.dev`; the wildcard DNS and certificate already cover any new name.

## 3. Open it

- **With the ingress:** `https://pgadmin-pr<PR>.dev3.flowxai.dev`
- **Without:** `kubectl -n dev-pr<PR> port-forward svc/pgadmin 8080:8080`, then `http://localhost:8080`

Login: `admin@flowx.ai` and the password from
```sh
kubectl -n dev-pr<PR> get secret pgadmin-login -o jsonpath='{.data.password}' | base64 -d; echo
```

In the left panel, `Servers` → the pre-registered server → Databases. No DB password prompt.

**Giving a colleague access** without cluster rights: deploy with `--ingress`, then send them the URL, and the login password privately (not in a channel).

## 4. Check it works

```sh
kubectl -n dev-pr<PR> get pod -l app=pgadmin                # 1/1 Running
kubectl -n dev-pr<PR> logs deploy/pgadmin | grep 'Added'    # "Added 0 Server Group(s) and 1 Server(s)."
curl -s -o /dev/null -w '%{http_code}\n' https://pgadmin-pr<PR>.dev3.flowxai.dev/misc/ping   # 200
```

DB login test from inside the pod (no password shown):
```sh
kubectl -n dev-pr<PR> exec deploy/pgadmin -c pgadmin -- sh -c \
  'PGPASSFILE=/var/lib/pgadmin/storage/admin_flowx.ai/pgpass /usr/local/pgsql-17/psql -h postgresql -U postgres -d postgres -Atc "select version()"'
```

## 5. Things to know

- **No disk.** Saved queries, settings and extra servers live in an `emptyDir`. A pod restart (including the nightly scale-down) loses them. The pre-registered server and the login come back.
- **Nightly scale-down.** Dev envs with `dailyScale` scale every Deployment to 0 at 20:00 UTC and back up at 05:00 UTC on weekdays. pgAdmin goes down and comes back with the env.
- **Not in the env's PR.** These objects are applied by hand. The `devenv` pipeline applies without pruning, so a redeploy leaves them alone; deleting the namespace removes them.
- **Security.** With the ingress, the page is on the internet behind only the pgAdmin login. Remove the ingress when you no longer need it.

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Reauthentication failed. cannot prompt during non-interactive execution` | Run `gcloud auth login` in a terminal. |
| `forbidden` on create | You need `gke-devenv-rw@flowx.ai`. |
| Pod stuck in `Init` / `CreateContainerConfigError` | Wrong `PG_SECRET`/`PG_KEY`. `kubectl -n <ns> describe pod -l app=pgadmin`. |
| pgAdmin asks for the DB password | pgpass missing or wrong. Check the init container log, and that the server's host/user match `PG_SERVICE`/`PG_USER`. |
| Server list empty | `servers.json` is loaded only on the first start of a fresh storage. Delete the pod; it starts clean. |
| URL gives 404 / 503 | Ingress missing or pod not ready: `kubectl -n <ns> get ingress,pod -l app=pgadmin`. |

## 7. Alternative: the base's own pgAdmin release

`k8s-flowx-base` has an optional `pgadmin` helmfile release (`installed: false` by default; values in `bases/flowx-base/test-deps-values/pgadmin.yaml.gotmpl`). Turning it on from an env's PR keeps it in git, but as shipped it:
- uses the Postgres password as the pgAdmin **login** password;
- builds its host from `flowx.ingress.tools` (a sandbox domain), so a dev env needs a host override;
- adds a 1Gi PVC, and connects as user `flowx` to DB `keycloak`.

This kit avoids those trade-offs and needs no PR. Use the base release if the env's owner wants it versioned in the PR.

## 8. Remove

```sh
./remove.sh dev-pr<PR> --ingress   # only the public URL
./remove.sh dev-pr<PR>             # everything, incl. the login secret
```
