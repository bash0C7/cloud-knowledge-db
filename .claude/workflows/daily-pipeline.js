export const meta = {
  name: 'daily-pipeline',
  description: 'cloud-knowledge-db daily ingestion: bookmark read → preflight → 5 parallel sources → finish',
  phases: [
    { title: 'Inspect',   detail: 'Read bookmark to determine SINCE/BEFORE window' },
    { title: 'Preflight', detail: 'Host/ollama check, esa conflict check, mark_started all sources' },
    { title: 'Sources',   detail: 'Parallel fetch→import→esa for all 5 sources' },
    { title: 'Finish',    detail: 'mark_completed, record_run, db sync, notify' },
  ],
}

const REPO        = '/Users/bash/dev/src/github.com/bash0C7/cloud-knowledge-db'
const SOURCE_KEYS = ['aws_blog', 'gcp_blog', 'gws_blog', 'gitlab_blog', 'classmethod_blog']

// Stage 1: Read bookmark to determine SINCE/BEFORE
phase('Inspect')

const WINDOW_SCHEMA = {
  type: 'object',
  required: ['since', 'before'],
  properties: {
    since:  { type: 'string', description: 'YYYY-MM-DD — floor of last_completed_before across all sources' },
    before: { type: 'string', description: 'YYYY-MM-DD — today in JST' },
  },
}

const window = await agent(
  `Read the file ${REPO}/db/last_run.yml and compute the date window for the next pipeline run.

Steps:
1. Read ${REPO}/db/last_run.yml (use the Read tool or Bash cat — NOT sqlite3).
2. Find the minimum last_completed_before value across all of these source keys:
   aws_blog, gcp_blog, gws_blog, gitlab_blog, classmethod_blog.
   If a source is missing or has no last_completed_before, treat it as yesterday.
3. Get today's date in JST: run TZ=Asia/Tokyo date +%Y-%m-%d
4. Return JSON: { since: "<min last_completed_before>", before: "<today JST>" }`,
  { label: 'inspect:window', phase: 'Inspect', schema: WINDOW_SCHEMA }
)

if (!window) {
  log('ERROR: Could not read bookmark — aborting')
  return { status: 'error', reason: 'bookmark read failed' }
}

const { since, before } = window
log(`Window: SINCE=${since} BEFORE=${before}`)

// Stage 2: pipeline:start — preflight + mark_started all sources
phase('Preflight')

const START_SCHEMA = {
  type: 'object',
  required: ['status'],
  properties: {
    status:    { type: 'string', enum: ['ok', 'aborted', 'error'] },
    conflicts: { type: 'string', description: 'Serialized conflict JSON when status=aborted' },
  },
}

const startResult = await agent(
  `Run the pipeline:start rake task and return the result as JSON.

Working directory: ${REPO}
Command:
  cd ${REPO} && APP_ENV=production SINCE=${since} BEFORE=${before} bundle exec rake pipeline:start

Timeout: 300 seconds.

Result rules:
- If exit 0 and stdout contains "status":"ok"  → return { status: "ok" }
- If exit non-zero and stdout/stderr contains "aborted" → return { status: "aborted", conflicts: "<full abort output>" }
- Otherwise → return { status: "error" }`,
  { label: 'pipeline:start', phase: 'Preflight', schema: START_SCHEMA }
)

if (!startResult || startResult.status === 'aborted') {
  const conflicts = startResult?.conflicts || '(no detail)'
  log(`ABORTED: esa conflicts detected\n${conflicts}`)
  return {
    status:    'aborted',
    reason:    'esa conflict detected by pipeline:start',
    conflicts,
    since,
    before,
  }
}

if (!startResult || startResult.status === 'error') {
  log('ERROR: pipeline:start failed')
  return { status: 'error', reason: 'pipeline:start failed', since, before }
}

log('Preflight OK — starting parallel source agents')

// Stage 3: Fan out 5 parallel pipeline:source agents
phase('Sources')

const SOURCE_SCHEMA = {
  type: 'object',
  required: ['key', 'success'],
  properties: {
    key:     { type: 'string' },
    success: { type: 'boolean' },
    output:  { type: 'string', description: 'Last ~500 chars of rake output' },
  },
}

const sourceResults = await parallel(
  SOURCE_KEYS.map((key) => () =>
    agent(
      `Run the pipeline:source rake task for source "${key}" and return the result as JSON.

Working directory: ${REPO}
Command:
  cd ${REPO} && APP_ENV=production SOURCE=${key} SINCE=${since} BEFORE=${before} bundle exec rake pipeline:source

Timeout: 1800 seconds (30 minutes — esa summarization via ollama can be slow).

Result rules:
- If exit 0 → return { key: "${key}", success: true,  output: "<last 500 chars of stdout>" }
- If exit non-zero or exception → return { key: "${key}", success: false, output: "<error output>" }`,
      { label: `pipeline:source:${key}`, phase: 'Sources', schema: SOURCE_SCHEMA }
    )
  )
)

const completed = sourceResults.filter(r => r?.success).map(r => r.key)
const failed    = sourceResults.filter(r => r && !r.success).map(r => r.key)
const unknown   = SOURCE_KEYS.filter(k => !sourceResults.some(r => r?.key === k))

log(`Sources: completed=[${completed.join(',')}] failed=[${failed.join(',')}] unknown=[${unknown.join(',')}]`)

const allFailed = [...failed, ...unknown]

// Stage 4: pipeline:finish — mark_completed, record_run, db sync, notify
phase('Finish')

const FINISH_SCHEMA = {
  type: 'object',
  required: ['status'],
  properties: {
    status: { type: 'string' },
    output: { type: 'string' },
  },
}

const finishResult = await agent(
  `Run the pipeline:finish rake task and return the result as JSON.

Working directory: ${REPO}
Command:
  cd ${REPO} && APP_ENV=production COMPLETED=${completed.join(',')} FAILED=${allFailed.join(',')} SINCE=${since} BEFORE=${before} bundle exec rake pipeline:finish

Timeout: 120 seconds.

Result rules:
- If exit 0 → return { status: "ok",     output: "<last 500 chars of stdout>" }
- If exit non-zero → return { status: "failed", output: "<error output>" }`,
  { label: 'pipeline:finish', phase: 'Finish', schema: FINISH_SCHEMA }
)

const finalStatus = allFailed.length === 0 ? 'ok' : 'partial_failed'
log(`Pipeline complete: status=${finalStatus} completed=${completed.length}/${SOURCE_KEYS.length}`)

return {
  status:    finalStatus,
  since,
  before,
  completed,
  failed:    allFailed,
  finish:    finishResult?.status || 'unknown',
}
