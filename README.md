# StackPort AI

StackPort AI is a Manifest V3 Chrome side-panel extension backed by a Node 20 / Express service. It uploads project ZIPs directly to Google Cloud Storage, then uses Gemini to analyze, plan, convert, validate, and package a target-stack project. Large archives never pass through the Express request body.

## Architecture

- `extension/` — Vite, React, TypeScript, Tailwind, JSZip, MV3 side panel.
- `backend/` — strict TypeScript API, Cloud Storage, Firestore/in-memory job store, Gemini pipeline.
- `shared/` — shared stack IDs, job states, and API contracts.
- GCS stores uploads/results; Firestore persists production job state. Local development uses in-memory jobs.
- The backend rejects unsafe ZIP paths, symlinks, excessive file counts, and excessive expanded size. Conversion failures are recorded in the report while other files continue.

## Requirements

- Node.js 20+ and npm 10+
- Google Cloud project with billing and the Cloud Run, Cloud Build, Cloud Storage, Firestore, and Secret Manager APIs enabled for deployment.
- Gemini API key stored in Secret Manager for deployment. For local work, put it in `.env` (never commit it).

## Local setup

1. Copy `.env.example` to `.env`; set `GEMINI_API_KEY` and `GCS_BUCKET` to a bucket you control. The local backend uses in-memory job state but still uses GCS for signed uploads and result downloads.
2. Install and build shared contracts: `npm install`, then `npm run build --workspace @stackport/shared`.
3. Start the API: `npm run dev --workspace @stackport/backend`. It listens on `http://localhost:8080`. `/health` is available for a health check.
4. Build the side panel with `npm run build --workspace @stackport/extension`. Set `VITE_API_URL` before building if the API is not at `http://localhost:8080`.
5. In Chrome, open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select `extension/dist`. Click the StackPort toolbar icon to open the side panel.

The extension removes `node_modules`, `.git`, and `dist` when it builds or cleans an archive. ZIPs over 100 MB are rejected. The Prompt API summary is optional, feature-detected, and stays on-device.

### Local extension origin/CORS

The default `.env.example` CORS origin accepts Chrome extension origins during local development. For a production deployment, set `CORS_ORIGIN` to the exact extension origin, `chrome-extension://<extension-id>`. An unpacked extension ID can change if its key changes. The extension's manifest allows the default local backend, Cloud Run `*.run.app`, and GCS signed URLs. For a custom API domain, add that domain to `extension/public/manifest.json` `host_permissions` before building.

### Run tests

```powershell
npm test
npm run build
```

The backend tests cover ZIP extraction safety/limits, stack detection, and migration-plan validation.

## Environment variables

| Variable | Required | Default | Description |
|---|---:|---|---|
| `PORT` | No | `8080` | HTTP port |
| `NODE_ENV` | No | `development` | `production` selects Firestore; other values use in-memory jobs |
| `GEMINI_API_KEY` | Yes for conversion | — | Gemini API key; use Secret Manager in deployed environments |
| `GEMINI_PLANNER_MODEL` | No | `gemini-2.5-pro` | Analyze/plan model |
| `GEMINI_CONVERTER_MODEL` | No | `gemini-2.5-flash` | Per-file conversion and repair model |
| `GCS_BUCKET` | Yes | — | Private bucket used for uploads and results |
| `CORS_ORIGIN` | No | `chrome-extension://*` | Comma-separated exact allowed origins; wildcard extension form is only used for local dev |
| `FIRESTORE_COLLECTION` | No | `stackportJobs` | Firestore collection name |
| `MAX_UPLOAD_BYTES` | No | `104857600` | Maximum uploaded ZIP bytes |
| `MAX_FILES` | No | `10000` | Maximum archive entries |
| `MAX_UNCOMPRESSED_BYTES` | No | `524288000` | Maximum expanded archive size |
| `SIGNED_URL_TTL_MINUTES` | No | `15` | V4 upload URL lifetime |
| `VITE_API_URL` | No | `http://localhost:8080` | Extension build-time backend URL |

## API

- `GET /health`
- `POST /uploads/sign` — `{ "fileName": "project.zip", "contentType": "application/zip" }` returns `{ "uploadUrl", "objectPath" }`.
- `POST /jobs` — `{ "objectPath", "sourceStack", "targetStack", "localSummary?" }` returns `{ "jobId" }`; pipeline processing is asynchronous.
- `GET /jobs/:id` — status, stage, percent, current file, logs, result URL, and error when applicable.

## Google Cloud deployment

Set shell variables first. Replace project, bucket, region, extension ID, and service-account names with your own values. The bucket is private; only short-lived signed URLs grant upload/download access.

```powershell
$PROJECT_ID = "your-gcp-project"
$REGION = "us-central1"
$BUCKET = "$PROJECT_ID-stackport"
$EXTENSION_ID = "your-published-extension-id"
$RUNTIME_SA = "stackport-runtime@$PROJECT_ID.iam.gserviceaccount.com"
$BUILD_SA = "stackport-build@$PROJECT_ID.iam.gserviceaccount.com"
$DEPLOYER = gcloud config get-value account
$PROJECT_NUMBER = gcloud projects describe $PROJECT_ID --format="value(projectNumber)"
gcloud config set project $PROJECT_ID
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com storage.googleapis.com firestore.googleapis.com secretmanager.googleapis.com
gcloud iam service-accounts create stackport-runtime --display-name "StackPort Cloud Run runtime"
gcloud iam service-accounts create stackport-build --display-name "StackPort Cloud Build deployer"
gcloud iam service-accounts add-iam-policy-binding $BUILD_SA --member="user:$DEPLOYER" --role="roles/iam.serviceAccountUser"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$BUILD_SA" --role="roles/cloudbuild.builds.builder"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$BUILD_SA" --role="roles/run.admin"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$BUILD_SA" --role="roles/artifactregistry.writer"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$BUILD_SA" --role="roles/logging.logWriter"
gcloud iam service-accounts add-iam-policy-binding $RUNTIME_SA --member="serviceAccount:$BUILD_SA" --role="roles/iam.serviceAccountUser"
gcloud iam service-accounts add-iam-policy-binding $BUILD_SA --member="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-cloudbuild.iam.gserviceaccount.com" --role="roles/iam.serviceAccountTokenCreator"
gcloud artifacts repositories create stackport --repository-format=docker --location=$REGION --description="StackPort backend images"
gcloud storage buckets create "gs://$BUCKET" --location=$REGION --uniform-bucket-level-access
gcloud storage buckets update "gs://$BUCKET" --cors-file=gcs-cors.json
gcloud storage buckets update "gs://$BUCKET" --lifecycle-file=gcs-lifecycle.json
gcloud firestore databases create --location=$REGION --type=firestore-native
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$RUNTIME_SA" --role="roles/storage.objectAdmin"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$RUNTIME_SA" --role="roles/datastore.user"
gcloud secrets create gemini-api-key --replication-policy=automatic
Read-Host "Paste the Gemini API key" -AsSecureString | ForEach-Object { $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($_); try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) | gcloud secrets versions add gemini-api-key --data-file=- } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } }
gcloud secrets add-iam-policy-binding gemini-api-key --member="serviceAccount:$RUNTIME_SA" --role="roles/secretmanager.secretAccessor"
gcloud builds submit --config=cloudbuild.yaml --service-account="projects/$PROJECT_ID/serviceAccounts/$BUILD_SA" --substitutions="_REGION=$REGION,_BUCKET=$BUCKET,_CORS_ORIGIN=chrome-extension://$EXTENSION_ID,_RUNTIME_SA=$RUNTIME_SA"
$API_URL = gcloud run services describe stackport-backend --region=$REGION --format="value(status.url)"
$env:VITE_API_URL = $API_URL
npm run build --workspace @stackport/extension
```

The runtime service account also needs permission to sign GCS URLs. On Compute Engine/Cloud Run credentials, grant the runtime service account `roles/iam.serviceAccountTokenCreator` on the service account whose credentials sign URLs (usually itself):

```powershell
gcloud iam service-accounts add-iam-policy-binding $RUNTIME_SA --member="serviceAccount:$RUNTIME_SA" --role="roles/iam.serviceAccountTokenCreator"
```

The commands above grant the build service account permissions to build/push to Artifact Registry and deploy, and authorize it to attach the runtime identity. The identity running `gcloud builds submit` must also be allowed to use `$BUILD_SA` (grant it `roles/iam.serviceAccountUser` on that service account).

Cloud Run is configured for 2 GiB memory, a 900-second request timeout, concurrency 10, and CPU available outside request handling so the asynchronous pipeline can run. Firestore must be initialized in Native mode. The supplied lifecycle JSON deletes uploaded and result objects after 24 hours.

### CORS / extension ID

Before applying `gcs-cors.json`, replace `REPLACE_WITH_EXTENSION_ID` with the actual extension ID. The `CORS_ORIGIN` substitution passed during deploy must likewise be the exact `chrome-extension://<id>` origin. For local side-panel development, the extension's origin must be explicitly permitted if you use a non-wildcard production setting.

## Troubleshooting

- **CORS or network error:** confirm the deployed `CORS_ORIGIN`, bucket CORS origins, extension ID, and manifest host permissions all match the extension and backend URLs.
- **Signing URL error:** verify the runtime identity has `roles/storage.objectAdmin` and `roles/iam.serviceAccountTokenCreator`, the bucket exists, and Application Default Credentials are available locally.
- **Gemini 401/403 or quota errors:** verify the Secret Manager version and Gemini API access. The converter retries transient errors and 429s with exponential backoff; persistent rate limits fail the affected file and appear in the report.
- **Archive rejected:** remove encrypted/corrupt archives, symbolic links, traversal paths, or projects exceeding the entry/expanded-size limits.
- **Extension reports missing host permission:** update `host_permissions` in the manifest for your backend domain and rebuild/reload the unpacked extension.
- **Conversion has manual review items:** open `CONVERSION_REPORT.md`; the pipeline preserves successful files and records failed files and remaining validation issues rather than treating AI output as production-verified.

## Security notes

The service never accepts archives in Express request bodies. Signed upload URLs are short-lived and scoped to one random object path. Uploaded projects are untrusted data and are not executed. The extractor guards traversal, symlinks, entry count, and expanded bytes. Conversion archives and results should still be treated as potentially sensitive; the 24-hour lifecycle rule is the cleanup backstop.
