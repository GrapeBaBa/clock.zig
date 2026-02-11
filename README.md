# clock.zig

A beacon slot clock in Zig.

## Build and Run

```bash
zig build test
zig build run-example
```


## How It Works

1. Timer loop:
   - A single async loop sleeps until the next slot boundary.
   - On wakeup it advances clock state.
2. Catch-up:
   - If time jumps forward, clock advances missing slots one by one.
   - This keeps slot and epoch events deterministic.
3. Event order per slot:
   - increment slot cache
   - emit slot event
   - resolve pending waiters
   - emit epoch event if boundary crossed
4. Wait API:
   - `waitForSlot(target)` returns when `currentSlot() >= target`.
   - Abort wakes waiters and returns `error.Aborted`.

## Testing

Use `ManualTimeProvider` for deterministic tests:

- construct with `Clock.initWithTimeProvider(..., manual_time.provider())`
- drive virtual time via `manual_time.advanceMs(...)`
- assert event order and waiter behavior without real-time delays
