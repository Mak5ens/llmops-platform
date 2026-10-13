#!/usr/bin/env bash
# Check the autoscaling of the job workers (LAB-135): zero workers on an empty queue, then 500 simulated jobs make KEDA
# scale them up, a worker is deleted while it works, and every job is answered exactly once before the workers go back
# to zero. Prints how long each step took.
# The dead letter queue is purged first: run it on a test cluster only.
# Usage: scripts/autoscaling-check.sh <kube context> [jobs, default 500] [seconds per job, default 2]
set -euo pipefail

context=${1:?usage: $0 <kube context> [jobs] [seconds per job]}
jobs=${2:-500}
seconds=${3:-2}
kc=(kubectl --context "$context" -n jobs)
replies=autoscaling-check

# Run in the RabbitMQ pod, with the default user's credentials read there (as scripts/queue-check.sh).
rabbit() {
  "${kc[@]}" exec rabbitmq-server-0 -c rabbitmq -- bash -c '
    conf=/etc/rabbitmq/conf.d/11-default_user.conf
    adm() {
      rabbitmqadmin --non-interactive --username "$(sed -n "s/^default_user = //p" $conf)" \
        --password "$(sed -n "s/^default_pass = //p" $conf)" "$@"
    }
    '"$1"
}
messages() { rabbit "rabbitmqctl -q list_queues name messages --no-table-headers" | awk -v q="$1" '$1 == q {print $2}'; }
# A Deployment at zero has no replicas field at all.
replicas() { local n; n=$("${kc[@]}" get deployment worker -o jsonpath='{.status.replicas}'); echo "${n:-0}"; }
ready() { local n; n=$("${kc[@]}" get deployment worker -o jsonpath='{.status.readyReplicas}'); echo "${n:-0}"; }
no_workers() { [[ $(replicas) -eq 0 ]]; }
# wait_for <description> <timeout in s> <command...>: poll until the command succeeds. Pass a function, not an
# expression with $(...), which would be evaluated once.
wait_for() {
  local what=$1 timeout=$2
  shift 2
  for _ in $(seq "$timeout"); do
    "$@" && return
    sleep 1
  done
  echo "Timed out after ${timeout} s: $what" >&2
  exit 1
}

echo "== Workers and their scaler"
"${kc[@]}" wait scaledobject/worker --for=condition=Ready --timeout=120s
# After an earlier run, the workers may still be cooling down.
wait_for "zero workers on an empty queue" 180 no_workers
echo "0 workers while the queue is empty"

echo "== $jobs simulated jobs of $seconds s"
rabbit "adm declare queue --name $replies --type quorum --durable true >/dev/null; adm purge queue --name $replies
  adm purge queue --name jobs.inference.dead" >/dev/null
start=$SECONDS
# One exec for every publish: a kubectl exec per job would take longer than the jobs.
rabbit "for i in \$(seq $jobs); do
  adm publish message --exchange jobs --routing-key inference --properties '{\"reply_to\": \"$replies\"}' \
    --payload '{\"id\": \"check-'\$i'\", \"team\": \"f1\", \"simulate\": {\"seconds\": $seconds}}' >/dev/null || exit 1
done"
published=$((SECONDS - start))
echo "Published in ${published} s"

first_ready="" max=0 deleted="" done_at=""
while true; do
  now=$((SECONDS - start)) count=$(replicas) answered=$(messages "$replies")
  ((count > max)) && max=$count
  [[ -z $first_ready && $(ready) -ge 1 ]] && first_ready=$now && echo "${now} s: first worker ready"
  # Halfway, delete a worker while it holds jobs: it must finish them before it stops.
  if [[ -z $deleted && $answered -ge $((jobs / 2)) && $count -ge 2 ]]; then
    pod=$("${kc[@]}" get pods -l app.kubernetes.io/name=worker -o jsonpath='{.items[0].metadata.name}')
    "${kc[@]}" delete pod "$pod" --wait=false >/dev/null
    deleted=$now && echo "${now} s: deleted $pod, ${answered} jobs answered"
  fi
  if [[ $answered -ge $jobs ]]; then
    done_at=$now && echo "${now} s: ${answered} jobs answered, ${max} workers at most"
    break
  fi
  ((now < 900)) || { echo "Only ${answered} of $jobs jobs answered after 900 s" >&2; exit 1; }
  sleep 2
done

echo "== No job lost, none twice"
answered=$(messages "$replies") dead=$(messages jobs.inference.dead) left=$(messages jobs.inference)
echo "answered ${answered}, dead-lettered ${dead}, left in the queue ${left}"
[[ $answered -eq $jobs && $dead -eq 0 && $left -eq 0 ]] || { echo "Expected $jobs answers, none dead or left" >&2; exit 1; }

echo "== Back to zero"
wait_for "workers back to zero" 300 no_workers
zero=$((SECONDS - start))
rabbit "adm delete queue --name $replies" >/dev/null

printf '\n%-44s %6s\n' "Step" "Time"
printf '%-44s %5ss\n' "publish $jobs jobs" "$published" \
  "first worker ready, from the first job" "$first_ready" \
  "every job answered" "$done_at" \
  "back to zero workers" "$zero"
printf '%-44s %6s\n' "workers at most" "$max"
printf '\nAutoscaling OK: 0 → %s → 0 workers, %s jobs answered once each\n' "$max" "$jobs"
