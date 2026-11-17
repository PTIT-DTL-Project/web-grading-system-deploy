import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const profile = __ENV.PROFILE || 'smoke';
const baseUrl = (__ENV.BASE_URL || '').replace(/\/$/, '');
const accessToken = __ENV.ACCESS_TOKEN || '';
const tokenFile = __ENV.TOKENS_FILE || '';
const tokens = tokenFile ? JSON.parse(open(tokenFile)) : (accessToken ? [accessToken] : []);
const assignmentId = __ENV.ASSIGNMENT_ID || '';
const assignmentListPath = __ENV.STUDENT_ASSIGNMENTS_PATH || '/api/v1/student/assignments?page=0&size=20';
const assignmentDetailPath = (__ENV.ASSIGNMENT_DETAIL_PATH || '/api/v1/student/assignments/{id}').replace('{id}', encodeURIComponent(assignmentId));
const assignmentResultPath = (__ENV.STUDENT_ASSIGNMENT_RESULT_PATH || '/api/v1/results/student/assignment/{id}').replace('{id}', encodeURIComponent(assignmentId));

const authFailures = new Counter('read_api_auth_failures');
const requestFailures = new Counter('read_api_request_failures');
const flowSuccess = new Rate('read_api_iteration_success');
let authRejected = false;

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
if (!Array.isArray(tokens) || tokens.some((token) => typeof token !== 'string' || token.trim() === '')
    || new Set(tokens).size !== tokens.length) {
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
  },
};

function tokenForVu() {
  return tokens[(__VU - 1) % tokens.length];
}

function get(path, name) {
  const response = http.get(`${baseUrl}${path}`, {
    headers: { Authorization: `Bearer ${tokenForVu()}`, Accept: 'application/json' },
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
