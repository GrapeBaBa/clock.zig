# clock.zig

Standalone Zig clock library that mirrors Lodestar `clock.ts` behavior with a millisecond-only API.

## Build and Run

```bash
zig build test
zig build run-example
```

Optional:

```bash
zig build -Doptimize=ReleaseFast
```

## Project Layout

- `src/clock.zig`: single library entry (types + implementation + tests)
- `examples/basic.zig`: minimal usage example
- `build.zig`: library + example + test build graph

## How This Mirrors Lodestar TS

Current Zig implementation mirrors the TypeScript clock at behavior level:

1. Slot/epoch progression:
   - TS recursive `setTimeout(onNextSlot)` is mapped to Zig `timerLoop -> onNextSlot`.
   - If multiple slots were missed (e.g. process stall), `onNextSlot` catches up slot-by-slot and emits events in order.
2. Wait semantics:
   - `waitForSlot(target)` resolves when `currentSlot >= target`.
   - Abort path rejects/returns aborted state for pending waits.
3. Gossip disparity checks:
   - Same acceptance model for current / next / previous slot windows using `maximum_gossip_clock_disparity_ms`.
4. Time model:
   - Public API is millisecond-based (`u64` inputs for absolute/tolerance time).
   - Slot and epoch remain `u64`.

## Testing Clock

For deterministic tests, use `ManualTimeProvider`:

- Construct clock with `Clock.initWithTimeHooks(..., manual_time.hooks())`
- Advance virtual time via `manual_time.advanceMs(...)`
- No real-time waiting is required to drive `waitForSlot`

This follows the same practical pattern used by other clients:
system clock in production, manual/stub clock in tests.

## CI

GitHub Actions workflow: `.github/workflows/ci.yml`

CI runs:

1. `zig build test`
2. `zig build run-example`

This validates both library tests and runtime example behavior.
