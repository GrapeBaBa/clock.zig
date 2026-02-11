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

This implementation mirrors Lodestar `clock.ts` at behavioral level, not by
line-by-line translation.

### Runtime model

1. Timer scheduling model:
   - TS uses recursive `setTimeout(onNextSlot)`.
   - Zig uses one async loop: `timerLoop -> sleepMs(msUntilNextSlot) -> onNextSlot`.
2. Catch-up model:
   - If local time jumps ahead, `onNextSlot` advances from cached slot to
     current wall-clock slot one-by-one.
   - This preserves deterministic emission order for missed slots.
3. Lazy start:
   - Clock loop is started on first active API usage (`ensureStarted`), same
     practical lifecycle as TS where timers are only meaningful after startup.
4. Re-alignment on drift:
   - `currentSlot()` detects slot jumps and calls `rearmTimer()` to cancel and
     restart the loop so wake-ups stay aligned to slot boundaries.

### Event ordering mirror

Per advanced slot, the order is:

1. increment `current_slot_cache`
2. emit slot event
3. resolve waiters whose target slot is reached
4. if epoch changed, emit epoch event

This matches Lodestar's expected "slot-first, epoch-after-boundary" behavior.
The step-by-step deterministic order is validated by tests.

### WaitForSlot mirror

`waitForSlot(target)` mirrors TS promise semantics:

1. Fast-path: return immediately when `currentSlot >= target`
2. Otherwise register waiter
3. Trigger one synchronous catch-up check (`currentSlot()`)
4. Block until:
   - target reached -> success
   - aborted -> `error.Aborted`

Pending waiters are woken both on normal slot advancement and abort path.

### Abort mirror

`AbortSignal` provides:

- atomic aborted flag
- callback registration/unregistration
- at-most-once callback invocation on abort

Clock subscribes once, and on abort it:

1. marks and wakes all pending waiters
2. cancels timer loop future

Equivalent intent: TS abort rejects pending waits and stops future ticking.

### Gossip disparity mirror

`isCurrentSlotGivenGossipDisparity` and
`currentSlotWithGossipDisparity` implement the same acceptance windows:

- current slot accepted directly
- near next boundary: next slot accepted
- just after current boundary: previous slot accepted

All checks use `maximum_gossip_clock_disparity_ms`.

### Time and numeric model

- Public time API is millisecond-based (`u64` for absolute/tolerance inputs).
- `Slot`/`Epoch` are `u64`.
- `computeTimeAtSlotMs`, `msFromSlot`, and `slotWithPastToleranceMs` return
  `error.Overflow` on arithmetic overflow (explicit error path in Zig).

This keeps behavior explicit and predictable in native code while preserving
the same core clock semantics.

### TS -> Zig mapping

- TS `setTimeout(onNextSlot)` -> Zig `timerLoop`
- TS `onNextSlot` recursion -> Zig `onNextSlot` while-catch-up loop
- TS listener callbacks -> Zig `SlotListener` / `EpochListener`
- TS wait promises -> Zig `waitForSlot` future + waiter registry
- TS abort listener -> Zig `AbortSignal.Subscription`
- TS fake timers -> Zig `ManualTimeProvider` + `ClockTimeHooks`

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
