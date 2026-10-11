#!/usr/bin/env bash
# Check the job queue: RabbitMQ and its topology ready, then fail a job three times, as a worker would, and check that
# RabbitMQ retries it after a growing delay, sets it aside in the dead letter queue, and that Prometheus sees it there.
# The dead letter queue is purged before and after: run it on a test cluster only.
# Usage: scripts/queue-check.sh <kube context>
set -euo pipefail

context=${1:?usage: $0 <kube context>}
kc=(kubectl --context "$context")
ns=jobs
queue=jobs.inference
dead=jobs.inference.dead
prometheus=/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1

# Run in the RabbitMQ pod, with the default user's credentials read there: they never reach a command line here.
rabbit() {
  "${kc[@]}" -n "$ns" exec rabbitmq-server-0 -c rabbitmq -- bash -c '
    conf=/etc/rabbitmq/conf.d/11-default_user.conf
    adm() {
      rabbitmqadmin --non-interactive --username "$(sed -n "s/^default_user = //p" $conf)" \
        --password "$(sed -n "s/^default_pass = //p" $conf)" "$@"
    }
    '"$1"
}
messages() { rabbit "rabbitmqctl -q list_queues name messages --no-table-headers" | awk -v q="$1" '$1 == q {print $2}'; }
# Length of the dead letter queue as Prometheus last scraped it.
query=$(python3 -c 'import urllib.parse; print(urllib.parse.quote(
  """rabbitmq_detailed_queue_messages{namespace="jobs", queue="jobs.inference.dead"}"""))')
scraped() {
  "${kc[@]}" get --raw "$prometheus/query?query=$query" \
    | python3 -c 'import json, sys; r = json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "none")'
}
# wait_scraped <value>: wait up to 2 minutes for Prometheus to scrape that length.
wait_scraped() {
  for _ in $(seq 24); do
    [[ $(scraped) == "$1" ]] && return
    sleep 5
  done
  echo "Prometheus sees $(scraped) jobs in $dead after 2 minutes, not $1" >&2
  exit 1
}

echo "== RabbitMQ"
"${kc[@]}" -n "$ns" wait rabbitmqcluster/rabbitmq --for=condition=AllReplicasReady --timeout=300s
"${kc[@]}" -n "$ns" wait --for=condition=Ready --timeout=120s --all \
  exchanges.rabbitmq.com,queues.rabbitmq.com,bindings.rabbitmq.com,policies.rabbitmq.com
rabbit "rabbitmqctl -q list_queues name type policy messages consumers"
rabbit "rabbitmqctl -q list_policies"

echo "== A job that fails three times"
rabbit "adm purge queue --name $dead" >/dev/null
# So that the job Prometheus sees in the dead letter queue at the end is this one.
wait_scraped 0
job="queue-check-$(date +%s)"
rabbit "adm publish message --exchange jobs --routing-key inference --payload $job" >/dev/null
echo "Published $job to the exchange jobs"
last=""
for attempt in 1 2 3; do
  # Fetch it and reject it with requeue, as a worker that fails a job does.
  for _ in $(seq 60); do
    rabbit "adm get messages --queue $queue --ack-mode reject_requeue_true" | grep -q "$job" && break
    sleep 1
  done
  now=$(date +%s)
  if [[ -z $last ]]; then
    echo "Attempt 1: rejected"
  else
    waited=$((now - last))
    echo "Attempt $attempt: rejected, delivered again ${waited} s after the previous failure"
    # 5 s times the delivery count (topology.yaml): 5 s, then 10 s. One second of slack for the polling.
    ((waited >= 5 * (attempt - 1) - 1)) || { echo "Delivered again after ${waited} s, before its delay" >&2; exit 1; }
  fi
  last=$now
done

for _ in $(seq 30); do
  [[ $(messages "$dead") == 1 ]] && break
  sleep 1
done
[[ $(messages "$dead") == 1 ]] || { echo "$job is not in $dead after its third failure" >&2; exit 1; }
[[ $(messages "$queue") == 0 ]] || { echo "$job is still in $queue" >&2; exit 1; }
echo "$job is in $dead, and no longer in $queue"

echo "== Seen by Prometheus"
wait_scraped 1
echo "Prometheus sees 1 job in $dead (dashboard Job queues, alert JobsDeadLettered)"

rabbit "adm purge queue --name $dead" >/dev/null
printf '\nJob queue OK: three failures, then the dead letter queue\n'
