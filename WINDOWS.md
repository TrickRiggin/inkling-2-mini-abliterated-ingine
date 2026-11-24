# Running ingine on Windows (WSL2)

`ingine` is a Linux C++20/CUDA inference engine built specifically for the RTX 5090 (`sm_120a`). Rather than maintaining a separate MSVC/Windows fork, it runs unmodified inside **WSL2** with GPU passthrough, and Windows applications talk to it directly at `http://127.0.0.1:8003/v1` via WSL2's automatic localhost forwarding.

## Requirements

* **Windows 11 x64** with **WSL `2.7.0` or newer** (`wsl --update` if older — earlier WSL versions fail Blackwell CUDA Graph capture).
* **NVIDIA RTX 5090 (32 GB)** (or compute capability `12.0` card with >= 32 GB VRAM).
* **Windows NVIDIA driver `580` or newer** (for CUDA 13; tested on `621.01`). Do **not** install a Linux GPU driver inside WSL2.
* A **WSL2 Linux distribution** such as Ubuntu 24.04 (`wsl --install -d Ubuntu-24.04`).
* **~24 GB free space** on your WSL2 Linux virtual disk (20.2 GB model + ~3 GB private CUDA 13.4 toolkit and build).

## Quick install (PowerShell)

Clone this repo anywhere on Windows (or download [`setup-windows.ps1`](setup-windows.ps1)) and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
```

Or run it directly from GitHub:

```powershell
irm https://raw.githubusercontent.com/TrickRiggin/inkling-2-mini-abliterated-ingine/main/setup-windows.ps1 | iex
```

What the installer does:
1. Checks your RTX 5090, Windows NVIDIA driver (`580+`), VRAM headroom, and WSL version (`2.7.0+`).
2. Installs missing Linux build prerequisites (`build-essential`, `git`, `curl`, `util-linux`) inside WSL2 if needed.
3. Clones upstream [`satellitedown/inkling-2-mini-abliterated-ingine`](https://github.com/satellitedown/inkling-2-mini-abliterated-ingine) into **WSL2's native Linux filesystem** (`~/inkling-2-mini-abliterated-ingine`) — keeping upstream as the remote so `ingine update` pulls engine and model updates directly, and avoiding `/mnt/c` slowness and CRLF issues.
4. Forwards `HF_TOKEN` (or `HUGGING_FACE_HUB_TOKEN` / `HF_PAT`) from your Windows environment if set, then runs upstream `scripts/install.sh` (private CUDA 13.4 toolkit, C++ build, and 20.2 GB model download + SHA-256 verification).
5. Installs a Windows `ingine` CLI shim (`%LOCALAPPDATA%\ingine\bin\ingine.cmd`) onto your User `PATH`.

### Useful installer flags

```powershell
.\setup-windows.ps1 -CheckOnly                 # verify GPU, driver, VRAM, and WSL2 version only
.\setup-windows.ps1 -Distro Ubuntu-24.04       # pick a specific WSL2 distribution
.\setup-windows.ps1 -ShimOnly                  # only reinstall the Windows `ingine` command
```

## Daily use from PowerShell / CMD

Once installed, manage the server directly from Windows without opening a WSL shell:

```powershell
ingine start       # start in the background (systemd user unit in WSL2) and wait until ready
ingine status      # health, model id, context length, and GPU VRAM
ingine stop        # stop the server and free ~25 GiB of GPU VRAM
ingine logs -f     # stream server logs
ingine update      # pull upstream updates, rebuild incrementally, and verify model pins
```

Point any Windows OpenAI-compatible client at:
* **Base URL:** `http://127.0.0.1:8003/v1`
* **Model:** `inkling-2-mini-abliterated`
* **API key:** any non-empty string (no authentication)

Quick smoke test from PowerShell:

```powershell
Invoke-RestMethod http://127.0.0.1:8003/health
```

## Measured WSL2 performance (RTX 5090)

Measured on Windows 11 (`WSL 2.7.11.0`, kernel `6.18.33.2`, NVIDIA driver `621.01`, Ubuntu 24.04) with the default serving profile (`262,144` context, `--dense-fp8 --kv-fp8 --spec --spec-threshold 0.8`, runtime abliteration active):

| Check | Result |
|---|---|
| GPU kernel / CUDA Graph / vision test suite (`ctest -LE model`) | **26/26 passed** (100% of executed tests) |
| Model load + CUDA Graph capture | **3.1 s** |
| Chat decode (512 tok, greedy, DSpark) | **416.8 tok/s** (3.08 tok/verify) |
| Code decode (512 tok, greedy, DSpark) | **393.1 tok/s** (3.01 tok/verify) |
| 20K-token prompt prefill | **8,205 tok/s** |
| Total GPU VRAM (server + Windows desktop) | **27.2 / 32.6 GiB** (~5.4 GiB free) |

Expect roughly 15–25% lower peak throughput than bare-metal Linux due to WSL2 GPU paravirtualization (`dxgkrnl`) and Windows desktop sharing the card.

## Windows-specific notes & troubleshooting

* **Do not build or store the 20 GB model under `/mnt/c`:** Accessing Windows NTFS from WSL2 goes over 9P, which makes C++ builds and 20 GB weight loads dramatically slower and can break symlinks and shell script line endings (`bash\r`). Always keep the WSL2 install on the Linux ext4 drive (default `~/inkling-2-mini-abliterated-ingine`).
* **Windows VRAM headroom:** The Windows desktop and browsers typically hold 1.5–3 GiB of VRAM. The default 262K-context profile takes ~24.4 GiB at startup, leaving a few GiB free. If startup OOMs while other GPU apps are open, either run `ingine stop` when not using it, or tune settings in WSL2's `~/.config/ingine/env`:
  ```bash
  # Lower context to 131K (saves ~2 GiB)
  INGINE_CTX=131072
  # Disable vision tower (-0.6 GiB) and/or conversation parking
  INGINE_EXTRA_ARGS="--no-vision --park-mb 0"
  ```
* **Background persistence across WSL2 idle timeouts:** Windows normally shuts down an idle WSL2 distro ~8 seconds after the last WSL terminal exits (which stops the `inkling-ingine` systemd user unit). The Windows `ingine` shim handles this automatically by holding a zero-CPU hidden `wsl.exe` keepalive session between `ingine start` and `ingine stop`, so the server stays up even after you close PowerShell and releases cleanly on `ingine stop`.
* **P0 GPU clock profile:** Upstream's installer writes `~/.nv/nvidia-application-profiles-rc.d/50-ingine` for a ~0.8% Linux memory-clock boost. On WSL2, clocks are managed by the Windows host driver, so that file is a harmless no-op.
* **Customizing per-command env vars from PowerShell:** `ingine.ps1` forwards `INGINE_CTX`, `INGINE_MODEL_DIR`, `INGINE_ABLATION`, `INGINE_EXTRA_ARGS`, `HOST`, `PORT`, and `HF_TOKEN` when set in your Windows shell.
