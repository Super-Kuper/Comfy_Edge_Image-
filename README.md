# Image Serverless — ComfyUI worker for FLUX.2 klein / Qwen-Image-Edit

RunPod serverless worker for the video_gen **keyframe** step. It runs ComfyUI
v0.44.0 on one 48 GB image GPU, executes a **prepared ComfyUI API graph** built
by the video_gen catalog, and returns the generated image plus execution-fact
telemetry. It does not build or modify the graph, does not ship model weights and
keeps ComfyUI on loopback only. Contract: **`image-serverless/v1`** —
[`contract/worker-contract.md`](contract/worker-contract.md).

Image models on the stand (both Apache-2.0, commercial use allowed):

| Model | Mode | Files |
|---|---|---|
| FLUX.2 klein 4B | t2i (generate) | diffusion model + Qwen3-4B text encoder + FLUX.2 VAE |
| Qwen-Image-Edit-2511 | edit (instruction + optional mask) и i2i (style-reference init image) | fp8mixed diffusion model + Qwen2.5-VL text encoder + Qwen-Image VAE |

## Deploy

1. **Storage first.** Create a network volume of at least **60 GB**
   (100 GB recommended) in a datacenter that offers 48 GB image GPUs
   (`AMPERE_48` — RTX A6000/A40, `ADA_48_PRO` — L40S/L40/RTX 6000 Ada). The
   pinned model set is ~46.3 GB; the volume also holds future models.
2. **Deploy the worker.** Publish this repository as a GitHub release to
   [RunPod Hub](https://console.runpod.io/hub) (metadata:
   [`.runpod/hub.json`](.runpod/hub.json) — `AMPERE_48,ADA_48_PRO`,
   CUDA 13.0–13.4, 40 GB container disk), or build the image and create a
   serverless endpoint yourself.
3. **Attach the volume** at `/runpod-volume`, use endpoint type **`QUEUE`**,
   **Max workers = 1–2**, idle timeout short (for example 5–10 s) and endpoint
   timeout **600–900 s** (the worker's `JOB_TIMEOUT_SECONDS` must be less than or
   equal to it). One warm worker that already loaded the model beats several
   cold ones; a second worker only helps for queued bursts.
4. **Wait for the first boot.** With `VOLUME_AUTOPOPULATE=true` (default) the
   container downloads missing files from
   [`models-manifest.txt`](models-manifest.txt) into
   `/runpod-volume/models`; later boots reuse the volume.
5. **Smoke-test** with the health action (see [Health](#health)); RunPod Hub runs
   this test on build ([`.runpod/tests.json`](.runpod/tests.json)).
6. **Keep secrets in the endpoint environment only** (`S3_*` for large results,
   optional `HF_TOKEN` for gated Hugging Face mirrors).

### Requirements

| Item | Requirement |
|---|---|
| GPU | 48 GB recommended: L40S (`ADA_48_PRO`) primary, RTX A6000 (`AMPERE_48`) cheap fallback. 32 GB works with fp8mixed on Qwen-Image-Edit-2511 but leaves little headroom; 24 GB is not supported by this manifest. |
| CUDA, endpoint | The image is built on a CUDA 13.0 ComfyUI base pinned by digest (see [Dockerfile](Dockerfile)). Host drivers must support CUDA 13.0 (13.0–13.4 are accepted by the Hub metadata). If the chosen 48 GB pool only advertises CUDA 12.x drivers, rebuild on a CUDA 12.x ComfyUI base and re-pin the digest + `.runpod/hub.json` `allowedCudaVersions`. |
| Network volume | at least 60 GB at `/runpod-volume` (100 GB recommended) |
| Registry | The built image must be available to RunPod (Hub build or your registry) |
| ComfyUI core | Image models are served by ComfyUI core nodes; the image installs no custom-node packages. |

## Build the image

The root [Dockerfile](Dockerfile) builds on the official ComfyUI v0.44.0
CUDA 13.0 image pinned by digest and adds the worker package, `handler.py` and
the volume scripts.

```bash
docker build -t <registry>/image-serverless:1.1.0 .
docker push <registry>/image-serverless:1.1.0
```

Structural build without ComfyUI or a GPU (checks that the Dockerfile, package
and scripts are wired; not meant to run):

```bash
docker build --build-arg BASE_IMAGE=python:3.12-slim \
  --build-arg SKIP_COMFY_PACKAGES=1 -t image-serverless:stub .
docker run --rm --entrypoint python image-serverless:stub -c "import image_worker"
```

Optional build args: `IMAGE_WORKER_VERSION` (`1.1.0`), `COMFYUI_VERSION`
(`v0.44.0`), `BASE_IMAGE`. Pin by digest:
`docker inspect --format='{{index .RepoDigests 0}}' <image>`.

## Job input

Submit to the endpoint's `/run` API; minimal shape (abbreviated graph):

```json
{
  "input": {
    "prompt": {"1": {"class_type": "UNETLoader", "inputs": {"unet_name": "flux-2-klein-4b.safetensors"}}},
    "parameter": {"mode": "generate", "width": 768, "height": 1344, "seed": 20261113},
    "acceleration": {"gpu_class": "RTX A6000"}
  }
}
```

| Field | Description |
|---|---|
| `prompt` | Complete ComfyUI API graph (node id to `{class_type, inputs}`), submitted unchanged. Required unless `action` is `health`. |
| `parameter` / `acceleration` | Generation and acceleration snapshots: tracing only. The worker never builds the graph from them and never substitutes their values for measured telemetry. |
| `assets` | Optional input files as presigned URLs `{name, url, sha256?, kind?, size?}`, downloaded into ComfyUI's input directory under `name`; the graph references those names. |
| `action` | `"health"` runs a model-free health check; no prompt needed. |
| `policy` | Optional RunPod policy; the worker does not read it. |

More examples: [`request.json`](contract/examples/request.json) (t2i),
[`request-edit.json`](contract/examples/request-edit.json) (edit with base image
and mask), [`request-i2i.json`](contract/examples/request-i2i.json) (i2i:
style-reference image as init image). The graphs there are illustrative: they
show the required shape and the node facts the worker measures; the actual
templates live in the `image_models` catalog.

### Edit assets

The edit graph expects the base image and the mask under the exact names sent in
`assets`:

```json
"assets": [
  {"name": "base.png", "url": "https://.../base.png", "sha256": "...", "kind": "image", "size": 184320},
  {"name": "mask.png", "url": "https://.../mask.png", "sha256": "...", "kind": "mask", "size": 18432}
]
```

The application chooses the names (the service uses `asset_<sha16>.png`); the
graph template must reference exactly those names in `LoadImage` /
`LoadImageMask`. The examples above use short illustrative names. The worker
verifies `sha256`/size, writes the files atomically and never uploads the edit
result over the source asset (the application stores the new variant).

### i2i / style reference

The same assets mechanism covers image-to-image: the application sends a style
reference image as an `image` asset, the graph loads it with `LoadImage`, scales
it to the target canvas (`ImageScale`), encodes it with `VAEEncode` and samples
with a partially denoised latent (`KSampler.denoise` below `1.0`). For
Qwen-Image-Edit the conditioning comes from `TextEncodeQwenImageEdit` with the
same image input, so the prompt describes the new scene while the reference
supplies palette, light and texture. See
[`request-i2i.json`](contract/examples/request-i2i.json).

This is core ComfyUI nodes only: the image needs no new custom-node package or
weights for i2i, and `docker/install-comfy-packages.sh` verifies
`LoadImage`, `ImageScale`, `VAEEncode` and `TextEncodeQwenImageEdit` at build
time. A style reference is an **input**, not a generation result: it is attached
only when the catalog model declares `capabilities.style_reference` and the
graph template contains the `{{style_reference}}` placeholder. The denoise
strength is a model default; if it is too low the output keeps too much of the
reference composition, if too high the style drifts — smoke-test it on the
stand before setting `tested_at`.

## Job output

```json
{
  "image": "<base64 png>",
  "telemetry": {
    "gpu_cc": 8.6, "gpu_class": "RTX A6000", "seconds": 7.4,
    "width": 768, "height": 1344, "model_name": "flux-2-klein-4b.safetensors",
    "seed": 20261113, "steps": 4, "cfg": 1.0, "sampler": "euler", "scheduler": "simple"
  }
}
```

- Exactly one of `image` (base64, small results) or `image_url` (presigned URL,
  large results in S3-compatible storage) is returned.
- `telemetry` is always measured, never copied from `parameter`/`acceleration`:
  `gpu_cc`/`gpu_class` from `torch.cuda`; `seconds` from submit to completion;
  `width`/`height` from the produced file header; `model_name`, `seed`, `steps`,
  `cfg`, `sampler`, `scheduler` from the executed graph. Missing facts fail the
  job with `telemetry_missing`; disagreeing sampler/loader nodes fail with
  `telemetry_ambiguous`.
- `text_detected` (OCR) is **not reported**: the image has no OCR engine, so the
  field is omitted instead of a silent `false`. The application records the OCR
  fact itself (`keyframe_text_detected`).
- Exact minimum: [`contract/output.schema.json`](contract/output.schema.json);
  examples: [`response.json`](contract/examples/response.json),
  [`response-url.json`](contract/examples/response-url.json).

## Health

Request (`POST /run`): `{"input": {"action": "health"}}`

```json
{"status": "ok", "comfyui": "ready", "volume_mounted": true}
```

`status` is `ok`, `starting` (ComfyUI is still booting — normal after a cold
start) or `degraded` (volume missing and/or ComfyUI unavailable). Health never
loads a model or runs a graph.

## Errors and cancellation

A failed job ends as `FAILED`; the error text carries a stable code. An empty or
unreadable image is never a success.

| Group | Codes |
|---|---|
| Input/config | `input_invalid`, `input_prompt_missing`, `config_invalid` |
| Assets | `asset_invalid`, `asset_download_failed`, `asset_hash_mismatch`, `asset_too_large` |
| ComfyUI | `comfy_boot_timeout`, `comfy_submit_failed`, `comfy_execution_failed`, `comfy_timeout`, `comfy_output_missing` |
| Telemetry | `telemetry_missing`, `telemetry_ambiguous`, `gpu_unavailable` |
| Output | `output_empty`, `output_invalid`, `output_storage_missing`, `output_storage_failed` |

Cancelling a job interrupts the running graph in ComfyUI, so the GPU is not kept
busy. Keep the endpoint timeout at or above `JOB_TIMEOUT_SECONDS` (default 900).
Full contract: [`contract/worker-contract.md`](contract/worker-contract.md).

## Models on the network volume

Models are not shipped in the image. On first boot `populate-volume.sh`
downloads missing files from [`models-manifest.txt`](models-manifest.txt) into
`/runpod-volume/models/<subdir>/<file>`, the layout ComfyUI sees through
`extra_model_paths.yaml`. Every row is pinned to an immutable Hugging Face commit
and a sha256; `populate-volume.sh` rejects `main`/`master` and unpinned URLs with
a readable error. It also creates `/runpod-volume/custom_nodes` and
`/runpod-volume/encoder-cache` for future use.

| Volume path | Source | Size |
|---|---|---|
| `diffusion_models/flux-2-klein-4b.safetensors` | [Comfy-Org/Flux-2-Klein-4B](https://huggingface.co/Comfy-Org/Flux-2-Klein-4B) @ `5b3abca5` | 7.75 GB |
| `text_encoders/qwen_3_4b.safetensors` | same repository | 8.04 GB |
| `vae/flux2-vae.safetensors` | same repository | 0.34 GB |
| `diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors` | [Comfy-Org/Qwen-Image-Edit](https://huggingface.co/Comfy-Org/Qwen-Image-Edit) @ `f68ace85` | 20.53 GB |
| `text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors` | [Comfy-Org/Qwen-Image](https://huggingface.co/Comfy-Org/Qwen-Image) @ `1f12b17b` | 9.38 GB |
| `vae/qwen_image_vae.safetensors` | same repository | 0.25 GB |

Volume manifest and boot variables: `models-manifest.txt`; `VOLUME_AUTOPOPULATE`
(default `true`), `HF_TOKEN` (optional, gated repositories only) and
`HF_ENDPOINT` (optional mirror; the commit path is preserved). The download
target is `$VOLUME_ROOT/models`.

### Adding a new model (weights + image)

Adding a model is two independent changes: **weights on the volume** and a
**catalog row in video_gen**. Weights are never baked into the image; only the
manifest and code are, so a weight-only model usually needs one small image
rebuild.

1. **Pin the files.** Take the Hugging Face repo, a **commit SHA** (not
   `main`), and the LFS sha256 for every file the graph needs (diffusion model,
   text encoder, VAE, optional LoRA). Check the model license; the default
   `commercial_only` catalog mode only allows `commercial` licenses.
2. **Add rows to [`models-manifest.txt`](models-manifest.txt)** — tab-separated
   `<models subdir>\t<filename>\t<URL>\t<sha256>`:
   ```text
   diffusion_models	my_model_fp8.safetensors	https://huggingface.co/Org/Repo/resolve/<40-hex-commit>/split_files/diffusion_models/my_model_fp8.safetensors	<64-hex-sha256>
   text_encoders	my_encoder.safetensors	https://huggingface.co/Org/Repo/resolve/<40-hex-commit>/split_files/text_encoders/my_encoder.safetensors	<64-hex-sha256>
   vae	my_vae.safetensors	https://huggingface.co/Org/Repo/resolve/<40-hex-commit>/split_files/vae/my_vae.safetensors	<64-hex-sha256>
   ```
   Filenames must be exactly what the catalog graph references; do not overwrite
   an existing file with different weights — use a new filename and a new graph
   revision.
3. **Rebuild and republish the image.** `models-manifest.txt` is `COPY`-ed into
   the image, so:
   ```bash
   docker build -t <registry>/image-serverless:<new-tag> .
   docker push <registry>/image-serverless:<new-tag>
   ```
   Update the RunPod endpoint image/digest (and `.runpod/hub.json` if the base or
   CUDA range changes). Without a rebuild you can override the manifest at the
   endpoint: put the updated file on the volume and set
   `MANIFEST=/runpod-volume/models-manifest.txt`; this avoids an image build but
   moves the manifest out of image versioning — prefer the rebuild.
4. **Populate the volume.** With `VOLUME_AUTOPOPULATE=true` the next cold start
   downloads only the missing files (sha256-checked, `.tmp` + atomic rename, flock
   between workers). To avoid a long first job, run
   `populate-volume.sh` in a temporary CPU pod with the same volume:
   ```bash
   VOL_ROOT=/runpod-volume MANIFEST=/opt/image-worker/models-manifest.txt \
     bash /opt/image-worker/populate-volume.sh
   ```
   Check free space first: the current set is ~46 GB; adding a 20 GB edit model
   to a 60 GB volume needs a resize (network volumes can be grown, not shrunk).
5. **Register the model in video_gen** (`admin` → `Настройки → Модели
   изображений`, or `POST /studio/image-models`). Fill `graph` (API-format
   template + `revision` + `hash`), `model_files` (exact `name`/`path`/`sha256`),
   `defaults` (steps/cfg/sampler/scheduler/denoise/size), `capabilities`,
   `license`, `cost` and `environment_id`/`stand_id`. Then run
   `POST /studio/image-models/{id}/test` (dry graph build) and a live smoke on
   the stand.
6. **Verify telemetry.** The worker reports `telemetry.model_name` as the file
   name from the executed graph; the service accepts the frame only when that
   name is in `model_files`. If the catalog entry is missing or the graph uses a
   different filename, the job stops with `keyframe_model_mismatch` — this is
   intentional, not a silent fallback.

If the model needs **custom nodes** or a newer ComfyUI than the pinned base,
that is an image-code change: add the node package to
[`docker/install-comfy-packages.sh`](docker/install-comfy-packages.sh) by commit
SHA and rebuild, or put nodes on the volume and set `LINK_VOLUME_NODES=true`
(less reproducible). The base ComfyUI version must support the model's node
classes; the worker's telemetry parser expects `KSampler*`/`SamplerCustom*`
with linked scheduler/noise/select/guider nodes and a save node producing
`images`.

## Model catalog graphs (`image_models`)

The worker is model-agnostic: adding a model means adding files to the volume and
a graph template to the `image_models` catalog, not editing this repository.
The admin flow (see `docs/tasks/2026-11-12-keyframe-implementation.md`):

1. **Create the catalog row** (`POST /studio/image-models`) with `slug`, `name`,
   `family`, `license`, `license_url`, `capabilities` (`supports_edit`,
   `edit_modes`, `sizes`, `seed`, `negative_prompt`), `defaults`, `graph` and
   `model_files`.
2. **Fill `model_files`** with the pinned files of the model (`name`, `path`,
   `sha256`) exactly as they land on the volume. This is not optional: the
   worker reports `telemetry.model_name` as the file name from the executed
   graph, while the snapshot stores the model `slug`; the pipeline accepts the
   frame only when that file name is present in `model_files[].name/path`.
   Without `model_files` the frame is rejected with
   `keyframe_model_mismatch`.
3. **Put the API-format graph template into `graph`**: `revision`, t2i template
   and optional edit template, `hash`. The service renders the template
   (`{{prompt}}`, `{{width}}`, `{{height}}`, `{{seed}}`, `{{steps}}`, `{{cfg}}`,
   `{{sampler}}`, `{{scheduler}}`, `{{model_files...}}`, `{{assets...}}`) and
   sends the finished graph. The worker does not know about placeholders.
4. **Respect the telemetry contract**, otherwise the job fails visibly:
   - the sampler is `KSampler`, `KSamplerAdvanced`, `SamplerCustom` or
     `SamplerCustomAdvanced` with its linked `RandomNoise` / `BasicScheduler` /
     `KSamplerSelect` / `CFGGuider` nodes;
   - the diffusion model is loaded by `UNETLoader`/`UnetLoaderGGUF*` or
     `CheckpointLoader*` (for `model_name`);
   - the graph ends in a save node producing an `images` entry (`SaveImage`).
5. **Keep `defaults` and the graph consistent**: `parameter.steps/cfg/sampler/
   scheduler/seed/width/height/model_name` that the service puts into the
   snapshot must equal the values rendered into the graph. The application
   compares them with the returned telemetry and stops the step on a deviation
   (the worker never substitutes expected values for facts).
6. **For edit models**, pass the base image and mask through `assets` with the
   names the edit template references (`LoadImage`/`LoadImageMask`), and set
   `capabilities.edit_modes` to `instruction` and/or `mask`.
7. **For i2i style-reference models**, set
   `capabilities.style_reference=true` and, if the graph has no t2i branch,
   `style_reference_required=true`; include `{{style_reference}}` in the
   template (`LoadImage → ImageScale → VAEEncode → KSampler`). The application
   sends the style reference in `assets` and does not start the frame without it
   (`style_reference_missing`). The image already has the core nodes; no new
   package is needed.
7. **Test the model** with `POST /studio/image-models/{id}/test` (admin), then set
   `tested_at`. A row without a successful test is visible as untested in the
   catalog.

Example catalog row (abbreviated):

```json
{
  "slug": "qwen-image-edit-2511",
  "name": "Qwen-Image-Edit-2511",
  "family": "qwen-image",
  "vendor": "Qwen",
  "license": "commercial",
  "license_url": "https://huggingface.co/Comfy-Org/Qwen-Image-Edit",
  "capabilities": {"supports_edit": true, "edit_modes": ["instruction", "mask"], "sizes": [[768, 1344]], "seed": true, "negative_prompt": true},
  "defaults": {"width": 768, "height": 1344, "steps": 20, "cfg": 2.5, "sampler": "euler", "scheduler": "simple", "edit_strength": 0.85},
  "graph": {"revision": 2, "hash": "<sha256>", "t2i": null, "edit": {"...": "API graph template"}},
  "model_files": [
    {"name": "qwen_image_edit_2511_fp8mixed.safetensors", "path": "diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors", "sha256": "..."}
  ]
}
```

## Custom nodes

The image is built on `runpod/comfyui:2.2.0-comfyuiv0.44.0-cuda13.0` pinned by
digest; FLUX.2 klein 4B and Qwen-Image-Edit-2511 are covered by ComfyUI core
nodes, so **no custom-node packages are installed**. If a future model needs a
node package, add it to
[`docker/install-comfy-packages.sh`](docker/install-comfy-packages.sh) **by
commit SHA** (never by `main`) and list it here with its license. Alternatively,
put nodes on the volume and enable `LINK_VOLUME_NODES=true`; the image's own
nodes take precedence and the conflict is logged.

## Endpoint environment

| Variable | Default | Purpose |
|---|---|---|
| `VOLUME_AUTOPOPULATE` | `true` | Download missing models to the volume at boot. |
| `HF_TOKEN` | — | Token for gated Hugging Face repositories (optional). |
| `JOB_TIMEOUT_SECONDS` | `900` | Maximum graph run time inside the worker. |
| `COMFY_BOOT_TIMEOUT_SECONDS` | `600` | How long to wait for the local ComfyUI to start. |
| `LINK_VOLUME_NODES` | `false` | Link `custom_nodes` from the volume at boot. |
| `S3_ENDPOINT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET` | — | S3-compatible storage for large `image_url` results. |

The complete list — inline output thresholds, asset limits, polling, GPU
overrides — is in the contract's environment table.

## Tests

The worker and its contract are tested without a GPU, ComfyUI or runpod SDK: the
ComfyUI HTTP API is mocked at the transport level (`httpx.MockTransport`).

```bash
cd image-serverless
PYTHONPATH=src ../.deps/testenv/bin/python -m pytest tests -q
```

Coverage: input/output JSON schemas (valid examples and rejected violations),
asset validation (name/sha256/size/duplicates) and download into ComfyUI input,
graph passthrough (the submitted graph is byte-for-byte the input graph),
KSampler and SamplerCustomAdvanced telemetry extraction, ambiguity/missing-fact
errors, PNG/JPEG/WebP dimension parsing, inline/URL delivery, health statuses,
cancellation → `/interrupt`, manifest pinning and shell-script syntax.

## Repository layout

Root: `Dockerfile`, `handler.py`, `models-manifest.txt`, `populate-volume.sh`,
`pyproject.toml`. `.runpod/` holds the Hub listing and build test; `contract/`
the v1 contract and examples; `src/image_worker/` the worker; `docker/` and
`scripts/` image helpers; `tests/` the offline test suite.

## What cannot be verified here (and risks)

The code, contract and tests are complete, but the following require a GPU,
Docker daemon, RunPod registry or live Hugging Face download and were **not**
executed while building this repository:

- **Image build** — no Docker/registry in this environment. The Dockerfile is
  structurally checked (all `COPY` sources exist, scripts pass `bash -n`), but a
  real build of the ComfyUI-based image is still required.
- **GPU inference** — no GPU here, so no graph was executed on ComfyUI and the
  real `gpu_cc`/`gpu_class`, timing and memory behaviour are untested.
- **ComfyUI core node classes for these models** — the exact node set used by
  FLUX.2 klein 4B / Qwen-Image-Edit-2511 at ComfyUI v0.44.0 must be confirmed on
  the first smoke run. The worker requires the sampler/loader classes listed in
  the contract to measure telemetry; if the catalog graph uses other classes,
  the job fails with `telemetry_missing` (visible, not silent) and the contract
  must be extended.
- **CUDA 13.0 base vs. 48 GB pools** — if `AMPERE_48`/`ADA_48_PRO` hosts only
  advertise CUDA 12.x drivers, the pinned base will not start; rebuild on a
  CUDA 12.x ComfyUI image and re-pin the digest and `allowedCudaVersions`.
- **Model downloads** — pinned revisions and sha256 come from the public
  Hugging Face metadata; the ~46 GB download itself was not run. A wrong mirror
  (`HF_ENDPOINT`) that drops the commit path fails the pin check by design.
- **Hub validation** — `.runpod/hub.json` was not pushed to RunPod Hub, so GPU
  pool availability and endpoint auto-configuration are unverified.
- **S3 presigned `image_url`** — the path is unit-tested with a fake storage
  backend, but no live S3/MinIO presign was exercised.
- **Memory** — Qwen-Image-Edit-2511 (fp8mixed, 20.5 GB) + 9.4 GB text encoder on
  a 48 GB card leaves little headroom; ComfyUI may offload parts. Long batches
  of variants are better served by one warm worker (max workers 1–2) than by
  parallel cold workers.
- **OCR** — not implemented by the worker; the service must record
  `text_detected` itself. `keyframe_text_detected` is a pipeline deviation, not
  a worker error.

## Licenses

Worker code is MIT (see [LICENSE](LICENSE)). The image includes ComfyUI
(GPL-3.0) and the NVIDIA CUDA/PyTorch components of the base image under their
own terms. Model weights are not part of this repository or the image: they are
downloaded by the operator to a network volume and remain governed by their
Hugging Face repository licenses (FLUX.2 klein 4B and Qwen-Image-Edit-2511 are
Apache-2.0; review them before use).
