# CLI-Only Docker Development (No Docker Desktop)

This guide describes how to build and use the badge firmware Docker image with **Docker Engine CLI** only (no graphical Docker Desktop). It is intended for Linux environments where you can access USB devices from the host.

## ✅ Prerequisites

- Docker Engine installed and running (rootless or rootful)
- Your user is in the `dialout` group to access serial devices

If you need to add yourself to `dialout`:

```bash
sudo usermod -a -G dialout $USER
```

Log out and log back in after running the command above.

## Build the CLI-Only Image

Use the new Makefile target to build the CLI-only image (uses `Dockerfile.rootless`):

```bash
make docker_cli_build
```

If you update Docker dependencies (like adding Python modules), rebuild the image with the same target.

**Optional overrides:**

- `DOCKER_IMAGE` (default: `disobey-badge-firmware:cli`)
- `DOCKERFILE_CLI` (default: `Dockerfile.rootless`)

Example:

```bash
make docker_cli_build DOCKER_IMAGE=badge-fw:local
```

## Connect to the Badge (REPL via Container)

Use the new make target to connect to the badge **through the container**:

```bash
make docker_cli_repl
```

By default, the target will attempt to use:

- `/dev/ttyUSB0`, or
- `/dev/ttyACM0`

If your badge is on a different device, provide `PORT` explicitly:

```bash
make docker_cli_repl PORT=/dev/ttyUSB1
```

Once connected, start the UI inside the REPL:

```python
import badge.main
```

## Notes

- This flow **does not require Docker Desktop**.
- The container mounts the repo at `/workspace` and runs `make repl_with_firmware_dir` inside the container.
- If you see permission errors, confirm the device node exists and your user belongs to the `dialout` group.
