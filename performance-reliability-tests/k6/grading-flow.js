import http from 'k6/http';
import encoding from 'k6/encoding';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const profile = __ENV.PROFILE || 'smoke';
const baseUrl = (__ENV.BASE_URL || '').replace(/\/$/, '');
const accessToken = (__ENV.ACCESS_TOKEN || '').trim();
const tokenFile = __ENV.TOKENS_FILE || '';
const rawTokenEntries = tokenFile ? JSON.parse(open(tokenFile)) : (accessToken ? [accessToken] : []);
const clientId = __ENV.KEYCLOAK_CLIENT_ID || 'web-grading-fe';
const tokenUrlOverride = __ENV.KEYCLOAK_TOKEN_URL || '';
const assignmentId = __ENV.ASSIGNMENT_ID || '';
const assignmentListPath = __ENV.STUDENT_ASSIGNMENTS_PATH || '/api/v1/student/assignments?page=0&size=20';
const assignmentDetailPath = (__ENV.ASSIGNMENT_DETAIL_PATH || '/api/v1/student/assignments/{id}').replace('{id}', encodeURIComponent(assignmentId));
const zipPath = __ENV.ZIP_PATH || '';
const resultPathTemplate = __ENV.SUBMISSION_RESULT_PATH || '/api/v1/results/{id}';
const submissionPathTemplate = __ENV.SUBMISSION_PATH || '/api/v1/submissions/{id}';
const pollingIntervalMs = Number(__ENV.POLL_INTERVAL_MS || 3000);
const gradingTimeoutMs = Number(__ENV.GRADING_TIMEOUT_MS || 600000);
const resultTimeoutMs = Number(__ENV.RESULT_TIMEOUT_MS || 60000);
const zipBytes = zipPath ? open(zipPath, 'b') : null;
const zipFileName = zipPath ? zipPath.split('/').pop() : '';

const submissionToTerminal = new Trend('submission_to_terminal_seconds');
const submissionToResult = new Trend('submission_to_result_seconds');
const authFailures = new Counter('api_auth_failures');
const apiRequestFailures = new Counter('api_request_failures');
const presignFailures = new Counter('presign_failures');
const uploadFailures = new Counter('upload_failures');
const gradingFailures = new Counter('grading_failures');
const gradingTimeouts = new Counter('grading_timeouts');
const missingResults = new Counter('missing_result_after_terminal');
const refreshFailures = new Counter('token_refresh_failures');
const refreshUnavailable = new Counter('token_refresh_unavailable');
const flowSuccess = new Rate('grading_flow_success');

// A grading flow polls for up to 10 minutes while Keycloak access tokens live ~5
// minutes, so the token must be refreshed mid-run. Entries may be a token string
// or {access_token, refresh_token}.
// Review: 2026-11-21, read-load run proved tokens expire during multi-minute runs.
function normalizeEntry(entry, index) {
  if (typeof entry === 'string') {
    return { access: entry.trim(), refresh: '' };
  }
  if (entry && typeof entry === 'object') {
    return {
      access: typeof entry.access_token === 'string' ? entry.access_token.trim() : '',
      refresh: typeof entry.refresh_token === 'string' ? entry.refresh_token.trim() : '',
    };
  }
  throw new Error(
    `TOKENS_FILE entry ${index + 1} must be a token string or an object with access_token and refresh_token.`,
  );
}

const tokens = rawTokenEntries.map(normalizeEntry);
const session = { access: '', refresh: '' };
let missingRefreshWarned = false;

function claimsOf(token) {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    return JSON.parse(encoding.b64decode(parts[1], 'rawurl', 's'));
  } catch (_) {
    return null;
  }
}

function refreshSession() {
  const url = tokenUrlOverride
    || (() => {
      const claims = claimsOf(session.access);
      const issuer = claims && typeof claims.iss === 'string' ? claims.iss.replace(/\/$/, '') : '';
      return issuer ? `${issuer}/protocol/openid-connect/token` : '';
    })();
  if (!session.refresh || !url) return false;
  const response = http.post(
    url,
    { grant_type: 'refresh_token', client_id: clientId, refresh_token: session.refresh },
    { tags: { endpoint: 'token_refresh' } },
  );
  if (response.status !== 200) return false;
  let body = null;
  try {
    body = response.json();
  } catch (_) {
    return false;
  }
  if (!body || typeof body.access_token !== 'string' || !body.access_token) return false;
  session.access = body.access_token;
  if (typeof body.refresh_token === 'string' && body.refresh_token) {
    session.refresh = body.refresh_token;
  }
  return true;
}

const profiles = {
  smoke: {
    executor: 'shared-iterations',
    vus: 1,
    iterations: 1,
    maxDuration: '15m',
  },
};

if (!profiles[profile]) {
  throw new Error(`grading-flow.js only supports PROFILE=smoke; use api-read-load.js for read-load profiles.`);
}
if (!baseUrl || !assignmentId || !zipPath) {
  throw new Error('Set BASE_URL, ASSIGNMENT_ID and ZIP_PATH.');
}
if (!Array.isArray(tokens) || tokens.some((token) => !token.access)
    || new Set(tokens.map((token) => token.access)).size !== tokens.length) {
  throw new Error('TOKENS_FILE must be a JSON array of non-empty, distinct bearer tokens.');
}
if (tokens.length < 1) {
  throw new Error('Provide ACCESS_TOKEN or a TOKENS_FILE with one distinct student token for the smoke run.');
}
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(assignmentId)) {
  throw new Error('ASSIGNMENT_ID must be a canonical UUID.');
}
if (!zipBytes || zipBytes.length === 0 || !zipFileName.toLowerCase().endsWith('.zip')) {
  throw new Error('ZIP_PATH must point to a readable, non-empty .zip file.');
}

export const options = {
  scenarios: {
    grading_flow: profiles[profile],
  },
  thresholds: {
    api_auth_failures: ['count==0'],
    api_request_failures: ['count==0'],
    grading_flow_success: ['rate==1'],
    presign_failures: ['count==0'],
    upload_failures: ['count==0'],
    grading_failures: ['count==0'],
    grading_timeouts: ['count==0'],
    missing_result_after_terminal: ['count==0'],
    token_refresh_failures: ['count==0'],
  },
};

let authRejected = false;

function currentToken() {
  if (!session.access) {
    const entry = tokens.length ? tokens[(__VU - 1) % tokens.length] : null;
    session.access = entry ? entry.access : accessToken;
    session.refresh = entry ? entry.refresh : '';
  }
  const claims = claimsOf(session.access);
  const expiresIn = claims && typeof claims.exp === 'number' ? claims.exp - Math.floor(Date.now() / 1000) : null;
  if (expiresIn !== null && expiresIn < 60) {
    if (session.refresh) {
      if (!refreshSession()) refreshFailures.add(1);
    } else if (!missingRefreshWarned) {
      missingRefreshWarned = true;
      refreshUnavailable.add(1);
      console.warn('access token near expiry and no refresh_token; a long grading run will get HTTP 401.');
    }
  }
  return session.access;
}

function apiParams() {
  return {
    headers: {
      Authorization: `Bearer ${currentToken()}`,
      Accept: 'application/json',
    },
    tags: { component: 'grading-flow-api' },
  };
}

function parseBody(response) {
  try {
    const body = response.json();
    return body && Object.prototype.hasOwnProperty.call(body, 'data') ? body.data : body;
  } catch (_) {
    return null;
  }
}

function observeAuth(response) {
  if (response.status === 401 || response.status === 403) {
    authRejected = true;
    authFailures.add(1);
    flowSuccess.add(false);
    console.error(`API authorization rejected (HTTP ${response.status}); this VU will stop issuing requests.`);
    return false;
  }
  return true;
}

function failFlow(counter, message) {
  counter.add(1);
  flowSuccess.add(false);
  console.error(message);
}

export default function () {
  // Keep each VU to one real submission; ramping-vus otherwise loops and floods the grader.
  if (__ITER > 0) {
    sleep(Math.max(1, gradingTimeoutMs / 1000));
    return;
  }
  if (authRejected) {
    sleep(1);
    return;
  }

  const assignments = http.get(`${baseUrl}${assignmentListPath}`, apiParams());
  if (!observeAuth(assignments)) return;
  const assignmentsOk = check(assignments, {
    'student assignment list returns 200': (r) => r.status === 200,
    'student assignment list returns JSON': (r) => parseBody(r) !== null,
  });
  if (!assignmentsOk) {
    failFlow(apiRequestFailures, `Student assignment list failed (HTTP ${assignments.status}).`);
    return;
  }

  const assignmentDetail = http.get(`${baseUrl}${assignmentDetailPath}`, apiParams());
  if (!observeAuth(assignmentDetail)) return;
  if (!check(assignmentDetail, { 'student can read target assignment': (r) => r.status === 200 })) {
    failFlow(apiRequestFailures, `Target assignment is not available to this student (HTTP ${assignmentDetail.status}).`);
    return;
  }

  const presignUrl = `${baseUrl}/api/v1/submissions/presigned-url?assignmentId=${encodeURIComponent(assignmentId)}&zipFileName=${encodeURIComponent(zipFileName)}`;
  const presign = http.post(presignUrl, null, apiParams());
  if (!observeAuth(presign)) return;

  const presignOk = check(presign, {
    'presigned URL request returns 201': (r) => r.status === 201,
  });
  const uploadData = parseBody(presign);
  if (!presignOk || !uploadData || !uploadData.uploadUrl || !uploadData.submissionId) {
    failFlow(presignFailures, `Could not obtain upload URL (HTTP ${presign.status}).`);
    return;
  }

  const submissionId = uploadData.submissionId;
  console.log(`submission_id=${submissionId}`);
  const gradingStartedAt = Date.now();
  const upload = http.put(uploadData.uploadUrl, zipBytes, {
    headers: { 'Content-Type': 'application/zip' },
    tags: { component: 'rustfs-upload' },
  });
  const uploadOk = check(upload, {
    'zip upload returns 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  if (!uploadOk) {
    failFlow(uploadFailures, `Zip upload failed (HTTP ${upload.status}) for submission ${submissionId}.`);
    return;
  }

  const gradingDeadline = gradingStartedAt + gradingTimeoutMs;
  let terminalStatus = null;
  while (Date.now() < gradingDeadline) {
    const submissionPath = submissionPathTemplate.replace('{id}', encodeURIComponent(submissionId));
    const response = http.get(`${baseUrl}${submissionPath}`, apiParams());
    if (!observeAuth(response)) return;
    const submission = parseBody(response);
    if (response.status !== 200 || !submission || !submission.status) {
      failFlow(apiRequestFailures, `Could not read submission status (HTTP ${response.status}) for ${submissionId}.`);
      return;
    }
    if (submission.status === 'DONE' || submission.status === 'FAILED') {
      terminalStatus = submission.status;
      break;
    }
    sleep(pollingIntervalMs / 1000);
  }

  if (!terminalStatus) {
    gradingTimeouts.add(1);
    flowSuccess.add(false);
    console.error(`Submission ${submissionId} did not reach DONE/FAILED within ${gradingTimeoutMs} ms.`);
    return;
  }

  submissionToTerminal.add((Date.now() - gradingStartedAt) / 1000);
  if (terminalStatus === 'FAILED') {
    gradingFailures.add(1);
    flowSuccess.add(false);
    console.error(`Grading reached FAILED for submission ${submissionId}.`);
  }

  let resultsAvailable = false;
  const resultDeadline = Date.now() + resultTimeoutMs;
  while (Date.now() < resultDeadline) {
    const resultPath = resultPathTemplate.replace('{id}', encodeURIComponent(submissionId));
    const response = http.get(`${baseUrl}${resultPath}`, apiParams());
    if (!observeAuth(response)) return;
    const results = parseBody(response);
    if (response.status !== 200) {
      failFlow(missingResults, `Result lookup failed (HTTP ${response.status}) for ${submissionId}.`);
      return;
    }
    if (Array.isArray(results) && results.length > 0) {
      resultsAvailable = true;
      break;
    }
    sleep(pollingIntervalMs / 1000);
  }

  if (!resultsAvailable) {
    missingResults.add(1);
    flowSuccess.add(false);
    console.error(`No result row became visible for terminal submission ${submissionId}.`);
    return;
  }

  submissionToResult.add((Date.now() - gradingStartedAt) / 1000);
  if (terminalStatus === 'DONE') flowSuccess.add(true);
}
