#!/usr/bin/env bash
# Load benchmark of the job workers' autoscaling (LAB-136). For each KEDA setting: apply it to the ScaledObject, run a
# k6 scenario inside the cluster (benchmarks/k6/), and record every second the workers' replicas and the jobs in the
# queue, until the workers are back to zero. Then scripts/bench-report.py turns the records into the results table
# and the charts of benchmarks/results/.
# ArgoCD would put the ScaledObject back as in Git: its reconciliation of job-worker is suspended meanwhile, and
# resumed at the end. Run it on a test cluster only.
# Usage: scripts/bench-autoscaling.sh <kube context> <ramp|spike|soak> [setting...] (all by default)
set -euo pipefail

context=${1:?usage: $0 <kube context> <ramp|spike|soak> [setting...]}
scenario=${2:?usage: $0 <kube context> <ramp|spike|soak> [setting...]}
shift 2
[[ $scenario =~ ^(ramp|spike|soak)$ ]] || { echo "Unknown scenario $scenario" >&2; exit 1; }

# The settings compared: jobs per worker (KEDA's target), seconds without jobs before zero workers (KEDA's cooldown),
# and the HPA's scale-down window: it keeps the highest replica count it computed over that window, 300 s by default.
# The polling interval (5 s) and the bounds (0 to 6 workers) stay those of Git.
declare -A settings=(
  [eager]="2 30 300"      # one worker per 2 jobs, zero 30 s after the last one
  [git]="4 60 300"        # platform/job-worker/base/autoscaling.yaml before LAB-136
  [frugal]="8 120 300"    # one worker per 8 jobs, zero 2 min after the last one
  [git-down30]="4 60 30"  # as git, but fewer workers 30 s after fewer jobs
  [tuned]="2 60 120"      # the setting chosen from the four above (benchmarks/README.md)
)
(($# > 0)) || set -- eager git frugal git-down30 tuned
for name; do [[ -n ${settings[$name]:-} ]] || { echo "Unknown setting $name" >&2; exit 1; }; done

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/benchmarks/results/$scenario
kc=(kubectl --context "$context" -n jobs)
port=15673
forward=""

restore() {
  [[ -n $forward ]] && kill "$forward" 2>/dev/null
  "${kc[@]}" delete job bench-k6 --ignore-not-found --wait=false >/dev/null
  "${kc[@]}" delete configmap bench-k6 bench-k6-env --ignore-not-found >/dev/null
  kubectl --context "$context" -n argocd annotate application job-worker argocd.argoproj.io/skip-reconcile- >/dev/null
  kubectl --context "$context" -n argocd annotate application job-worker argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  echo "ArgoCD manages job-worker again"
}
trap restore EXIT

# RabbitMQ's management API, through a port-forward, to read the queue every second.
user=$("${kc[@]}" get secret rabbitmq-default-user -o jsonpath='{.data.username}' | base64 -d)
password=$("${kc[@]}" get secret rabbitmq-default-user -o jsonpath='{.data.password}' | base64 -d)
"${kc[@]}" port-forward svc/rabbitmq "$port:15672" >/dev/null &
forward=$!
api() { curl -sf -u "$user:$password" "http://localhost:$port/api/$1"; }
for _ in $(seq 30); do api overview >/dev/null && break; sleep 1; done

# A Deployment at zero has no replicas fields at all.
replicas() { "${kc[@]}" get deployment worker -o jsonpath='{.spec.replicas} {.status.replicas} {.status.readyReplicas}'; }
queue() {
  api queues/%2F/jobs.inference | python3 -c 'import json, sys
q = json.load(sys.stdin)
print(q.get("messages_ready", 0), q.get("messages_unacknowledged", 0))'
}
idle() {
  local r q
  read -r -a r <<<"$(replicas)" && read -r -a q <<<"$(queue)"
  [[ ${r[0]:-0} -eq 0 && ${r[1]:-0} -eq 0 && ${q[0]} -eq 0 && ${q[1]} -eq 0 ]]
}
wait_idle() {
  for _ in $(seq 400); do idle && return; sleep 1; done
  echo "The workers did not go back to zero" >&2
  exit 1
}

echo "== Suspending ArgoCD's reconciliation of job-worker"
kubectl --context "$context" -n argocd annotate application job-worker argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
# The annotation does not stop a sync already running (scripts/slo-check.sh).
sleep 10

"${kc[@]}" create configmap bench-k6 --from-file="$root/benchmarks/k6/autoscaling.js" \
  --dry-run=client -o yaml | "${kc[@]}" apply -f - >/dev/null
"${kc[@]}" create configmap bench-k6-env --from-literal=SCENARIO="$scenario" --from-literal=JOB_SECONDS=2 \
  --dry-run=client -o yaml | "${kc[@]}" apply -f - >/dev/null
mkdir -p "$out"

for name; do
  read -r value cooldown window <<<"${settings[$name]}"
  echo "== $scenario, setting $name: $value jobs per worker, zero after $cooldown s, scale-down window $window s"
  "${kc[@]}" patch scaledobject worker --type merge -p "$(python3 -c 'import json, sys
value, cooldown, window = sys.argv[1:]
print(json.dumps({"spec": {
    "cooldownPeriod": int(cooldown),
    "advanced": {"horizontalPodAutoscalerConfig": {"behavior": {"scaleDown": {"stabilizationWindowSeconds": int(window)}}}},
    "triggers": [{"type": "rabbitmq", "authenticationRef": {"name": "rabbitmq"}, "metadata": {
        "protocol": "http", "queueName": "jobs.inference", "mode": "QueueLength", "value": value}}],
}}))' "$value" "$cooldown" "$window")" >/dev/null
  wait_idle
  # The HPA remembers the replica counts of the last run for its scale-down window, and would start this one at the
  # last peak: KEDA recreates it without that memory.
  "${kc[@]}" delete hpa keda-hpa-worker --wait=true >/dev/null
  for _ in $(seq 60); do "${kc[@]}" get hpa keda-hpa-worker >/dev/null 2>&1 && break; sleep 1; done

  "${kc[@]}" delete job bench-k6 --ignore-not-found --wait=true >/dev/null
  "${kc[@]}" apply -f "$root/benchmarks/k6/job.yaml" >/dev/null
  csv=$out/$name.csv
  echo "t,desired,replicas,ready,waiting,in_progress" >"$csv"
  start=$(date +%s.%N) finished="" seen=""
  while true; do
    now=$(date +%s.%N)
    read -r -a r <<<"$(replicas)"
    read -r -a q <<<"$(queue)"
    t=$(python3 -c "print(round($now - $start, 1))")
    echo "$t,${r[0]:-0},${r[1]:-0},${r[2]:-0},${q[0]},${q[1]}" >>"$csv"
    ((${r[1]:-0} > 0)) && seen=1
    if [[ -z $finished ]]; then
      status=$("${kc[@]}" get job bench-k6 -o jsonpath='{.status.succeeded}{.status.failed}')
      [[ -n $status ]] && finished=$t && echo "k6 finished at ${t} s"
    elif [[ -n $seen && ${r[1]:-0} -eq 0 && ${r[0]:-0} -eq 0 ]]; then
      echo "Workers back to zero at ${t} s"
      break
    fi
    python3 -c "import time; time.sleep(max(0, 1 - (time.time() - $now)))"
    (($(printf '%.0f' "$t") < 1800)) || { echo "Timed out after 1800 s" >&2; exit 1; }
  done

  logs=$("${kc[@]}" logs job/bench-k6)
  summary=$(sed -n 's/^BENCH_SUMMARY //p' <<<"$logs")
  [[ -n $summary ]] || { echo "$logs" >&2; echo "No summary from k6" >&2; exit 1; }
  # The time origin of the charts is when k6's scenarios started; offset: how long after the first record.
  python3 -c 'import json, sys
s = json.loads(sys.argv[1])
s.update(setting=sys.argv[2], value=int(sys.argv[3]), cooldown=int(sys.argv[4]), window=int(sys.argv[5]),
         offset=round(s["start"] / 1000 - float(sys.argv[6]), 1))
open(sys.argv[7], "w").write(json.dumps(s, indent=2) + "\n")' "$summary" "$name" "$value" "$cooldown" "$window" "$start" "$out/$name.json"
  [[ $("${kc[@]}" get job bench-k6 -o jsonpath='{.status.succeeded}') == 1 ]] \
    || { echo "$logs" >&2; echo "k6 failed: thresholds not met" >&2; exit 1; }
  python3 -c 'import json, sys
s = json.loads(sys.argv[1])
if not s["answered"] == s["published"] > 0:
    sys.exit("%(answered)s of %(published)s jobs answered" % s)' "$summary"
  echo "$summary"
done

uv run --quiet --with matplotlib "$root/scripts/bench-report.py" "$root/benchmarks/results" "$scenario"
