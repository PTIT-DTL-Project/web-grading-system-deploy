import http from 'k6/http';
import encoding from 'k6/encoding';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';

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
const assignmentResultPath = (__ENV.STUDENT_ASSIGNMENT_RESULT_PATH || '/api/v1/results/student/assignment/{id}').replace('{id}', encodeURIComponent(assignmentId));

const authFailures = new Counter('read_api_auth_failures');
const requestFailures = new Counter('read_api_request_failures');
const refreshFailures = new Counter('token_refresh_failures');
const refreshUnavailable = new Counter('token_refresh_unavailable');
const flowSuccess = new Rate('read_api_iteration_success');
let authRejected = false;

// Access tokens issued by Keycloak for this realm live ~5 minutes, which is
// shorter than a load/stress run. Without a refresh, a VU gets HTTP 401 partway
// through and the whole run is invalid, so every entry may carry a refresh token
// that is exchanged before the access token expires.
// Review: 2026-11-21, load run 20261121T091619Z_82266 failed on expired tokens.
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

// Active session per VU: the access token is replaced in place after a refresh.
const sessions = {};
const missingRefreshWarned = {};

function claimsOf(token) {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    return JSON.parse(encoding.b64decode(parts[1], 'rawurl', 's'));
  } catch (_) {
    return null;
  }
}

function sessionForVu() {
  if (!sessions[__VU]) {
    const entry = tokens[(__VU - 1) % tokens.length];
    sessions[__VU] = { access: entry.access, refresh: entry.refresh };
  }
  return sessions[__VU];
}

function tokenEndpoint(session) {
  if (tokenUrlOverride) return tokenUrlOverride;
  const claims = claimsOf(session.access);
  const issuer = claims && typeof claims.iss === 'string' ? claims.iss.replace(/\/$/, '') : '';
  return issuer ? `${issuer}/protocol/openid-connect/token` : '';
}

function refreshSession(session) {
  const url = tokenEndpoint(session);
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

function currentToken() {
  const session = sessionForVu();
  const claims = claimsOf(session.access);
  const expiresIn = claims && typeof claims.exp === 'number' ? claims.exp - Math.floor(Date.now() / 1000) : null;
  // Refresh shortly before expiry; a token without a readable exp is used as-is
  // so a non-JWT test token still works for a short smoke run.
  if (expiresIn !== null && expiresIn < 60) {
    if (session.refresh) {
      if (!refreshSession(session)) refreshFailures.add(1);
    } else if (!missingRefreshWarned[__VU]) {
      // Warn once per VU. A short run can still finish before the token expires,
      // and a real expiry surfaces as read_api_auth_failures, so this is not counted
      // as a failure. Without refresh_token, only runs shorter than the token
      // lifetime are trustworthy.
      missingRefreshWarned[__VU] = true;
      refreshUnavailable.add(1);
      console.warn('access token near expiry and no refresh_token for this VU; a longer run will get HTTP 401.');
    }
  }
  return session.access;
}

const profiles = {
  smoke: {
    maxVUs: 1,
    scenario: { executor: 'shared-iterations', vus: 1, iterations: 1, maxDuration: '30s' },
  },
  load: {
    scenario: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 1 },
        { duration: '45s', target: 2 },
        { duration: '45s', target: 3 },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '5s',
    },
  },
  stress: {
    scenario: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 1 },
        { duration: '30s', target: 2 },
        { duration: '30s', target: 3 },
        { duration: '30s', target: 4 },
        { duration: '30s', target: 5 },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '5s',
    },
  },
  spike: {
    scenario: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 1 },
        { duration: '10s', target: 5 },
        { duration: '30s', target: 5 },
        { duration: '10s', target: 1 },
        { duration: '30s', target: 1 },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '5s',
    },
  },
};

if (!profiles[profile]) throw new Error(`PROFILE must be one of: ${Object.keys(profiles).join(', ')}`);
if (!baseUrl || !assignmentId) throw new Error('Set BASE_URL and ASSIGNMENT_ID.');
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(assignmentId)) {
  throw new Error('ASSIGNMENT_ID must be a canonical UUID.');
}
if (!Array.isArray(tokens) || tokens.some((token) => !token.access)
    || new Set(tokens.map((token) => token.access)).size !== tokens.length) {
  throw new Error('TOKENS_FILE must be a JSON array of non-empty, distinct bearer tokens.');
}
const requiredTokens = { smoke: 1, load: 3, stress: 5, spike: 5 }[profile];
if (tokens.length < requiredTokens) {
  throw new Error(`PROFILE=${profile} may start ${requiredTokens} VUs; provide that many distinct student tokens.`);
}

export const options = {
  scenarios: { read_api: profiles[profile].scenario },
  thresholds: {
    read_api_auth_failures: ['count==0'],
    read_api_request_failures: ['count==0'],
    token_refresh_failures: ['count==0'],
  },
};

function get(path, name) {
  const response = http.get(`${baseUrl}${path}`, {
    headers: { Authorization: `Bearer ${currentToken()}`, Accept: 'application/json' },
    tags: { endpoint: name },
  });
  if (response.status === 401 || response.status === 403) {
    authFailures.add(1);
    flowSuccess.add(false);
    authRejected = true;
    console.error(`${name} rejected token with HTTP ${response.status}; stop this VU.`);
    return false;
  }
  const ok = check(response, { [`${name} returns 200`]: (r) => r.status === 200 });
  if (!ok) requestFailures.add(1);
  return ok;
}

export default function () {
  if (authRejected) {
    sleep(1);
    return;
  }
  const listOk = get(assignmentListPath, 'student_assignment_list');
  if (!listOk || authRejected) {
    if (!authRejected) flowSuccess.add(false);
    return;
  }
  const detailOk = get(assignmentDetailPath, 'student_assignment_detail');
  if (!detailOk || authRejected) {
    if (!authRejected) flowSuccess.add(false);
    return;
  }
  const resultOk = get(assignmentResultPath, 'student_assignment_result');
  flowSuccess.add(resultOk);
  sleep(1);
}
