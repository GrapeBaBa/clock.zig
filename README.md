# zig-beacon-clock

Beacon chain slot/epoch clock for Ethereum consensus, implemented in Zig (`0.16.0-dev`, `std.Io`).

Drop-in replacement for Lodestar's TypeScript `Clock` class (`packages/beacon-node/src/util/clock.ts`), with identical catch-up and event semantics.

## Architecture

Three-layer design. Each layer depends only on the one below it.

```
┌─────────────────────────────────────────────────────┐
│  Layer 2 – EventClock            (EventClock.zig)   │
│  Async event loop, listeners, waiters, catch-up     │
├─────────────────────────────────────────────────────┤
│  Layer 1 – SlotClock             (SlotClock.zig)    │
│  Stateful clock, wall-clock reads, AdvanceIterator  │
├─────────────────────────────────────────────────────┤
│  Layer 0 – slot_math             (slot_math.zig)    │
│  Pure arithmetic, no state, no I/O, comptime-safe   │
└─────────────────────────────────────────────────────┘
         TimeSource (time_source.zig) ← injected
```

### Layer 0 — `slot_math.zig`

Pure functions mapping between Unix timestamps, slots, and epochs. No state, no allocation, no I/O. All overflow paths return `null` (`?T`) instead of panicking.

- `slotAtMs`, `slotAtSec` — timestamp → slot
- `epochAtSlot` — slot → epoch
- `slotStartSec`, `slotStartMs` — slot → timestamp
- `msUntilNextSlot` — time until next slot boundary
- `Config` with `validate()` — rejects zero divisors and sec→ms overflow at init time

### Layer 1 — `SlotClock.zig`

Wraps `slot_math` with a `TimeSource` and a cached `current_slot`. Pure-read helpers query wall-clock time; only `advanceTo()` mutates the cache.

- `currentSlot`, `currentEpoch` — wall-clock read (does **not** update cache)
- `currentSlotOrGenesis`, `currentEpochOrGenesis` — returns `0` pre-genesis
- `currentSlotWithGossipDisparity` — bumps to next slot when within `MAXIMUM_GOSSIP_CLOCK_DISPARITY`
- `isCurrentSlotGivenGossipDisparity` — checks both "near next" and "just past current" boundaries
- `slotWithFutureTolerance`, `slotWithPastTolerance` — shifted slot reads
- `secFromSlot`, `msFromSlot` — elapsed time since a slot
- `advanceTo(target) → AdvanceIterator` — steps `current_slot` one-by-one toward `target`, yielding `.slot` and `.epoch` events in order

### Layer 2 — `EventClock.zig`

Async event-driven clock built on `std.Io`. Combines `SlotClock` with a cooperative fiber loop to emit slot/epoch events and dispatch waiters.

**Lifecycle:**

```
init() → onSlot/onEpoch() → start() → ... → stop() → join() → deinit()
```

- `init` — in-place initialization (self-referential struct, not returned by value)
- `start` — spawns `runAutoLoop` fiber via `std.Io.async`. Idempotent
- `stop` — signals loop to exit, aborts all pending waiters. Idempotent
- `join` — awaits loop fiber completion via `Future.cancel`
- `deinit` — calls `stop()` + `join()`, frees all resources

**Listener API:**

```zig
const id = try clock.onSlot(callback, ctx);
_ = clock.offSlot(id);
```

- Slot and epoch listeners registered before `start()` are guaranteed delivery
- Snapshot-based emission prevents iterator invalidation during callbacks
- Listener capacity is pre-allocated — no allocation in the emission hot path

**waitForSlot:**

```zig
var fut = try clock.waitForSlot(target_slot);
errdefer fut.cancel();
try fut.await(io);
```

- Returns immediately if already at or past target slot
- Future-based API backed by `std.Io.Event` + `std.Io.Future`
- Dispatched by `advanceAndDispatch` when `current_slot >= target`
- `fut.cancel()` available for error-path cleanup (releases `WaitState` and removes from waiters list)
- Use `errdefer fut.cancel()` between `waitForSlot` and `await` to guarantee cleanup on error
- Returns `error.Aborted` on `stop()`

**Catch-up semantics (matching TS `get currentSlot()`):**

Every public accessor that exposes "current" slot/epoch state calls `catchUp()` first — the same pattern as the TS version where `get currentSlot()` triggers event emission before returning. This ensures listeners and waiters see events even if the auto-loop hasn't ticked yet.

Affected accessors: `currentSlot`, `currentEpoch`, `currentSlotOrGenesis`, `currentEpochOrGenesis`, `currentSlotWithGossipDisparity`, `isCurrentSlotGivenGossipDisparity`.

Pure arithmetic helpers (`slotWithFutureTolerance`, `slotWithPastTolerance`, `secFromSlot`, `msFromSlot`) do **not** catch up, matching TS which doesn't go through `this.currentSlot` for those.

**Auto-loop (`runAutoLoop`):**

- Sleeps until next slot boundary; `stop()` cancels the sleep future directly via `Future.cancel`
- Skips advancement pre-genesis (`currentSlot()` returns `null`)
- Checks `stopped` flag in `advanceAndDispatch` loop (matches TS's `!this.signal.aborted`)
- Falls back to `self.stop()` + `break` if `msUntilNextSlot` returns `null` (config overflow defense-in-depth)

### `time_source.zig`

Pluggable time source abstraction. `TimeSource.fromIo(*std.Io)` bridges to `std.Io.Clock.real` for production; tests inject fake clocks via function pointer for deterministic control.

## Concurrency model

`std.Io.Evented` runs N:1 cooperative fibers on a single OS thread — the same model as JavaScript's single-threaded event loop. No concurrent access, so `catchUp()` / `advanceAndDispatch` are safe to call from any fiber without synchronization.

## TS semantic alignment

This implementation matches the Lodestar `Clock` class behavior:

| TS pattern | Zig equivalent |
|---|---|
| `get currentSlot()` catches up events before returning | `catchUp()` called in all current-state accessors |
| `onNextSlot` loop checks `!this.signal.aborted` | `advanceAndDispatch` checks `self.stopped` per event |
| `waitForSlot` uses `this.currentSlot` getter (triggers catch-up) | `catchUp()` + `current_slot` fast-path |
| `setTimeout(this.onNextSlot, this.msUntilNextSlot())` | `std.Io.sleep` + `Future.cancel` on stop |
| `slot 0` not emitted pre-genesis | `currentSlot()` returns `null` pre-genesis, loop skips |

## Example

```zig
const std = @import("std");
const clock = @import("zig_beacon_clock");

fn onSlot(_: ?*anyopaque, slot: clock.Slot) void {
    std.debug.print("slot={d}\n", .{slot});
}

fn onEpoch(_: ?*anyopaque, epoch: clock.Epoch) void {
    std.debug.print("epoch={d}\n", .{epoch});
}

pub fn main() !void {
    var evented: std.Io.Evented = undefined;
    try evented.init(std.heap.page_allocator, .{});
    defer evented.deinit();
    const io = evented.io();

    const now_sec: u64 = @intCast(std.Io.Clock.real.now(io).toSeconds());

    var ec: clock.EventClock = undefined;
    try ec.init(std.heap.page_allocator, .{
        .genesis_time_sec = now_sec,
        .seconds_per_slot = 1,
        .slots_per_epoch = 4,
    }, io);
    defer ec.deinit();

    _ = try ec.onSlot(onSlot, null);
    _ = try ec.onEpoch(onEpoch, null);

    ec.start();

    const start_slot = ec.currentSlotOrGenesis();
    std.debug.print("start_slot={d}, waiting for slot {d}...\n", .{ start_slot, start_slot + 3 });

    var fut = try ec.waitForSlot(start_slot + 3);
    errdefer fut.cancel();
    try fut.await(io);

    std.debug.print("done.\n", .{});
}
```

Run with:

```bash
zig build run-example
```

## Build & test

```bash
zig build test
```

Requires Zig `0.16.0-dev` (master) with `std.Io` support.
