const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Beacon chain slot number.
pub const Slot = u64;
/// Beacon chain epoch number.
pub const Epoch = u64;

/// Events emitted by `Clock`.
///
/// The clock emits `slot` every time it advances one slot, and emits `epoch`
/// whenever slot advancement crosses an epoch boundary.
pub const ClockEvent = enum {
    /// Emitted whenever the clock advances to a new slot.
    slot,
    /// Emitted whenever the clock advances to a new epoch.
    epoch,
};

/// Static chain timing configuration used by the clock.
///
/// The clock implementation is pure wall-clock math on top of these constants.
/// No chain state is required once these values and the genesis time are known.
pub const ChainForkConfig = struct {
    /// Milliseconds per slot.
    slot_duration_ms: u64,
    /// Accepted local clock skew for gossip-related checks, in milliseconds.
    maximum_gossip_clock_disparity_ms: u64,
    /// Number of slots per epoch.
    slots_per_epoch: u64,
};

/// Pluggable clock time provider used by `Clock`.
///
/// Most callers should use `TimeProvider.system()` via `Clock.init(...)`.
/// Custom providers are mainly useful for deterministic tests.
pub const TimeProvider = struct {
    /// Opaque pointer passed back into provider callbacks.
    ctx: ?*anyopaque,
    /// Returns current time in unix milliseconds.
    now_ms: *const fn (ctx: ?*anyopaque) u64,
    /// Sleeps for `duration_ms` according to the selected time model.
    sleep_ms: *const fn (ctx: ?*anyopaque, io: Io, duration_ms: u64) Io.Cancelable!void,

    /// Built-in provider backed by real wall clock and real sleep.
    pub fn system() TimeProvider {
        return .{
            .ctx = null,
            .now_ms = realNowMsHook,
            .sleep_ms = realSleepMsHook,
        };
    }
};

/// Deterministic manual time source for tests.
///
/// This mirrors the "manual/stub clock" approach used in other clients:
/// production code can use real time, while tests drive virtual time by
/// calling `advanceMs` or `setNowMs`.
///
/// `provider()` returns `TimeProvider` so the same `Clock` implementation can
/// run against this provider.
pub const ManualTimeProvider = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    now_ms: u64,

    /// Initialize with a deterministic starting timestamp in milliseconds.
    pub fn init(io: Io, now_ms: u64) ManualTimeProvider {
        return .{
            .io = io,
            .now_ms = now_ms,
        };
    }

    /// Return provider consumable by `Clock.initWithTimeProvider`.
    pub fn provider(self: *ManualTimeProvider) TimeProvider {
        return .{
            .ctx = @ptrCast(self),
            .now_ms = nowMsHook,
            .sleep_ms = sleepMsHook,
        };
    }

    /// Set absolute virtual time and wake one blocked sleeper.
    pub fn setNowMs(self: *ManualTimeProvider, now_ms: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.now_ms = now_ms;
        self.condition.signal(self.io);
    }

    /// Advance virtual time forward and wake one blocked sleeper.
    pub fn advanceMs(self: *ManualTimeProvider, delta_ms: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.now_ms = std.math.add(u64, self.now_ms, delta_ms) catch std.math.maxInt(u64);
        self.condition.signal(self.io);
    }

    fn nowMsHook(ctx: ?*anyopaque) u64 {
        const self: *ManualTimeProvider = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.now_ms;
    }

    fn sleepMsHook(ctx: ?*anyopaque, io: Io, duration_ms: u64) Io.Cancelable!void {
        const self: *ManualTimeProvider = @ptrCast(@alignCast(ctx.?));
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const target_ms = std.math.add(u64, self.now_ms, duration_ms) catch std.math.maxInt(u64);
        while (self.now_ms < target_ms) {
            try self.condition.wait(io, &self.mutex);
        }
    }
};

/// Minimal one-shot cancellation primitive.
///
/// This is intentionally smaller than Web `AbortSignal`. It provides exactly
/// what this clock needs:
/// - an atomic aborted flag
/// - callback subscription / unsubscription
/// - guaranteed at-most-once callback invocation after abort
///
/// Internally callbacks are stored in an intrusive linked list (`Subscription`)
/// so registration/removal does not allocate.
pub const AbortSignal = struct {
    aborted_flag: std.atomic.Value(bool) = .init(false),
    io: Io,
    mutex: Io.Mutex = .init,
    head: ?*Subscription = null,

    /// Create an abort signal bound to a concrete IO handle.
    pub fn init(io: Io) AbortSignal {
        return .{ .io = io };
    }

    /// Linked-list node used to subscribe abort callbacks.
    ///
    /// The caller owns the storage and keeps it alive while subscribed.
    pub const Subscription = struct {
        prev: ?*Subscription = null,
        next: ?*Subscription = null,
        callback: *const fn (ctx: *anyopaque) void = undefined,
        ctx: *anyopaque = undefined,
        linked: bool = false,
    };

    /// Transition to aborted state and invoke each registered callback once.
    ///
    /// Implementation notes:
    /// - `swap(true)` makes abort idempotent and thread-safe.
    /// - callbacks list is detached while holding the mutex.
    /// - callbacks are invoked after unlocking, so user code cannot deadlock
    ///   by re-entering signal operations from a callback.
    pub fn abort(self: *AbortSignal) void {
        if (self.aborted_flag.swap(true, .acq_rel)) return;

        self.mutex.lockUncancelable(self.io);
        const node = self.head;
        self.head = null;
        self.mutex.unlock(self.io);

        var current = node;
        while (current) |sub| {
            const next = sub.next;
            sub.prev = null;
            sub.next = null;
            sub.linked = false;
            sub.callback(sub.ctx);
            current = next;
        }
    }

    /// Return whether the signal is already aborted.
    pub fn aborted(self: *const AbortSignal) bool {
        return self.aborted_flag.load(.acquire);
    }

    /// Register an abort callback.
    ///
    /// Returns `false` if already aborted; in that case callback is invoked
    /// immediately in the caller thread so callers do not miss cancellation.
    ///
    /// Returns `true` when successfully linked and pending future abort.
    pub fn onAbort(
        self: *AbortSignal,
        sub: *Subscription,
        ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque) void,
    ) bool {
        if (self.aborted()) {
            callback(ctx);
            return false;
        }

        var invoke_now = false;
        self.mutex.lockUncancelable(self.io);
        if (self.aborted_flag.load(.acquire)) {
            invoke_now = true;
        } else if (!sub.linked) {
            sub.* = .{
                .prev = null,
                .next = self.head,
                .callback = callback,
                .ctx = ctx,
                .linked = true,
            };
            if (self.head) |head| {
                head.prev = sub;
            }
            self.head = sub;
        }
        self.mutex.unlock(self.io);

        if (invoke_now) {
            callback(ctx);
            return false;
        }
        return true;
    }

    /// Remove a previously registered callback if still linked.
    ///
    /// Safe to call multiple times on the same subscription.
    pub fn offAbort(self: *AbortSignal, sub: *Subscription) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!sub.linked) return;

        if (sub.prev) |prev| {
            prev.next = sub.next;
        } else {
            self.head = sub.next;
        }
        if (sub.next) |next| {
            next.prev = sub.prev;
        }
        sub.prev = null;
        sub.next = null;
        sub.linked = false;
    }
};

/// Callback registration for slot events.
pub const SlotListener = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque, slot: Slot) void,
};

/// Callback registration for epoch events.
pub const EpochListener = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque, epoch: Epoch) void,
};

const SlotWaiter = struct {
    target_slot: Slot,
    done: bool = false,
    aborted: bool = false,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
};

/// Chain clock driven by local wall time.
///
/// Working model:
/// - A single timer task (`timerLoop`) sleeps until the next slot boundary.
/// - On wakeup, `onNextSlot` catches up one-or-more missed slots.
/// - Slot listeners and epoch listeners are invoked in-order during catch-up.
/// - `waitForSlot` callers are parked in `waiters` and signaled when reached.
///
///
/// Thread-safety:
/// This type is not safe for concurrent mutation from multiple threads.
/// Use one owner thread / one IO executor for all API calls.
pub const Clock = struct {
    pub const WaitForSlotError = error{Aborted} || Io.Cancelable || Allocator.Error;
    pub const AddSlotListenerError = Allocator.Error;
    pub const AddEpochListenerError = Allocator.Error;

    allocator: Allocator,
    io: Io,
    config: ChainForkConfig,
    genesis_time_ms: u64,
    signal: *AbortSignal,
    time_provider: TimeProvider,

    current_slot_cache: Slot,
    slot_listeners: std.ArrayListUnmanaged(SlotListener) = .{},
    epoch_listeners: std.ArrayListUnmanaged(EpochListener) = .{},
    waiters_mutex: Io.Mutex = .init,
    waiters: std.ArrayListUnmanaged(*SlotWaiter) = .{},
    abort_sub: AbortSignal.Subscription = .{},
    abort_hook_registered: bool = false,
    runner: ?Io.Future(void) = null,

    /// Build a clock instance from static config + genesis time + abort signal.
    ///
    /// Initialization is lazy: no timer task is spawned here. The timer starts
    /// on `start()` or on first API call that requires ticking.
    pub fn init(
        allocator: Allocator,
        io: Io,
        config: ChainForkConfig,
        genesis_time_ms: u64,
        signal: *AbortSignal,
    ) Clock {
        return initWithTimeProvider(allocator, io, config, genesis_time_ms, signal, TimeProvider.system());
    }

    /// Build a clock instance with explicit time provider.
    ///
    /// This is intended for deterministic tests where callers want to control
    /// perceived time and timer wake-ups.
    pub fn initWithTimeProvider(
        allocator: Allocator,
        io: Io,
        config: ChainForkConfig,
        genesis_time_ms: u64,
        signal: *AbortSignal,
        time_provider: TimeProvider,
    ) Clock {
        const initial_now_ms = time_provider.now_ms(time_provider.ctx);
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .genesis_time_ms = genesis_time_ms,
            .signal = signal,
            .time_provider = time_provider,
            .current_slot_cache = getCurrentSlotAtMs(config, genesis_time_ms, initial_now_ms),
        };
    }

    /// Start the background timer loop if not already running.
    ///
    /// Also registers one abort hook once, so external cancellation can stop
    /// timer execution and unblock any pending `waitForSlot`.
    pub fn start(self: *Clock) void {
        if (self.signal.aborted()) return;
        if (self.runner != null) return;

        if (!self.abort_hook_registered) {
            if (!self.signal.onAbort(&self.abort_sub, @ptrCast(self), onAbortSignal)) {
                return;
            }
            self.abort_hook_registered = true;
        }

        self.runner = self.io.async(timerLoop, .{self});
    }

    /// Stop the clock and release all runtime resources.
    ///
    /// Shutdown steps:
    /// - detach abort hook
    /// - mark + signal all waiters as aborted
    /// - cancel running timer future
    /// - free listener/waiter containers
    pub fn deinit(self: *Clock) void {
        if (self.abort_hook_registered) {
            self.signal.offAbort(&self.abort_sub);
            self.abort_hook_registered = false;
        }
        self.abortAllWaiters();
        if (self.runner) |*runner| {
            runner.cancel(self.io);
            self.runner = null;
        }
        self.slot_listeners.deinit(self.allocator);
        self.epoch_listeners.deinit(self.allocator);
        self.waiters.deinit(self.allocator);
    }

    /// Register a slot listener.
    ///
    /// Listener is invoked once per advanced slot and receives the slot value.
    /// Registration does not replay historical slots.
    pub fn onSlot(self: *Clock, listener: SlotListener) AddSlotListenerError!void {
        self.ensureStarted();
        try self.slot_listeners.append(self.allocator, listener);
    }

    /// Register an epoch listener.
    ///
    /// Listener is invoked when slot advancement crosses into a new epoch.
    /// Registration does not replay historical epochs.
    pub fn onEpoch(self: *Clock, listener: EpochListener) AddEpochListenerError!void {
        self.ensureStarted();
        try self.epoch_listeners.append(self.allocator, listener);
    }

    /// Unregister a slot listener.
    pub fn offSlot(self: *Clock, listener: SlotListener) void {
        var i: usize = 0;
        while (i < self.slot_listeners.items.len) : (i += 1) {
            const item = self.slot_listeners.items[i];
            if (item.ctx == listener.ctx and item.callback == listener.callback) {
                _ = self.slot_listeners.swapRemove(i);
                return;
            }
        }
    }

    /// Unregister an epoch listener.
    pub fn offEpoch(self: *Clock, listener: EpochListener) void {
        var i: usize = 0;
        while (i < self.epoch_listeners.items.len) : (i += 1) {
            const item = self.epoch_listeners.items[i];
            if (item.ctx == listener.ctx and item.callback == listener.callback) {
                _ = self.epoch_listeners.swapRemove(i);
                return;
            }
        }
    }

    /// Return the current slot and keep internal state caught up.
    ///
    /// If wall-clock time jumped ahead (for example process stalled or system
    /// resumed), the method immediately:
    /// - rearms timer alignment
    /// - performs synchronous catch-up via `onNextSlot`
    ///
    /// This preserves TS behavior where missed slots are emitted in order.
    pub fn currentSlot(self: *Clock) Slot {
        self.ensureStarted();
        const slot = getCurrentSlotAtMs(self.config, self.genesis_time_ms, self.nowMs());
        if (slot > self.current_slot_cache) {
            self.rearmTimer();
            self.onNextSlot(slot);
        }
        return slot;
    }

    /// Return current slot with "near-boundary next-slot" tolerance.
    ///
    /// If the next slot starts within `maximum_gossip_clock_disparity_ms`,
    /// return `current_slot + 1` to match gossip timing acceptance rules.
    pub fn currentSlotWithGossipDisparity(self: *Clock) Slot {
        const current_slot = self.currentSlot();
        const next_slot_time_ms = computeTimeAtSlotMs(self.config, current_slot + 1, self.genesis_time_ms) catch {
            return current_slot;
        };
        const now_ms = self.nowMs();
        if (next_slot_time_ms > now_ms and next_slot_time_ms - now_ms < self.config.maximum_gossip_clock_disparity_ms) {
            return current_slot + 1;
        }
        return current_slot;
    }

    /// Return epoch derived from `currentSlot()`.
    pub fn currentEpoch(self: *Clock) Epoch {
        return computeEpochAtSlot(self.config, self.currentSlot());
    }

    /// Return slot as if local clock were advanced by `tolerance_ms`.
    ///
    /// Implemented by shifting genesis backwards, equivalent to `now+tolerance`.
    pub fn slotWithFutureToleranceMs(self: *Clock, tolerance_ms: u64) Slot {
        const adjusted_genesis_ms = self.genesis_time_ms -| tolerance_ms;
        return getCurrentSlotAtMs(self.config, adjusted_genesis_ms, self.nowMs());
    }

    /// Return slot as if local clock were reversed by `tolerance_ms`.
    ///
    /// Implemented by shifting genesis forwards, equivalent to `now-tolerance`.
    pub fn slotWithPastToleranceMs(self: *Clock, tolerance_ms: u64) error{Overflow}!Slot {
        const adjusted_genesis_ms = try std.math.add(u64, self.genesis_time_ms, tolerance_ms);
        return getCurrentSlotAtMs(self.config, adjusted_genesis_ms, self.nowMs());
    }

    /// Check whether a candidate `slot` is acceptable under gossip skew rules.
    ///
    /// Acceptance window:
    /// - exact current slot: always valid
    /// - next slot: valid close to next boundary
    /// - previous slot: valid just after current boundary
    pub fn isCurrentSlotGivenGossipDisparity(self: *Clock, slot: Slot) bool {
        const current_slot = self.currentSlot();
        if (current_slot == slot) {
            return true;
        }

        const now_ms = self.nowMs();
        const next_slot_time_ms = computeTimeAtSlotMs(self.config, current_slot + 1, self.genesis_time_ms) catch {
            return false;
        };
        if (next_slot_time_ms > now_ms and next_slot_time_ms - now_ms < self.config.maximum_gossip_clock_disparity_ms) {
            return slot == current_slot + 1;
        }

        const current_slot_time_ms = computeTimeAtSlotMs(self.config, current_slot, self.genesis_time_ms) catch {
            return false;
        };
        if (now_ms >= current_slot_time_ms and now_ms - current_slot_time_ms < self.config.maximum_gossip_clock_disparity_ms) {
            if (current_slot == 0) return false;
            return slot == current_slot - 1;
        }

        return false;
    }

    /// Asynchronously wait until `currentSlot() >= slot`.
    ///
    /// Implementation uses a per-waiter condition variable and a shared waiter
    /// registry. Waiters are resolved by `onNextSlot` and aborted by signal.
    /// Completes with `error.Aborted` if cancellation happens first.
    pub fn waitForSlot(self: *Clock, slot: Slot) Io.Future(WaitForSlotError!void) {
        return self.io.async(waitForSlotTask, .{ self, slot });
    }

    /// Milliseconds elapsed from slot start to `to_ms` (or now if null).
    pub fn msFromSlot(self: *const Clock, slot: Slot, to_ms: ?u64) error{Overflow}!i64 {
        const to = to_ms orelse self.nowMs();
        return try diffI64(to, try computeTimeAtSlotMs(self.config, slot, self.genesis_time_ms));
    }

    /// Main scheduling loop.
    ///
    /// Repeats forever:
    /// - exit early if aborted
    /// - catch up to current time
    /// - sleep until next slot boundary
    fn timerLoop(self: *Clock) void {
        while (true) {
            if (self.signal.aborted()) {
                self.abortAllWaiters();
                self.runner = null;
                return;
            }

            // Catch up first so a late-started/rearmed loop does not miss the
            // slot that is already due at current wall time.
            self.onNextSlot(null);
            self.sleepMs(self.msUntilNextSlot()) catch return;
        }
    }

    /// Worker for a single `waitForSlot` request.
    ///
    /// Fast path returns immediately if target already reached. Otherwise this
    /// registers waiter state, forces one synchronous catch-up check, and then
    /// blocks on condition variable until resolved or aborted.
    fn waitForSlotTask(self: *Clock, slot: Slot) WaitForSlotError!void {
        self.ensureStarted();
        if (self.signal.aborted()) return error.Aborted;
        if (self.currentSlot() >= slot) return;

        var waiter: SlotWaiter = .{ .target_slot = slot };
        try self.registerWaiter(&waiter);
        defer self.unregisterWaiter(&waiter);

        _ = self.currentSlot();

        try waiter.mutex.lock(self.io);
        defer waiter.mutex.unlock(self.io);
        while (!waiter.done and !waiter.aborted and !self.signal.aborted()) {
            try waiter.condition.wait(self.io, &waiter.mutex);
        }

        if (waiter.aborted or self.signal.aborted()) {
            return error.Aborted;
        }
    }

    /// Advance internal slot state up to `clock_slot`.
    ///
    /// When multiple slots were missed, this loops through each slot so event
    /// ordering and epoch-boundary notifications remain deterministic.
    fn onNextSlot(self: *Clock, slot: ?Slot) void {
        const clock_slot = slot orelse getCurrentSlotAtMs(self.config, self.genesis_time_ms, self.nowMs());
        while (self.current_slot_cache < clock_slot and !self.signal.aborted()) {
            const previous_slot = self.current_slot_cache;
            self.current_slot_cache += 1;

            self.emitSlot(self.current_slot_cache);
            self.resolveWaitersAtSlot(self.current_slot_cache);

            const previous_epoch = computeEpochAtSlot(self.config, previous_slot);
            const current_epoch = computeEpochAtSlot(self.config, self.current_slot_cache);
            if (previous_epoch < current_epoch) {
                self.emitEpoch(current_epoch);
            }
        }
    }

    fn emitSlot(self: *Clock, slot: Slot) void {
        for (self.slot_listeners.items) |listener| {
            listener.callback(listener.ctx, slot);
        }
    }

    fn emitEpoch(self: *Clock, epoch: Epoch) void {
        for (self.epoch_listeners.items) |listener| {
            listener.callback(listener.ctx, epoch);
        }
    }

    /// Compute delay in milliseconds until the next slot boundary.
    ///
    /// Uses modulo arithmetic against `slot_duration_ms` and genesis origin.
    fn msUntilNextSlot(self: *const Clock) u64 {
        const now_ms = self.nowMs();
        if (now_ms < self.genesis_time_ms) {
            return self.genesis_time_ms - now_ms;
        }
        const diff_ms = now_ms - self.genesis_time_ms;
        const slot_ms = self.config.slot_duration_ms;
        if (slot_ms == 0) return 0;
        const rem = @mod(diff_ms, slot_ms);
        if (rem == 0) return slot_ms;
        return slot_ms - rem;
    }

    fn nowMs(self: *const Clock) u64 {
        return self.time_provider.now_ms(self.time_provider.ctx);
    }

    fn sleepMs(self: *Clock, duration_ms: u64) Io.Cancelable!void {
        return self.time_provider.sleep_ms(self.time_provider.ctx, self.io, duration_ms);
    }

    fn registerWaiter(self: *Clock, waiter: *SlotWaiter) WaitForSlotError!void {
        self.waiters_mutex.lockUncancelable(self.io);
        defer self.waiters_mutex.unlock(self.io);
        try self.waiters.append(self.allocator, waiter);
    }

    fn unregisterWaiter(self: *Clock, waiter: *SlotWaiter) void {
        self.waiters_mutex.lockUncancelable(self.io);
        defer self.waiters_mutex.unlock(self.io);

        var i: usize = 0;
        while (i < self.waiters.items.len) : (i += 1) {
            if (self.waiters.items[i] == waiter) {
                _ = self.waiters.swapRemove(i);
                return;
            }
        }
    }

    /// Resolve and wake all waiters whose target slot has been reached.
    fn resolveWaitersAtSlot(self: *Clock, slot: Slot) void {
        self.waiters_mutex.lockUncancelable(self.io);
        defer self.waiters_mutex.unlock(self.io);

        var i: usize = 0;
        while (i < self.waiters.items.len) {
            const waiter = self.waiters.items[i];
            if (slot >= waiter.target_slot) {
                waiter.mutex.lockUncancelable(self.io);
                waiter.done = true;
                waiter.condition.signal(self.io);
                waiter.mutex.unlock(self.io);
                _ = self.waiters.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Abort and wake every pending waiter.
    fn abortAllWaiters(self: *Clock) void {
        self.waiters_mutex.lockUncancelable(self.io);
        defer self.waiters_mutex.unlock(self.io);

        for (self.waiters.items) |waiter| {
            waiter.mutex.lockUncancelable(self.io);
            waiter.aborted = true;
            waiter.condition.signal(self.io);
            waiter.mutex.unlock(self.io);
        }
        self.waiters.clearRetainingCapacity();
    }

    /// Lazily ensure timer loop is running unless already aborted.
    fn ensureStarted(self: *Clock) void {
        if (self.signal.aborted()) return;
        if (self.runner == null) self.start();
    }

    /// Cancel and restart timer loop to re-align boundary timing.
    fn rearmTimer(self: *Clock) void {
        if (self.signal.aborted()) return;
        if (self.runner) |*runner| {
            runner.cancel(self.io);
            self.runner = null;
        }
        self.start();
    }

    /// Abort callback registered in `start`.
    ///
    /// Cancels runner and wakes waiters so all in-flight waits terminate.
    fn onAbortSignal(ctx: *anyopaque) void {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        self.abortAllWaiters();
        if (self.runner) |*runner| {
            runner.cancel(self.io);
            self.runner = null;
        }
    }
};

/// Convert a slot number to its containing epoch.
///
/// Returns `0` when `slots_per_epoch == 0` to avoid division by zero and keep
/// behavior deterministic for invalid config.
pub fn computeEpochAtSlot(config: ChainForkConfig, slot: Slot) Epoch {
    if (config.slots_per_epoch == 0) return 0;
    return slot / config.slots_per_epoch;
}

/// Compute unix time (milliseconds) for the start boundary of `slot`.
///
/// Returns `error.Overflow` on arithmetic overflow.
pub fn computeTimeAtSlotMs(config: ChainForkConfig, slot: Slot, genesis_time_ms: u64) error{Overflow}!u64 {
    const delta_ms = try std.math.mul(u64, slot, config.slot_duration_ms);
    return try std.math.add(u64, genesis_time_ms, delta_ms);
}

/// Compute current slot from wall clock and genesis time.
///
/// Returns `0` before genesis or when `slot_duration_ms == 0`.
/// Otherwise computes `floor((now_ms - genesis_ms) / slot_duration_ms)`.
pub fn getCurrentSlot(config: ChainForkConfig, genesis_time_ms: u64) Slot {
    return getCurrentSlotAtMs(config, genesis_time_ms, realNowMs());
}

/// Compute current slot using explicit `now_ms` input.
///
/// This is the pure helper used by injected/fake time sources.
pub fn getCurrentSlotAtMs(config: ChainForkConfig, genesis_time_ms: u64, now_ms: u64) Slot {
    if (now_ms <= genesis_time_ms) return 0;
    if (config.slot_duration_ms == 0) return 0;
    return (now_ms - genesis_time_ms) / config.slot_duration_ms;
}

fn realNowMs() u64 {
    const timestamp = Io.Clock.real.now(std.Options.debug_io);
    return @as(u64, @intCast(@divTrunc(timestamp.nanoseconds, std.time.ns_per_ms)));
}

fn realNowMsHook(ctx: ?*anyopaque) u64 {
    _ = ctx;
    return realNowMs();
}

fn realSleepMsHook(ctx: ?*anyopaque, io: Io, duration_ms: u64) Io.Cancelable!void {
    _ = ctx;
    const sleep_ms_i64 = std.math.cast(i64, duration_ms) orelse std.math.maxInt(i64);
    try io.sleep(.fromMilliseconds(sleep_ms_i64), .awake);
}

fn diffI64(a: u64, b: u64) error{Overflow}!i64 {
    const diff = @as(i128, @intCast(a)) - @as(i128, @intCast(b));
    return std.math.cast(i64, diff) orelse error.Overflow;
}

test "computeEpochAtSlot boundaries" {
    const config = ChainForkConfig{
        .slot_duration_ms = 12_000,
        .maximum_gossip_clock_disparity_ms = 500,
        .slots_per_epoch = 32,
    };

    try std.testing.expectEqual(@as(Epoch, 0), computeEpochAtSlot(config, 0));
    try std.testing.expectEqual(@as(Epoch, 0), computeEpochAtSlot(config, 31));
    try std.testing.expectEqual(@as(Epoch, 1), computeEpochAtSlot(config, 32));
    try std.testing.expectEqual(@as(Epoch, 1), computeEpochAtSlot(config, 63));
    try std.testing.expectEqual(@as(Epoch, 2), computeEpochAtSlot(config, 64));
}

test "computeEpochAtSlot returns zero when slots_per_epoch is zero" {
    const config = ChainForkConfig{
        .slot_duration_ms = 12_000,
        .maximum_gossip_clock_disparity_ms = 500,
        .slots_per_epoch = 0,
    };

    try std.testing.expectEqual(@as(Epoch, 0), computeEpochAtSlot(config, 12_345));
}

test "computeTimeAtSlotMs derives milliseconds" {
    const config = ChainForkConfig{
        .slot_duration_ms = 12_000,
        .maximum_gossip_clock_disparity_ms = 500,
        .slots_per_epoch = 32,
    };
    const genesis_time_ms: u64 = 1_700_000_000_000;

    try std.testing.expectEqual(@as(u64, 1_700_000_024_000), try computeTimeAtSlotMs(config, 2, genesis_time_ms));
}

test "getCurrentSlot clamps to zero before genesis" {
    const config = ChainForkConfig{
        .slot_duration_ms = 1_000,
        .maximum_gossip_clock_disparity_ms = 500,
        .slots_per_epoch = 32,
    };
    const genesis_time_ms = realNowMs() + 60_000;

    try std.testing.expectEqual(@as(Slot, 0), getCurrentSlot(config, genesis_time_ms));
}

test "getCurrentSlot returns zero for non-positive slot duration" {
    const config = ChainForkConfig{
        .slot_duration_ms = 0,
        .maximum_gossip_clock_disparity_ms = 500,
        .slots_per_epoch = 32,
    };

    try std.testing.expectEqual(@as(Slot, 0), getCurrentSlot(config, realNowMs() - 10_000));
}

fn testSlotListener(ctx: *anyopaque, slot: Slot) void {
    _ = ctx;
    _ = slot;
}

fn testEpochListener(ctx: *anyopaque, epoch: Epoch) void {
    _ = ctx;
    _ = epoch;
}

const RecordedEventKind = enum {
    slot,
    epoch,
};

const RecordedEvent = struct {
    kind: RecordedEventKind,
    value: u64,
};

const EventRecorder = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    len: usize = 0,
    events: [64]RecordedEvent = undefined,

    fn init(io: Io) EventRecorder {
        return .{ .io = io };
    }

    fn onSlot(ctx: *anyopaque, slot: Slot) void {
        const self: *EventRecorder = @ptrCast(@alignCast(ctx));
        self.push(.{ .kind = .slot, .value = slot });
    }

    fn onEpoch(ctx: *anyopaque, epoch: Epoch) void {
        const self: *EventRecorder = @ptrCast(@alignCast(ctx));
        self.push(.{ .kind = .epoch, .value = epoch });
    }

    fn push(self: *EventRecorder, event: RecordedEvent) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.len < self.events.len);
        self.events[self.len] = event;
        self.len += 1;
        self.condition.signal(self.io);
    }

    fn waitForLen(self: *EventRecorder, io: Io, target_len: usize) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (self.len < target_len) {
            try self.condition.wait(io, &self.mutex);
        }
    }

    fn expect(self: *EventRecorder, expected: []const RecordedEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try std.testing.expectEqual(expected.len, self.len);
        var i: usize = 0;
        while (i < expected.len) : (i += 1) {
            try std.testing.expectEqual(expected[i].kind, self.events[i].kind);
            try std.testing.expectEqual(expected[i].value, self.events[i].value);
        }
    }
};

test "clock smoke compiles and exercises async paths on master" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var signal = AbortSignal.init(threaded.io());

    const genesis_time_ms = realNowMs();

    var clock = Clock.init(
        std.testing.allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 1000,
            .maximum_gossip_clock_disparity_ms = 500,
            .slots_per_epoch = 32,
        },
        genesis_time_ms,
        &signal,
    );
    defer clock.deinit();

    try clock.onSlot(.{ .ctx = @ptrCast(&clock), .callback = testSlotListener });
    try clock.onEpoch(.{ .ctx = @ptrCast(&clock), .callback = testEpochListener });
    clock.offSlot(.{ .ctx = @ptrCast(&clock), .callback = testSlotListener });
    clock.offEpoch(.{ .ctx = @ptrCast(&clock), .callback = testEpochListener });

    const slot = clock.currentSlot();
    _ = clock.currentSlotWithGossipDisparity();
    _ = clock.currentEpoch();
    _ = clock.slotWithFutureToleranceMs(1_000);
    _ = try clock.slotWithPastToleranceMs(1_000);
    _ = clock.isCurrentSlotGivenGossipDisparity(slot);
    _ = try clock.msFromSlot(slot, null);

    var wait_for_now = clock.waitForSlot(slot);
    try wait_for_now.await(threaded.io());

    signal.abort();
}

test "clock can be driven by manual time provider" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var signal = AbortSignal.init(threaded.io());

    var manual_time = ManualTimeProvider.init(threaded.io(), 50_000);

    var clock = Clock.initWithTimeProvider(
        std.testing.allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 1_000,
            .maximum_gossip_clock_disparity_ms = 500,
            .slots_per_epoch = 32,
        },
        50_000,
        &signal,
        manual_time.provider(),
    );
    defer clock.deinit();

    try std.testing.expectEqual(@as(Slot, 0), clock.currentSlot());

    const started_real_ms = realNowMs();
    var wait_for_slot = clock.waitForSlot(3);

    manual_time.advanceMs(1_000);
    manual_time.advanceMs(1_000);
    manual_time.advanceMs(1_000);

    try wait_for_slot.await(threaded.io());

    try std.testing.expectEqual(@as(Slot, 3), clock.currentSlot());
    try std.testing.expectEqual(@as(i64, 0), try clock.msFromSlot(3, null));

    const elapsed_real_ms = realNowMs() - started_real_ms;
    try std.testing.expect(elapsed_real_ms < 250);

    signal.abort();
}

test "waitForSlot abort path resolves and releases waiter" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var signal = AbortSignal.init(threaded.io());

    var manual_time = ManualTimeProvider.init(threaded.io(), 10_000);
    var clock = Clock.initWithTimeProvider(
        std.testing.allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 1_000,
            .maximum_gossip_clock_disparity_ms = 500,
            .slots_per_epoch = 32,
        },
        10_000,
        &signal,
        manual_time.provider(),
    );
    defer clock.deinit();

    var wait_for_slot = clock.waitForSlot(10);

    const deadline_ms = realNowMs() + 250;
    while (realNowMs() < deadline_ms) {
        var waiter_len: usize = 0;
        clock.waiters_mutex.lockUncancelable(threaded.io());
        waiter_len = clock.waiters.items.len;
        clock.waiters_mutex.unlock(threaded.io());
        if (waiter_len > 0) break;
        try threaded.io().sleep(.fromMilliseconds(1), .awake);
    }

    signal.abort();
    try std.testing.expectError(error.Aborted, wait_for_slot.await(threaded.io()));

    clock.waiters_mutex.lockUncancelable(threaded.io());
    defer clock.waiters_mutex.unlock(threaded.io());
    try std.testing.expectEqual(@as(usize, 0), clock.waiters.items.len);
}

test "manual time tick emits deterministic slot and epoch order step-by-step" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var signal = AbortSignal.init(threaded.io());

    var manual_time = ManualTimeProvider.init(threaded.io(), 100_000);
    var recorder = EventRecorder.init(threaded.io());

    var clock = Clock.initWithTimeProvider(
        std.testing.allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 1_000,
            .maximum_gossip_clock_disparity_ms = 500,
            .slots_per_epoch = 4,
        },
        100_000,
        &signal,
        manual_time.provider(),
    );
    defer clock.deinit();

    try clock.onSlot(.{ .ctx = @ptrCast(&recorder), .callback = EventRecorder.onSlot });
    try clock.onEpoch(.{ .ctx = @ptrCast(&recorder), .callback = EventRecorder.onEpoch });

    {
        var wait_for_1 = clock.waitForSlot(1);
        manual_time.advanceMs(1_000);
        try wait_for_1.await(threaded.io());
        try recorder.waitForLen(threaded.io(), 1);
        const expected = [_]RecordedEvent{
            .{ .kind = .slot, .value = 1 },
        };
        try recorder.expect(expected[0..]);
    }

    {
        var wait_for_2 = clock.waitForSlot(2);
        manual_time.advanceMs(1_000);
        try wait_for_2.await(threaded.io());
        try recorder.waitForLen(threaded.io(), 2);
        const expected = [_]RecordedEvent{
            .{ .kind = .slot, .value = 1 },
            .{ .kind = .slot, .value = 2 },
        };
        try recorder.expect(expected[0..]);
    }

    {
        var wait_for_3 = clock.waitForSlot(3);
        manual_time.advanceMs(1_000);
        try wait_for_3.await(threaded.io());
        try recorder.waitForLen(threaded.io(), 3);
        const expected = [_]RecordedEvent{
            .{ .kind = .slot, .value = 1 },
            .{ .kind = .slot, .value = 2 },
            .{ .kind = .slot, .value = 3 },
        };
        try recorder.expect(expected[0..]);
    }

    {
        var wait_for_4 = clock.waitForSlot(4);
        manual_time.advanceMs(1_000);
        try wait_for_4.await(threaded.io());
        try recorder.waitForLen(threaded.io(), 5);
        const expected = [_]RecordedEvent{
            .{ .kind = .slot, .value = 1 },
            .{ .kind = .slot, .value = 2 },
            .{ .kind = .slot, .value = 3 },
            .{ .kind = .slot, .value = 4 },
            .{ .kind = .epoch, .value = 1 },
        };
        try recorder.expect(expected[0..]);
    }

    {
        var wait_for_5 = clock.waitForSlot(5);
        manual_time.advanceMs(1_000);
        try wait_for_5.await(threaded.io());
        try recorder.waitForLen(threaded.io(), 6);
        const expected = [_]RecordedEvent{
            .{ .kind = .slot, .value = 1 },
            .{ .kind = .slot, .value = 2 },
            .{ .kind = .slot, .value = 3 },
            .{ .kind = .slot, .value = 4 },
            .{ .kind = .epoch, .value = 1 },
            .{ .kind = .slot, .value = 5 },
        };
        try recorder.expect(expected[0..]);
    }

    signal.abort();
}

test "currentSlot single call catches up multiple missed slots in order" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var signal = AbortSignal.init(threaded.io());

    var manual_time = ManualTimeProvider.init(threaded.io(), 200_000);
    var recorder = EventRecorder.init(threaded.io());

    var clock = Clock.initWithTimeProvider(
        std.testing.allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 1_000,
            .maximum_gossip_clock_disparity_ms = 500,
            .slots_per_epoch = 4,
        },
        200_000,
        &signal,
        manual_time.provider(),
    );
    defer clock.deinit();

    try clock.onSlot(.{ .ctx = @ptrCast(&recorder), .callback = EventRecorder.onSlot });
    try clock.onEpoch(.{ .ctx = @ptrCast(&recorder), .callback = EventRecorder.onEpoch });

    try std.testing.expectEqual(@as(Slot, 0), clock.currentSlot());

    manual_time.advanceMs(5_000);

    try std.testing.expectEqual(@as(Slot, 5), clock.currentSlot());
    try recorder.waitForLen(threaded.io(), 6);

    const expected = [_]RecordedEvent{
        .{ .kind = .slot, .value = 1 },
        .{ .kind = .slot, .value = 2 },
        .{ .kind = .slot, .value = 3 },
        .{ .kind = .slot, .value = 4 },
        .{ .kind = .epoch, .value = 1 },
        .{ .kind = .slot, .value = 5 },
    };
    try recorder.expect(expected[0..]);

    signal.abort();
}

test "currentSlot rearm restores next-slot cadence after catch-up" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var signal = AbortSignal.init(threaded.io());

    var manual_time = ManualTimeProvider.init(threaded.io(), 300_000);
    var recorder = EventRecorder.init(threaded.io());

    var clock = Clock.initWithTimeProvider(
        std.testing.allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 1_000,
            .maximum_gossip_clock_disparity_ms = 500,
            .slots_per_epoch = 4,
        },
        300_000,
        &signal,
        manual_time.provider(),
    );
    defer clock.deinit();

    try clock.onSlot(.{ .ctx = @ptrCast(&recorder), .callback = EventRecorder.onSlot });
    try clock.onEpoch(.{ .ctx = @ptrCast(&recorder), .callback = EventRecorder.onEpoch });

    try std.testing.expectEqual(@as(Slot, 0), clock.currentSlot());

    // Jump forward, then use currentSlot() to trigger rearm + synchronous catch-up.
    manual_time.advanceMs(5_000);
    try std.testing.expectEqual(@as(Slot, 5), clock.currentSlot());
    try recorder.waitForLen(threaded.io(), 6);

    // Before the full 1_000ms boundary, no new slot should fire.
    manual_time.advanceMs(999);
    const before_boundary = [_]RecordedEvent{
        .{ .kind = .slot, .value = 1 },
        .{ .kind = .slot, .value = 2 },
        .{ .kind = .slot, .value = 3 },
        .{ .kind = .slot, .value = 4 },
        .{ .kind = .epoch, .value = 1 },
        .{ .kind = .slot, .value = 5 },
    };
    try recorder.expect(before_boundary[0..]);

    // Hitting the last 1ms should trigger exactly the next slot.
    manual_time.advanceMs(1);
    const deadline_ms = realNowMs() + 250;
    while (realNowMs() < deadline_ms) {
        var current_len: usize = 0;
        recorder.mutex.lockUncancelable(threaded.io());
        current_len = recorder.len;
        recorder.mutex.unlock(threaded.io());
        if (current_len >= 7) break;
        try threaded.io().sleep(.fromMilliseconds(1), .awake);
    }

    recorder.mutex.lockUncancelable(threaded.io());
    const final_len = recorder.len;
    recorder.mutex.unlock(threaded.io());
    try std.testing.expectEqual(@as(usize, 7), final_len);

    const after_boundary = [_]RecordedEvent{
        .{ .kind = .slot, .value = 1 },
        .{ .kind = .slot, .value = 2 },
        .{ .kind = .slot, .value = 3 },
        .{ .kind = .slot, .value = 4 },
        .{ .kind = .epoch, .value = 1 },
        .{ .kind = .slot, .value = 5 },
        .{ .kind = .slot, .value = 6 },
    };
    try recorder.expect(after_boundary[0..]);

    signal.abort();
}

fn abortAfter(io: Io, signal: *AbortSignal, timeout_ms: i64) Io.Cancelable!void {
    io.sleep(.fromMilliseconds(timeout_ms), .awake) catch return;
    signal.abort();
}

test "system timer waitForSlot reaches target slot" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var signal = AbortSignal.init(threaded.io());

    var clock = Clock.init(
        std.testing.allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 20,
            .maximum_gossip_clock_disparity_ms = 5,
            .slots_per_epoch = 4,
        },
        realNowMs(),
        &signal,
    );
    defer clock.deinit();

    var watchdog = threaded.io().async(abortAfter, .{ threaded.io(), &signal, 5_000 });
    defer _ = watchdog.cancel(threaded.io()) catch {};

    const start_slot = clock.currentSlot();
    const target_slot = start_slot + 3;

    var wait_for_target = clock.waitForSlot(target_slot);
    try wait_for_target.await(threaded.io());

    try std.testing.expect(clock.currentSlot() >= target_slot);
}

test "system timer slot listener emits ordered sequence" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var signal = AbortSignal.init(threaded.io());
    var recorder = EventRecorder.init(threaded.io());

    var clock = Clock.init(
        std.testing.allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 20,
            .maximum_gossip_clock_disparity_ms = 5,
            .slots_per_epoch = 4,
        },
        realNowMs(),
        &signal,
    );
    defer clock.deinit();

    try clock.onSlot(.{ .ctx = @ptrCast(&recorder), .callback = EventRecorder.onSlot });

    var watchdog = threaded.io().async(abortAfter, .{ threaded.io(), &signal, 5_000 });
    defer _ = watchdog.cancel(threaded.io()) catch {};

    const base_slot = clock.currentSlot();
    const target_slot = base_slot + 4;

    var wait_for_target = clock.waitForSlot(target_slot);
    try wait_for_target.await(threaded.io());

    recorder.mutex.lockUncancelable(threaded.io());
    defer recorder.mutex.unlock(threaded.io());

    const expected_min_len = std.math.cast(usize, target_slot - base_slot) orelse unreachable;
    try std.testing.expect(recorder.len >= expected_min_len);

    var i: usize = 0;
    while (i < recorder.len) : (i += 1) {
        try std.testing.expectEqual(RecordedEventKind.slot, recorder.events[i].kind);
        if (i > 0) {
            try std.testing.expectEqual(recorder.events[i - 1].value + 1, recorder.events[i].value);
        }
    }
    try std.testing.expect(recorder.events[recorder.len - 1].value >= target_slot);
}

test "system timer currentSlot catches up after paused timer loop" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var signal = AbortSignal.init(threaded.io());
    var recorder = EventRecorder.init(threaded.io());

    var clock = Clock.init(
        std.testing.allocator,
        threaded.io(),
        .{
            .slot_duration_ms = 25,
            .maximum_gossip_clock_disparity_ms = 5,
            .slots_per_epoch = 4,
        },
        realNowMs(),
        &signal,
    );
    defer clock.deinit();

    try clock.onSlot(.{ .ctx = @ptrCast(&recorder), .callback = EventRecorder.onSlot });

    const start_slot = clock.currentSlot();

    // Emulate a process stall by stopping the timer loop while wall time keeps advancing.
    if (clock.runner) |*runner| {
        _ = runner.cancel(threaded.io());
        clock.runner = null;
    }

    try threaded.io().sleep(.fromMilliseconds(180), .awake);

    const caught_up_slot = clock.currentSlot();
    try std.testing.expect(caught_up_slot >= start_slot + 4);

    // Freeze again before assertions so background ticking cannot race this check.
    if (clock.runner) |*runner| {
        _ = runner.cancel(threaded.io());
        clock.runner = null;
    }

    recorder.mutex.lockUncancelable(threaded.io());
    defer recorder.mutex.unlock(threaded.io());

    try std.testing.expect(recorder.len >= 4);
    var i: usize = 1;
    while (i < recorder.len) : (i += 1) {
        try std.testing.expectEqual(RecordedEventKind.slot, recorder.events[i - 1].kind);
        try std.testing.expectEqual(RecordedEventKind.slot, recorder.events[i].kind);
        try std.testing.expect(recorder.events[i].value > recorder.events[i - 1].value);
    }
    try std.testing.expect(recorder.events[recorder.len - 1].value >= caught_up_slot);
}
