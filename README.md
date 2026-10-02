# predbat-givtcp-addon

A single Docker image combining [Predbat](https://github.com/springfall2008/batpred)
(home battery prediction/control for Home Assistant) and
[GivTCP](https://github.com/britkat1980/giv_tcp) (GivEnergy inverter ↔ MQTT/HA
bridge), with three [s6-overlay](https://github.com/just-containers/s6-overlay)
services started in strict order:

```
wait-for-ha  →  givtcp  →  predbat
```

Neither app's own source is vendored/committed here — both are fetched straight
from their upstream git repos at build time (`PREDBAT_VERSION`/`GIVTCP_VERSION` in
`versions.env`), the same way
[`nipar4/predbat_addon`](https://github.com/nipar4/predbat_addon) fetches Predbat.
This repo is independent of that one — it does not touch or build from it.

## Why three services, in this order

- `wait-for-ha` polls Home Assistant over TCP (`WAIT_FOR_HA_HOST`/`WAIT_FOR_HA_PORT`)
  and force-restarts the container if HA disappears for `WAIT_FOR_HA_MAX_FAILS`
  consecutive checks. Optional — a no-op if those env vars aren't set.
- `givtcp` depends on `wait-for-ha` (s6-rc ordering) and does its own redundant
  wait for HA before starting, then runs GivTCP against your real GivEnergy
  inverter(s).
- `predbat` depends on `givtcp` (which transitively ensures `wait-for-ha` ran
  first), does its own redundant HA wait, then starts Predbat.

`predbat`'s dependency on `givtcp` is ordering only (s6-rc guarantees `givtcp`'s
process has been *launched* first, not that it's fully warmed up or has found an
inverter yet). Predbat is not given a GivTCP-specific readiness check — its actual
dependency is on HA *entities* GivTCP populates via MQTT, which is an
eventually-consistent path Predbat already needs to tolerate as normal long-running
operation. **A handful of "entity not found" warnings on a genuinely cold first
boot are expected and should self-resolve within Predbat's own polling cycle — not
a bug in this image.**

## Known upstream issues

### GivTCP's `pymodbus.client.sync` import is broken, on every ref, as of 2026-10

GivTCP's `requirements.txt` pins no version for `pymodbus`, so pip always installs
whatever's latest on PyPI (currently 3.15.0), which removed the
`pymodbus.client.sync` module path that `startup.py` and `GivTCP/evc.py` still
import. This breaks on **any** GivTCP ref, not just `main` — confirmed broken on
the latest tagged release (`3.5`) too, and there is no upstream fix to wait for.

This image patches it with a `sed` in the `Dockerfile`, verified working against
real GivEnergy hardware (found the inverter, opened a live Modbus connection,
published HA MQTT discovery, stayed healthy). The patch includes a build-time
`grep` guard that fails the build loudly if a future GivTCP release moves or
duplicates the broken import in a way the `sed` no longer catches — this is
expected to be carried indefinitely, not removed once "fixed upstream," unless you
confirm a newer release no longer needs it.

### No declared license on GivTCP

Neither the archived `GivEnergy/giv_tcp` org repo nor the actively-maintained
`britkat1980/giv_tcp` fork declares an OSS license. Fine for personal/private use;
worth knowing if you ever intend to redistribute this image publicly.

## Networking and privilege

This image needs `--network host` — without it, GivTCP's subnet broadcast scan for
inverters only reaches Docker's own bridge network, not your real LAN. It also
needs `--privileged` (confirmed working in production; not narrowed to specific
capabilities like `NET_RAW`/`NET_ADMIN` — see the project's planning notes if you
want to experiment with that yourself against real hardware, since a regression
there manifests as "scan finds nothing," not a crash, so it can't be validated in
CI).

**Because all three services share one container, Predbat also ends up running
host-networked and privileged, even though Predbat itself needs neither.** This is
an accepted cost of combining them into one image.

### Ports

| Service | Port(s) | Notes |
|---|---|---|
| Predbat | `5052` | HA ingress panel |
| Predbat | `8199` | Standalone/host-mapped web UI |
| GivTCP  | `8099` | REST + the nginx-served web config UI, combined |
| GivTCP  | `6350` | Settings REST API — up almost immediately |
| GivTCP  | `6345`+ | Per-inverter REST API — only opens once an inverter is found |
| GivTCP  | `6379` | Redis (job queue) |
| GivTCP  | `1883` | MQTT, only if GivTCP runs its own internal broker (unconfirmed whether the current GivTCP release still does this — verify via `docker exec <container> ps` if you're not pointing `MQTT_ADDRESS` at an external broker) |

`8099` (GivTCP) and `8199` (Predbat) are easy to mix up when reading configs —
double-check which one you mean.

Previously GivTCP ran host-networked alone; combining it with Predbat means
Predbat's `5052`/`8199` become host-mode too. Check nothing else on your target
host already binds those before deploying.

## Config layout — kept genuinely separate

Predbat's config (`apps.yaml`) and GivTCP's config (`allsettings.json`, at a path
hardcoded in GivTCP's own `startup.py`, not env-configurable) are **not** merged
into one shared directory. Mount two independent host directories instead — Docker
supports a bind mount nested inside another bind mount's container path with no
conflict, so this gives fully independent, separately-backupable storage on the
host even though the container-side paths are nested:

```
docker run -d \
  --network host --privileged \
  -v /opt/predbat-givtcp/predbat-conf:/config \
  -v /opt/predbat-givtcp/givtcp-conf:/config/GivTCP \
  -e WAIT_FOR_HA_HOST=192.168.1.210 \
  -e WAIT_FOR_HA_PORT=8123 \
  nipar4/predbat-givtcp-addon:latest
```

## Environment variables

| Variable | Default | Used by |
|---|---|---|
| `WAIT_FOR_HA_HOST` | unset (disables HA waiting) | all three services |
| `WAIT_FOR_HA_PORT` | unset (disables HA waiting) | all three services |
| `WAIT_FOR_HA_INTERVAL` | `10` | all three services |
| `WAIT_FOR_HA_MAX_FAILS` | `3` | `wait-for-ha` only (consecutive failures before container restart) |
| `DELAY_INTERVAL` | `10` | `givtcp`, `predbat` (extra settle time after HA becomes reachable) |

GivTCP's own many configuration options live in `/config/GivTCP/allsettings.json`
(auto-bootstrapped on first run) rather than environment variables — edit it
directly or via GivTCP's own web config UI at `http://<host>:8099/config.html`.

## Building and testing locally

```
scripts/build-boot-test.sh
```

Builds the image (always sourcing `PREDBAT_VERSION`/`GIVTCP_VERSION`/`S6_VERSION`
from `versions.env`), boots it without `--network host`/`--privileged`, and asserts
all three s6 services reach an expected state. This intentionally cannot validate
GivTCP's real-LAN inverter discovery (no hardware/LAN access in that mode) — treat
a pass here as "the image boots cleanly," not as "it talks to your inverter." For
that, test by hand against real hardware using the `docker run` example above.
