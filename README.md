# jeffrey-epstein-files-fetcher

A Kubernetes-native bulk downloader for the DOJ's publicly released Jeffrey Epstein disclosure documents (EFTA datasets). Uses Python's `ThreadPoolExecutor` for concurrent downloads and runs as a Kubernetes **Indexed Job** to distribute work across multiple pods.

---

## How it works

The downloader targets the DOJ's Epstein disclosure portal at `justice.gov/epstein`. Each dataset contains sequentially numbered PDFs named `EFTA{08d}.pdf` (e.g. `EFTA00000001.pdf`).

When the Job runs:

1. The total file range is split evenly across all pods using `JOB_COMPLETION_INDEX`
2. Each pod downloads its assigned slice concurrently via `ThreadPoolExecutor`
3. Files are written to a shared `PersistentVolumeClaim` at `/data/dataset-{N}/`
4. Already-downloaded files are skipped (idempotent)
5. Failed requests are retried up to 3 times, with backoff for `429` and network errors

---

## Project structure

```
.
├── scripts/
│   └── fetch_data.py          # Core downloader script
└── k8s/
    └── dev-tools/
        ├── fetcher-job.yaml   # Kubernetes Indexed Job (4 parallel pods)
        └── fetcher-dev.yaml   # Dev pod for local testing (sleep infinity)
```

---

## Prerequisites

- Kubernetes cluster with the `data-dev` namespace
- A PVC named `jeffrey-epstein-files-trainer-training-data` in `data-dev`
- Docker image `rinavillaruz/jeffrey-epstein-files-fetcher` available to the cluster

---

## Running the job

Apply the Indexed Job manifest:

```bash
kubectl apply -f k8s/dev-tools/fetcher-job.yaml
```

Monitor progress:

```bash
kubectl logs -n data-dev -l app=jeffrey-epstein-files-fetcher --follow
```

Check job status:

```bash
kubectl get job fetcher-job -n data-dev
```

---

## Configuration

The following environment variables control behaviour:

| Variable             | Default | Description                                      |
|----------------------|---------|--------------------------------------------------|
| `WORKERS`            | `25`    | Number of concurrent download threads per pod    |
| `TOTAL_PODS`         | `4`     | Total pods in the job (must match `completions`) |
| `JOB_COMPLETION_INDEX` | `0`   | Set automatically by Kubernetes Indexed Job      |

The job manifest sets `WORKERS=50` and `TOTAL_PODS=4`, giving up to **200 concurrent downloads** across the cluster.

---

## Dev pod

A `fetcher-dev` pod is provided for debugging and manual testing. It mounts the same PVC and runs `sleep infinity` so you can exec in:

```bash
kubectl apply -f k8s/dev-tools/fetcher-dev.yaml
kubectl exec -it fetcher-dev -n data-dev -- bash
```

---

## Download behaviour

| HTTP status | Action                          |
|-------------|---------------------------------|
| `200`       | Save file, log `OK`             |
| `403`       | Log `BLOCKED`, skip             |
| `429`       | Wait 10s, retry                 |
| Other       | Log `FAIL` with status code     |
| Network err | Retry up to 3 times (5s backoff)|
| File exists | Skip (idempotent)               |

---

## Resources per pod

```yaml
requests:
  memory: 512Mi
  cpu: 500m
limits:
  memory: 2Gi
  cpu: 2000m
```
