# RustFS (object storage)

S3-compatible storage backing submission ZIP uploads via presigned URLs.
Deployed manually with `deploy/install-rustfs.sh` — ArgoCD does **not** manage
RustFS (it only manages the 5 microservices), so always commit manifest changes.

## Browser CORS for presigned uploads

The FE uploads ZIPs with a browser `PUT` straight to the presigned URL, so the
S3 API listener must allow the web origin. Otherwise preflight `OPTIONS` returns
no `Access-Control-Allow-Origin` and the browser blocks the PUT — while CI stays
green, because this failure only happens in a browser.

### Format rules (`RUSTFS_CORS_ALLOWED_ORIGINS`)

- Comma-separated list of **exact** origins: scheme + host, no spaces, no
  trailing slash.
- Never `"*"`: wildcard disables credentialed requests and is flagged by the
  RustFS reflective-CORS advisory. Keep a narrow allowlist.
- `RUSTFS_CONSOLE_CORS_ALLOWED_ORIGINS` is a separate variable for the console
  listener — uploads go through the S3 API listener, so leave it alone.
- Reference: https://docs.rustfs.com/en/administration/cors

### Adding a new web origin

1. Append the origin in `deployment.yaml` (`RUSTFS_CORS_ALLOWED_ORIGINS`).
2. Apply: `kubectl apply -n web-grading -f deploy/rustfs/deployment.yaml`
   (or re-run `deploy/install-rustfs.sh`). The changed pod template triggers a
   rolling restart automatically — RustFS reads this variable at startup.
3. Verify preflight against the public S3 endpoint:

```bash
curl -i -X OPTIONS \
  'https://web-dev1-rustfs-api.vucongtuanduong.dpdns.org/<bucket>/<key>' \
  -H 'Origin: https://web-dev1-fe.vucongtuanduong.dpdns.org' \
  -H 'Access-Control-Request-Method: PUT'
```

Expect `Access-Control-Allow-Origin: https://web-dev1-fe.vucongtuanduong.dpdns.org`.
Repeat with an unlisted origin and confirm it is **not** allowed.

4. Submit a real file end-to-end from the new hostname.
