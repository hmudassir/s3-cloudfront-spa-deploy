# S3 + CloudFront setup for a single-page app

A one-time setup that the deploy scripts assume.

## Bucket

Create an S3 bucket and keep **Block all public access** turned on. Visitors never reach the bucket directly; only CloudFront reads it.

## Distribution

1. **Origin:** the bucket itself (`<bucket>.s3.<region>.amazonaws.com`), not the S3 website endpoint.
2. **Origin access control (OAC):** create one and apply the bucket policy CloudFront offers, so only this distribution can read the bucket.
3. **Viewer protocol policy:** redirect HTTP to HTTPS.
4. **Default root object:** `index.html`.

## Routing for client-side URLs

A link like `/articles/42` has no file in the bucket. Add two **custom error responses**:

| HTTP error code | Response page path | Response code | Error caching TTL |
| --- | --- | --- | --- |
| 403 | `/index.html` | 200 | 0 |
| 404 | `/index.html` | 200 | 0 |

A private bucket answers 403 (not 404) for missing keys, which is why both are needed.

## Deploy credentials

Create an IAM user (or role) for deploying and attach [`iam/deploy-policy.json`](../iam/deploy-policy.json) with your bucket, account ID and distribution ID filled in. It can read and write site files and refresh this one distribution, and nothing else. Configure it with `aws configure`.

## Caching, as the scripts apply it

| Files | Cache-Control | Why |
| --- | --- | --- |
| Hashed assets (`app-3f9c2a1b.js`) | `public,max-age=31536000,immutable` | The name changes whenever the content does |
| `index.html`, `version.json` | `no-cache` | Must point at the newest assets |
| `FRESH_DIRS` (e.g. `data/`) | `no-cache` | Content that changes under the same name |

After each upload the scripts invalidate `/`, `/index.html`, `/version.json` and each `FRESH_DIRS/*` path. Hashed assets never need invalidating.
