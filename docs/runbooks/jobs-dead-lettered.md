# Runbook: failed jobs in a dead letter queue

**Alert:** `JobsDeadLettered`: a dead letter queue of the namespace `jobs` (`jobs.inference.dead`) holds jobs.
A job lands there after its third failure: its worker rejected it, or died holding it, three times (policy `jobs-retry` in [`platform/job-queue/base/topology.yaml`](../../platform/job-queue/base/topology.yaml)).
Effect: those jobs are not processed. Nothing else is: the other jobs keep flowing, and the alert stays on until the queue is empty.

The commands below run `rabbitmqadmin` in the RabbitMQ pod, with the default user from the secret `rabbitmq-default-user`:

```bash
rmq() {
  kubectl -n jobs exec rabbitmq-server-0 -c rabbitmq -- bash -c 'conf=/etc/rabbitmq/conf.d/11-default_user.conf
    rabbitmqadmin --non-interactive --username "$(sed -n "s/^default_user = //p" $conf)" \
      --password "$(sed -n "s/^default_pass = //p" $conf)" "$@"' rmq "$@"
}
```

## 1. Why they failed

```bash
kubectl -n jobs exec rabbitmq-server-0 -c rabbitmq -- rabbitmqctl -q list_queues name messages   # how many in each queue
rmq get messages --queue jobs.inference.dead --count 5 --ack-mode ack_requeue_true                 # look, and leave them
```

Each job keeps its body and an `x-death` header: the queue it came from, the reason (`delivery_limit`), and how many times it died.
Then read the logs and traces of the worker at the time of the failures (Grafana, Explore, Loki and Tempo, namespace of the workers).

| What you see | Likely cause | Next |
| -- | -- | -- |
| `429` in the worker's logs, `Rate limit exceeded for api_key` | the jobs went over the team's requests per minute (`config/tenants.yaml`): the retries come 5 s and 10 s later, inside the same minute (LAB-194) | replay them at a slower pace: fewer workers, or a team limit that fits the batch |
| every job of a period, whatever its content | the worker or what it calls was down (gateway, model) | fix it, then replay them all (step 2) |
| always the same kind of job | a job the worker cannot process: bad input, too long for the model | fix the worker or the producer; replay, or purge if the job is invalid |
| the worker restarts while processing (`OOMKilled`) | the job needs more memory than the worker's limit | raise the limit in Git, then replay |

## 2. Replay them

Once the cause is fixed, a shovel moves the jobs back to the exchange `jobs` with their routing key, and they start again with three attempts:

```bash
rmq shovels declare_amqp091 --name replay-inference --source-uri amqp:// --destination-uri amqp:// \
  --source-queue jobs.inference.dead --destination-exchange jobs --predeclared-source --predeclared-destination
kubectl -n jobs exec rabbitmq-server-0 -c rabbitmq -- rabbitmqctl -q list_queues name messages   # until .dead is at 0
rmq shovels delete --name replay-inference   # a shovel keeps running until deleted
```

To drop them instead: `rmq purge queue --name jobs.inference.dead`.

## 3. After

Check that the replayed jobs are processed (dashboard **Job queues**: *Jobs waiting* goes down, *Failed jobs set aside* is at 0) and that the alert resolves.
