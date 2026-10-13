// Load scenarios of the job workers (LAB-136). Publishes jobs, simulated unless JOB_ALIAS is set, to the exchange
// `jobs` through RabbitMQ's management API, collects the workers' replies, and measures how long each job took from its
// reply: the time it waited for a worker (scale-up included) plus the time it ran.
//
// Run inside the cluster by scripts/bench-autoscaling.sh, which also follows the replica count. SCENARIO picks one of:
// - ramp: from 0 to 6 jobs a second over 3 min, held 1 min, back to 0 over 1 min;
// - spike: two bursts of 150 jobs, 95 s apart: the first takes about 45 s to answer, so the workers idle about 50 s
//   before the second, between the shortest and the default delay before zero workers;
// - soak: 3 jobs a second for 4 min, then nothing.
//
// The management API publishes and gets one HTTP request at a time: fine for tens of jobs a second, not for a
// throughput test of RabbitMQ itself.
import encoding from 'k6/encoding';
import exec from 'k6/execution';
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Gauge, Trend } from 'k6/metrics';

const api = __ENV.RABBITMQ_URL.replace(/\/$/, '');
const params = {
  headers: {
    Authorization: `Basic ${encoding.b64encode(`${__ENV.RABBITMQ_USER}:${__ENV.RABBITMQ_PASSWORD}`)}`,
    'Content-Type': 'application/json',
  },
  tags: { name: 'management api' },
};
const replies = __ENV.REPLY_QUEUE || 'bench-replies';
const seconds = Number(__ENV.JOB_SECONDS || 2);
// With JOB_ALIAS, real jobs instead of simulated ones: each asks the alias a question about Formula 1 strategy, with
// up to JOB_MAX_TOKENS tokens out (scripts/inference-peak.sh, LAB-138). chat-pro calls Scaleway and costs money.
const alias = __ENV.JOB_ALIAS;
const maxTokens = Number(__ENV.JOB_MAX_TOKENS || 512);
const questions = [
  "Explique ce qu'est un undercut en Formule 1, avec un exemple chiffré.",
  'Un pilote a des pneus durs usés de 25 tours et la voiture de sécurité sort. Doit-il s\'arrêter ? Justifie.',
  'Compare une stratégie à un arrêt et une stratégie à deux arrêts sur un circuit où dépasser est difficile.',
  "Quelles informations un ingénieur de course surveille-t-il pendant les dix derniers tours d'un Grand Prix ?",
  'Rédige le briefing de stratégie d\'une course incertaine sous la pluie, en cinq points.',
];
const scenario = __ENV.SCENARIO || 'spike';

// A job's latency, from its publication to its reply, in ms.
const latency = new Trend('job_latency', true);
// When the scenarios started (epoch ms): the time origin of the records. Not the end of setup(), which can come
// seconds earlier.
const runStart = new Gauge('run_start');
// The latency of the first job published: it waits for the first worker to start.
const firstLatency = new Gauge('first_job_latency', true);
const published = new Counter('jobs_published');
const answered = new Counter('jobs_answered');
const failed = new Counter('jobs_failed');

// Each scenario's publishers, and when the last one stops publishing (s).
const burst = (startTime) => ({
  executor: 'constant-arrival-rate',
  rate: 30,
  timeUnit: '1s',
  duration: '5s',
  startTime,
  preAllocatedVUs: 20,
  maxVUs: 60,
});
const publishers = {
  ramp: {
    scenarios: {
      ramp: {
        executor: 'ramping-arrival-rate',
        startRate: 0,
        timeUnit: '1s',
        stages: [
          { target: 6, duration: '3m' },
          { target: 6, duration: '1m' },
          { target: 0, duration: '1m' },
        ],
        preAllocatedVUs: 10,
        maxVUs: 30,
      },
    },
    end: 300,
  },
  spike: { scenarios: { first: burst('0s'), second: burst('95s') }, end: 100 },
  soak: {
    scenarios: {
      soak: { executor: 'constant-arrival-rate', rate: 3, timeUnit: '1s', duration: '4m', preAllocatedVUs: 10, maxVUs: 30 },
    },
    end: 240,
  },
}[scenario];

const scenarios = { ...publishers.scenarios };
for (const name of Object.keys(scenarios)) scenarios[name] = { ...scenarios[name], exec: 'publish' };

export const options = {
  scenarios: {
    ...scenarios,
    // One VU gets the replies until every job is answered (or the deadline).
    collect: { executor: 'per-vu-iterations', vus: 1, iterations: 1, maxDuration: '20m', exec: 'collect' },
  },
  thresholds: {
    checks: ['rate==1'],
    jobs_failed: ['count==0'],
    // No limit: a threshold only makes k6 report the latency of each publisher apart (both bursts of spike).
    ...Object.fromEntries(Object.keys(scenarios).map((name) => [`job_latency{publisher:${name}}`, ['max>=0']])),
  },
  // The default summary's p(90) is replaced by p(50), the median the results report.
  summaryTrendStats: ['min', 'med', 'p(95)', 'p(99)', 'max', 'count'],
};

function queue(name) {
  return `${api}/api/queues/%2F/${encodeURIComponent(name)}`;
}

export function setup() {
  // RabbitMQ 4 refuses transient shared queues: a durable quorum queue, deleted at the end.
  const declared = http.put(queue(replies), JSON.stringify({ durable: true, arguments: { 'x-queue-type': 'quorum' } }), params);
  check(declared, { 'reply queue declared': (r) => r.status === 201 || r.status === 204 });
  http.del(`${queue(replies)}/contents`, null, params);
}

export function publish() {
  const id = `bench-${exec.scenario.name}-${Date.now()}-${exec.scenario.iterationInTest}`;
  const body = {
    routing_key: 'inference',
    properties: { reply_to: replies, delivery_mode: 2 },
    payload: JSON.stringify(
      alias
        ? {
            id,
            team: 'f1',
            alias,
            max_tokens: maxTokens,
            messages: [{ role: 'user', content: questions[exec.scenario.iterationInTest % questions.length] }],
          }
        : { id, team: 'f1', simulate: { seconds } },
    ),
    payload_encoding: 'string',
  };
  const res = http.post(`${api}/api/exchanges/%2F/jobs/publish`, JSON.stringify(body), params);
  if (check(res, { 'job routed': (r) => r.status === 200 && r.json('routed') === true })) published.add(1);
}

// Jobs still in jobs.inference, waiting or held by a worker.
function pending() {
  const res = http.get(queue('jobs.inference'), params);
  return res.status === 200 ? res.json('messages') : -1;
}

export function collect() {
  // The collector starts with the first publisher. After the last publication, stop once the queue has been empty for
  // 15 s with no reply left: the management API refreshes the queue's counts every 5 s only.
  const start = Date.now();
  runStart.add(start);
  const end = start + publishers.end * 1000;
  let quiet = null;
  let first = Infinity;
  for (;;) {
    const res = http.post(
      `${queue(replies)}/get`,
      JSON.stringify({ count: 500, ackmode: 'ack_requeue_false', encoding: 'auto' }),
      params,
    );
    const now = Date.now();
    const got = res.status === 200 ? res.json() : [];
    for (const message of got) {
      const reply = JSON.parse(message.payload);
      // bench-<publisher>-<published at, ms>-<n>
      const [, publisher, published] = reply.id.split('-');
      latency.add(now - Number(published), { publisher });
      if (Number(published) < first) {
        first = Number(published);
        firstLatency.add(now - first);
      }
      if (reply.status === 'done') answered.add(1);
      else failed.add(1);
    }
    if (got.length > 0 || now < end || pending() !== 0) quiet = null;
    else if (quiet === null) quiet = now;
    else if (now - quiet > 15000) break;
    sleep(0.5);
  }
}

export function teardown() {
  http.del(queue(replies), null, params);
}

// One line for scripts/bench-autoscaling.sh, after k6's own summary.
export function handleSummary(data) {
  const values = (name) => (data.metrics[name] ? data.metrics[name].values : {});
  const summary = {
    scenario,
    start: values('run_start').value,
    published: values('jobs_published').count || 0,
    answered: values('jobs_answered').count || 0,
    failed: values('jobs_failed').count || 0,
    latency: values('job_latency'),
    first: values('first_job_latency').value,
    publishers: Object.fromEntries(Object.keys(scenarios).map((name) => [name, values(`job_latency{publisher:${name}}`)])),
    dropped: values('dropped_iterations').count || 0,
  };
  return { stdout: `BENCH_SUMMARY ${JSON.stringify(summary)}\n` };
}
