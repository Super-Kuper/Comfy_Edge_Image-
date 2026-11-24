# Image Serverless — ComfyUI worker for FLUX.2 klein / Qwen-Image-2512 / Qwen-Image-Edit

RunPod serverless worker for the video_gen **keyframe** step. It runs ComfyUI
v0.44.0 on one 48 GB image GPU, executes a **prepared ComfyUI API graph** built
by the video_gen catalog, and returns the generated image plus execution-fact
telemetry. It does not build or modify the graph, does not ship model weights and
keeps ComfyUI on loopback only. Contract: **`image-serverless/v1`** —
[`contract/worker-contract.md`](contract/worker-contract.md).

Image models on the stand (all Apache-2.0, commercial use allowed):

| Model | Mode | Files |
|---|---|---|
| FLUX.2 klein 4B | t2i (generate) | diffusion model + Qwen3-4B text encoder + FLUX.2 VAE |
| Qwen-Image-2512 | t2i (generate) | fp8 diffusion model + Qwen2.5-VL text encoder + Qwen-Image VAE |
| Qwen-Image-Edit-2511 | edit (instruction + optional mask) и i2i (style-reference init image) | fp8mixed diffusion model + Qwen2.5-VL text encoder + Qwen-Image VAE |

The two Qwen models reuse the same text encoder and VAE; only the diffusion
weights differ.

## Deploy

1. **Storage first.** Create a network volume of at least **100 GB** in a
   datacenter that offers 48 GB image GPUs (`AMPERE_48` — RTX A6000/A40,
   `ADA_48_PRO` — L40S/L40/RTX 6000 Ada). The pinned model set is ~66.7 GB; the
   volume also holds ComfyUI outputs/temporary files and future models. The old
   60 GB minimum is no longer enough for the current manifest.
2. **Deploy the worker.** Publish this repository as a GitHub release to
   [RunPod Hub](https://console.runpod.io/hub) (metadata:
   [`.runpod/hub.json`](.runpod/hub.json) — `AMPERE_48,ADA_48_PRO`,
   CUDA 13.0–13.4, 40 GB container disk), or build the image and create a
   serverless endpoint yourself.
3. **Attach the volume** at `/runpod-volume`, use endpoint type **`QUEUE`**,
   **Max workers = 1–2**, idle timeout short (for example 5–10 s) and endpoint
   timeout **at least `JOB_TIMEOUT_SECONDS`** (the worker default is 900 s;
   **1200 s recommended** for Qwen-Image-2512: a live 20-step frame on an A40
   took 409 s, and the catalog's 50-step default approaches 600 s). One warm
   worker that already loaded the model beats several cold ones; a second worker
   only helps for queued bursts. Keep the endpoint timeout above the worker job
   timeout: RunPod kills the run when either expires.
4. **Populate the volume before traffic.** With `VOLUME_AUTOPOPULATE=true`
   (default) the container downloads missing files from
   [`models-manifest.txt`](models-manifest.txt) into
   `/runpod-volume/models`; later boots reuse the volume. The first download of
   ~67 GB takes tens of minutes, and a job submitted meanwhile can sit in the
   queue longer than the app's `policy.ttl` — RunPod then answers `404` on
   `status` (`run not found`). Pre-populate with the CPU pod recipe above or
   keep `min workers = 1` while the volume is cold.
5. **Smoke-test** with the health action (see [Health](#health)); RunPod Hub runs
   this test on build ([`.runpod/tests.json`](.runpod/tests.json)).
6. **Keep secrets in the endpoint environment only** (`S3_*` for large results,
   optional `HF_TOKEN` for gated Hugging Face mirrors).

### Requirements

| Item | Requirement |
|---|---|
| GPU | 48 GB recommended: L40S (`ADA_48_PRO`) primary, RTX A6000 (`AMPERE_48`) cheap fallback. 32 GB works with fp8 Qwen-Image models but leaves little headroom; 24 GB is not supported by this manifest. |
| CUDA, endpoint | The image is built on a CUDA 13.0 ComfyUI base pinned by digest (see [Dockerfile](Dockerfile)). Host drivers must support CUDA 13.0 (13.0–13.4 are accepted by the Hub metadata). If the chosen 48 GB pool only advertises CUDA 12.x drivers, rebuild on a CUDA 12.x ComfyUI base and re-pin the digest + `.runpod/hub.json` `allowedCudaVersions`. |
| Network volume | at least 100 GB at `/runpod-volume` (the pinned set is ~66.7 GB) |
| Registry | The built image must be available to RunPod (Hub build or your registry) |
| ComfyUI core | Image models are served by ComfyUI core nodes; the image installs no custom-node packages. |

## Build the image

The root [Dockerfile](Dockerfile) builds on the official ComfyUI v0.44.0
CUDA 13.0 image pinned by digest and adds the worker package, `handler.py` and
the volume scripts.

```bash
docker build -t <registry>/image-serverless:1.2.0 .
docker push <registry>/image-serverless:1.2.0
```

Structural build without ComfyUI or a GPU (checks that the Dockerfile, package
and scripts are wired; not meant to run):

```bash
docker build --build-arg BASE_IMAGE=python:3.12-slim \
  --build-arg SKIP_COMFY_PACKAGES=1 -t image-serverless:stub .
docker run --rm --entrypoint python image-serverless:stub -c "import image_worker"
```

Optional build args: `IMAGE_WORKER_VERSION` (`1.2.0`), `COMFYUI_VERSION`
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

The **video_gen** side sends `policy.executionTimeout` = keyframe timeout (900 s)
and `policy.ttl` = `KEYFRAME_JOB_TTL_SECONDS` (3600 s): TTL must cover both the
queue and the execution. A `404` from `/v2/{endpoint}/status/{run}` means the run
is not registered for that endpoint — the endpoint was recreated while the job
was in flight or the job expired and was purged; it is not a graph error. The
app repeats the poll a few times (a run may not be registered immediately) and
reports the response body plus endpoint/run ids, so the card shows the real
cause.

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
| `diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors` | [Comfy-Org/Qwen-Image](https://huggingface.co/Comfy-Org/Qwen-Image) @ `1f12b17b` | 20.43 GB |
| `diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors` | [Comfy-Org/Qwen-Image-Edit](https://huggingface.co/Comfy-Org/Qwen-Image-Edit) @ `f68ace85` | 20.53 GB |
| `text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors` | [Comfy-Org/Qwen-Image](https://huggingface.co/Comfy-Org/Qwen-Image) @ `1f12b17b` | 9.38 GB |
| `vae/qwen_image_vae.safetensors` | same repository | 0.25 GB |

Volume manifest and boot variables: `models-manifest.txt`; `VOLUME_AUTOPOPULATE`
(default `true`), `VOLUME_VERIFY` (default `fast`), `VOLUME_BACKGROUND_VERIFY`
(default `true`), `HF_TOKEN` (optional, gated repositories only) and
`HF_ENDPOINT` (optional mirror; the commit path is preserved). The download
target is `$VOLUME_ROOT/models`.

### Boot checks: fast path and background verification

`populate-volume.sh` runs before the handler starts, so it must not re-read the
whole volume on every cold start: hashing the pinned sha256 of all 66.7 GB takes
~4.5 minutes on the RunPod network volume (~245 MB/s) — 94% of the boot time
measured in a real worker log. The script therefore keeps
`models/.populate-state.tsv` (`<subdir>/<file>\t<sha256>\t<size>\t<mtime>`) and,
with `VERIFY=fast` (default), treats a file as intact when the recorded sha256,
size and mtime still match: a warm boot is a handful of `stat` calls. Rows
written by older worker versions have no mtime, so such a file is hashed once
and upgraded in place — no re-download, no manual migration.

Metadata mismatch (new pin, changed size or mtime) or `VERIFY=full` reads the
file. A file that does not match its pin is moved to `<file>.corrupt-<UTC>` and
re-downloaded, so ComfyUI never sees known-bad weights: the job fails visibly
instead of generating from corrupted bytes, and the quarantine copy is removed
only after the verified replacement is in place (it stays for diagnosis if the
re-download fails).

The full check still runs on every boot, but off the critical path: once the
handler is up, `entrypoint.sh` starts a second populate pass with `VERIFY=full`
(`[populate-verify]` in the log, `nice`/`ionice`, stopped on `SIGTERM`). It
repairs whatever it finds, so integrity is verified seconds after boot instead
of blocking it. It does share the volume with the first job's weight load, so the
first render can be somewhat slower until the pass finishes. Set `VOLUME_BACKGROUND_VERIFY=false` to skip it (the volume is
then verified only when metadata changes) or `VOLUME_VERIFY=full` to keep the
old blocking behaviour.

The flock on `$VOLUME_ROOT/.populate.lock` is taken only around mutations
(download, quarantine, state write), never around hashing: a background check in
one worker does not stall the boot of another worker on the same volume.

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
   **The endpoint image is the versioned copy of this manifest.** A file added to
   `models-manifest.txt` reaches the volume only when a worker built from an image
   that contains the new manifest cold-starts and runs `populate-volume.sh`.
   Registering the model in the video_gen `image_models` catalog without updating
   the endpoint image leaves ComfyUI with the old file list: the frame stops with
   `keyframe_generation_failed`, and the worker log shows
   `400 value_not_in_list` for `unet_name` / `clip_name` / `vae_name`. After the
   image update set `min workers=1` until the first boot's populate finishes, then
   return `min` to 0 (a queued job also triggers the download, but a 20 GB model
   can outlive the endpoint timeout while the worker is still booting).
   **Raise `RUNPOD_INIT_TIMEOUT` on the endpoint (e.g. `1800`)** for that first
   boot: `populate-volume.sh` runs before the handler starts, so the default
   RunPod cold-start timeout (~7 minutes) kills the worker in the middle of a
   20 GB download; it resumes from `.<file>.tmp` on the next boot
   (`curl --continue-at -`), but the worker can cycle several times before the
   file lands. The variable only extends initialization, so it can stay set. It
   covers the first download only: a warm boot no longer re-reads the volume
   (see "Boot checks" above), so returning `min` to 0 no longer costs minutes.
4. **Populate the volume.** With `VOLUME_AUTOPOPULATE=true` the next cold start
   downloads only the missing files (sha256-checked, `.tmp` + atomic rename, flock
   between workers) and verifies the rest in the background after the handler is
   up. To avoid a long first job, run
   `populate-volume.sh` in a temporary CPU pod with the same volume:
   ```bash
   VOL_ROOT=/runpod-volume MANIFEST=/opt/image-worker/models-manifest.txt \
     bash /opt/image-worker/populate-volume.sh
   ```
   Check free space first: the current set is ~66.7 GB; adding another 20 GB
   model to a 100 GB volume needs a resize check (network volumes can be grown,
   not shrunk).
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
   `sha256`) exactly as they land on the volume — the diffusion model **and**
   its text encoder/VAE. This is not optional: the worker reports
   `telemetry.model_name` as the file name from the executed graph, while the
   snapshot stores the model `slug`; the pipeline accepts the frame only when
   that file name is present in `model_files[].name/path`. Without
   `model_files` the template placeholder `{{model_file}}` stops the job with
   `image_model_files_missing` and the frame is rejected with
   `keyframe_model_mismatch` (`{{model_file}}` is resolved from the
   `diffusion_models/`/`checkpoints/` entry, never from the slug).
3. **Put the API-format graph template into `graph`**: `revision`, `template`,
   `hash`. The service renders the template and sends the finished graph; the
   worker does not know about placeholders. Placeholders are `{{prompt}}`,
   `{{negative_prompt}}`, `{{instruction}}`, `{{strength}}`, `{{width}}`,
   `{{height}}`, `{{seed}}`, `{{steps}}`, `{{cfg}}`, `{{sampler}}`,
   `{{scheduler}}`, `{{denoise}}`, `{{filename_prefix}}`, `{{model_file}}`,
   `{{base_image}}`, `{{mask}}`, `{{anchor}}`, `{{style_reference}}`.
4. **Respect the telemetry contract**, otherwise the job fails visibly:
   - the sampler is `KSampler`, `KSamplerAdvanced`, `SamplerCustom` or
     `SamplerCustomAdvanced` with its linked `RandomNoise` / `BasicScheduler` /
     `KSamplerSelect` / `CFGGuider` nodes. FLUX.2's native `Flux2Scheduler` is
     **not** in the telemetry parser yet: a graph with it fails with
     `telemetry_missing` (scheduler), so use `KSampler` (euler/simple) or extend
     the worker parser;
   - the diffusion model is loaded by `UNETLoader`/`UnetLoaderGGUF*` or
     `CheckpointLoader*` (for `model_name`);
   - the graph ends in a save node producing an `images` entry (`SaveImage`).
5. **Keep `defaults` and the graph consistent**: `parameter.steps/cfg/sampler/
   scheduler/seed/width/height/model_name` that the service puts into the
   snapshot must equal the values rendered into the graph. The application
   compares them with the returned telemetry and stops the step on a deviation
   (the worker never substitutes expected values for facts).
6. **For edit models**, pass the base image and mask through `assets` with the
   names the edit template references (`LoadImage`/`LoadImageMask`), scale the
   base to the snapshot canvas (`ImageScale`) so the measured size equals the
   snapshot, and set `capabilities.edit_modes` to `instruction` and/or `mask`.
7. **For i2i style-reference models**, set
   `capabilities.style_reference=true` and, if the graph has no t2i branch,
   `style_reference_required=true`; include `{{style_reference}}` in the
   template (`LoadImage → ImageScale → VAEEncode → KSampler`). The application
   sends the style reference in `assets` and does not start the frame without it
   (`style_reference_missing`). The image already has the core nodes; no new
   package is needed.
8. **Check the graph, then get a live frame.** `POST
   /studio/image-models/{id}/test` (admin) is a **static lint without GPU**: it
   renders every branch (t2i, edit with/without mask, i2i), checks node classes,
   link indices/types, required inputs (`weight_dtype`), asset names and pinned
   `model_files`, and returns `409 image_model_graph_invalid` with the exact
   problems. It does **not** set `tested_at`: that date is set only by the first
   successful **live** keyframe (the smoke test on the stand), so a row is never
   marked "tested" just because the template rendered. A row without a live
   frame is visible as untested in the catalog.

### Graph gotchas for the shipped models

- **FLUX.2 klein 4B (t2i)**: split loaders are mandatory —
  `UNETLoader(flux-2-klein-4b.safetensors, weight_dtype=default)` +
  `CLIPLoader(qwen_3_4b.safetensors, type=flux2)` + `VAELoader(flux2-vae.safetensors)`.
  The latent node must be `EmptyFlux2LatentImage` (128 channels, size multiple
  of 16): `EmptyLatentImage`/`EmptySD3LatentImage` give 4/16 channels and fail
  at the sampler. `weight_dtype` is required by ComfyUI 0.44.
- **Qwen-Image-2512 (t2i)**: `UNETLoader` + `CLIPLoader(type=qwen_image)` +
  `VAELoader(qwen_image_vae.safetensors)`, `CLIPTextEncode` positive/negative,
  `EmptySD3LatentImage` (16-channel latent) and the required
  `ModelSamplingAuraFlow(shift=3.1)` before `KSampler`; without the AuraFlow
  node Qwen-Image produces noise. The diffusion file is
  `qwen_image_2512_fp8_e4m3fn.safetensors`; the text encoder and VAE are shared
  with Qwen-Image-Edit. Defaults from the model card: 50 steps / CFG 4.0.
- **Qwen-Image-Edit-2511 (edit)**: `UNETLoader` + `CLIPLoader(type=qwen_image)`
  + `VAELoader`, base image via `LoadImage` → `ImageScale` → `VAEEncode`,
  conditioning via `TextEncodeQwenImageEdit`, optional mask via
  `LoadImageMask(channel=red)`/`SetLatentNoiseMask`. Use `defaults.strength`
  ~0.85 for instruction edits (it renders into KSampler `denoise`); 0.35 barely
  changes the frame.
- **Qwen-Image-Edit-2511 i2i (style reference)**: same loaders, reference via
  `LoadImage` → `ImageScale` → `VAEEncode`, denoise ~0.65, conditioning
  `TextEncodeQwenImageEdit` with the reference image.

All shipped templates are covered by `graph_lint` tests in video_gen; the
ComfyUI node classes themselves are still verified only on a live stand.

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
  "defaults": {"width": 768, "height": 1344, "steps": 20, "cfg": 2.5, "sampler": "euler", "scheduler": "simple", "strength": 0.85},
  "graph": {"revision": "qwen-image-edit-2511-v2", "hash": "<sha256>", "template": {"1": {"class_type": "UNETLoader", "inputs": {"unet_name": "{{model_file}}", "weight_dtype": "default"}}, "...": "API graph template"}},
  "model_files": [
    {"name": "qwen_image_edit_2511_fp8mixed.safetensors", "path": "diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors", "sha256": "..."},
    {"name": "qwen_2.5_vl_7b_fp8_scaled.safetensors", "path": "text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors", "sha256": "..."},
    {"name": "qwen_image_vae.safetensors", "path": "vae/qwen_image_vae.safetensors", "sha256": "..."}
  ]
}
```

## Custom nodes

The image is built on `runpod/comfyui:2.2.0-comfyuiv0.44.0-cuda13.0` pinned by
digest; FLUX.2 klein 4B and Qwen-Image-2512 / Qwen-Image-Edit-2511 are covered by
ComfyUI core nodes, so **no custom-node packages are installed**. If a future
model needs a node package, add it to
[`docker/install-comfy-packages.sh`](docker/install-comfy-packages.sh) **by
commit SHA** (never by `main`) and list it here with its license. Alternatively,
put nodes on the volume and enable `LINK_VOLUME_NODES=true`; the image's own
nodes take precedence and the conflict is logged.

## Endpoint environment

| Variable | Default | Purpose |
|---|---|---|
| `VOLUME_AUTOPOPULATE` | `true` | Download missing models to the volume at boot. |
| `VOLUME_VERIFY` | `fast` | `fast` trusts the recorded size+mtime from `.populate-state.tsv`; `full` always reads sha256; `off` skips the check (debug only). |
| `VOLUME_BACKGROUND_VERIFY` | `true` | Run the full sha256 pass in the background after the handler starts (`[populate-verify]`). |
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
  FLUX.2 klein 4B / Qwen-Image-2512 / Qwen-Image-Edit-2511 at ComfyUI v0.44.0
  must be confirmed on the first smoke run. The worker requires the
  sampler/loader classes listed in the contract to measure telemetry; if the
  catalog graph uses other classes, the job fails with `telemetry_missing`
  (visible, not silent) and the contract must be extended.
- **CUDA 13.0 base vs. 48 GB pools** — if `AMPERE_48`/`ADA_48_PRO` hosts only
  advertise CUDA 12.x drivers, the pinned base will not start; rebuild on a
  CUDA 12.x ComfyUI image and re-pin the digest and `allowedCudaVersions`.
- **Model downloads** — pinned revisions and sha256 come from the public
  Hugging Face metadata; the ~66.7 GB download itself was not run. A wrong
  mirror (`HF_ENDPOINT`) that drops the commit path fails the pin check by
  design.
- **Hub validation** — `.runpod/hub.json` was not pushed to RunPod Hub, so GPU
  pool availability and endpoint auto-configuration are unverified.
- **S3 presigned `image_url`** — the path is unit-tested with a fake storage
  backend, but no live S3/MinIO presign was exercised.
- **Memory** — any Qwen-Image 20B model (fp8, ~20.4–20.5 GB) + 9.4 GB text
  encoder on a 48 GB card leaves little headroom; ComfyUI may offload parts.
  Long batches of variants are better served by one warm worker (max workers
  1–2) than by parallel cold workers.
- **OCR** — not implemented by the worker; the service must record
  `text_detected` itself. `keyframe_text_detected` is a pipeline deviation, not
  a worker error.

## Licenses

Worker code is MIT (see [LICENSE](LICENSE)). The image includes ComfyUI
(GPL-3.0) and the NVIDIA CUDA/PyTorch components of the base image under their
own terms. Model weights are not part of this repository or the image: they are
downloaded by the operator to a network volume and remain governed by their
Hugging Face repository licenses (FLUX.2 klein 4B, Qwen-Image-2512 and
Qwen-Image-Edit-2511 are Apache-2.0; review them before use).
