"""Offline coordinator model. No live adapter, launcher, timer host or authorization.

A future host must keep this owner and its independent scheduler outside the GUI
runtime. Passing fake-adapter checks does not establish a supported live stop path.
Model events require serialized state transitions and atomically fenced command
dispatch. These classes are not a thread-safe timer host or a real control adapter.
The injected timing defaults are test parameters, not the Release acceptance procedure.
"""
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
from typing import Callable, Protocol


@dataclass(frozen=True)
class ClockReading:
    seconds: float
    domain: str


@dataclass(frozen=True)
class StopCapability:
    exact_target: str
    idempotent: bool
    independent_of_gui: bool
    works_with_window_closed: bool


class StopAdapter(Protocol):
    capability: StopCapability

    def request_pause(self, target: str) -> None: ...


class Scheduler(Protocol):
    def at(self, deadline: float, callback: Callable[[], None]) -> Callable[[], None]:
        """Arm outside the GUI runtime; return cancellation, never a GUI task."""
        ...

    def dispatch_before(self, deadline: float, pending: Callable[[], bool], action: Callable[[], None]) -> bool:
        """Atomically order bounded dispatch against expiry; never hold through an await.

        A future host must fence late Play delivery after Pause as well. A flag
        check on a GUI thread is insufficient. No such live host is supplied here.
        """
        ...


class PrivateJournal:
    """Append-only private JSONL receipts; an existing path cannot be overwritten."""

    def __init__(self, path):
        path = Path(path)
        if not path.is_absolute() or ".." in path.parts or not path.name:
            raise ValueError("Absolute journal path without parent traversal required")
        directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        self.fd = None
        try:
            for component in path.parts[1:-1]:
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                os.close(directory)
                directory = child
            self.fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND | os.O_NOFOLLOW,
                              0o600, dir_fd=directory)
        finally:
            os.close(directory)

    def append(self, event):
        if self.fd is None:
            raise ValueError("Journal is closed")
        data = (json.dumps(event, sort_keys=True, allow_nan=False) + "\n").encode()
        while data:
            written = os.write(self.fd, data)
            if written <= 0:
                raise OSError("Receipt write made no progress")
            data = data[written:]
        os.fsync(self.fd)

    def close(self):
        descriptor, self.fd = self.fd, None
        if descriptor is not None:
            os.close(descriptor)


class StopGuard:
    """One independent idempotent stop request per admitted playing interval."""

    def __init__(self, scheduler, adapter, target, emit, clock, trusted_clock):
        capability = adapter.capability
        if (capability.exact_target != target or capability.idempotent is not True
                or capability.independent_of_gui is not True or capability.works_with_window_closed is not True):
            raise ValueError("Exact independent idempotent closed-window stop is unavailable")
        self.scheduler, self.adapter, self.target, self.emit = scheduler, adapter, target, emit
        self.clock = clock
        self.trusted_clock = trusted_clock
        self.last_trusted = trusted_clock()
        self.clock_domain = self.last_trusted.domain
        self.cancel = None
        self.requested = False
        self.requested_at = None
        self.pause_finished_at = None
        self.pause_succeeded = False
        self.pause_call_finished = False
        self.clock_failed = False
        self.next_token, self.tokens, self.token = 0, set(), None

    def schedule(self, deadline):
        self.next_token += 1
        token = self.next_token
        self.tokens.add(token)

        def expired():
            if token in self.tokens:
                self.stop("independent-deadline")

        try:
            return token, self.scheduler.at(deadline, expired)
        except Exception:
            self.tokens.discard(token)
            raise

    def arm(self, deadline):
        if self.cancel is not None:
            raise RuntimeError("Previous guard has not been settled")
        self.requested = False
        self.requested_at = None
        self.pause_finished_at = None
        self.pause_succeeded = False
        self.pause_call_finished = False
        self.clock_failed = False
        self.token, self.cancel = self.schedule(deadline)
        self.emit("guard-armed", deadline=deadline)

    def move_deadline(self, deadline):
        if self.cancel is None or self.requested:
            raise RuntimeError("An expired guard cannot be rearmed")
        previous, previous_token = self.cancel, self.token
        # Retain the old guard until replacement exists. Any scheduler failure is terminal.
        self.token, self.cancel = self.schedule(deadline)
        self.tokens.discard(previous_token)
        previous()
        if self.requested:
            raise RuntimeError("Guard expired during deadline replacement")
        self.emit("guard-deadline-updated", deadline=deadline)

    def stop(self, reason):
        if self.requested:
            return
        self.requested = True
        try:
            self.requested_at = self.read_time()
        except Exception:
            self.requested_at = None
            self.clock_failed = True
        entrance_clock_failed = False
        try:
            self.emit("pause-requested", reason=reason, clockUnavailable=self.clock_failed)
        finally:
            try:
                try:
                    self.read_time()  # Fence post-call readings against actual call entrance too.
                except Exception:
                    self.clock_failed = True
                    entrance_clock_failed = True
                self.adapter.request_pause(self.target)
                self.pause_succeeded = True
            except Exception as error:
                # Keep unknown-playing charge; a failed path cannot establish bounded playback.
                self.emit("pause-request-failed", error=type(error).__name__)
            finally:
                try:
                    self.pause_finished_at = self.read_time()
                except Exception:
                    self.pause_finished_at = None
                self.pause_call_finished = True
                if entrance_clock_failed:
                    self.emit("pause-clock-unavailable", stage="control-call-entrance")
                if self.pause_finished_at is None:
                    self.clock_failed = True
                    self.emit("pause-clock-unavailable", stage="completed-control-call")

    def read_time(self):
        reading, floor = self.clock(), self.trusted_clock()
        if (reading.domain != self.clock_domain or reading.domain != floor.domain
                or type(reading.seconds) not in (int, float) or not math.isfinite(reading.seconds)
                or reading.seconds < max(floor.seconds, self.last_trusted.seconds)):
            raise RuntimeError("Stop clock domain or monotonicity changed")
        self.last_trusted = reading
        return reading.seconds

    def settled(self):
        self.tokens.clear()  # Retired callbacks cannot stop a later cell even if cancellation is late.
        if self.cancel is not None:
            self.cancel()
            self.cancel = None


@dataclass(frozen=True)
class Observation:
    at: float
    gui_generation: int
    target: str
    local_device: str
    output: str
    window_open: bool
    window_exposed: bool
    playing: bool | None
    profiler_active: bool


class Coordinator:
    """Persistent event-driven model; failed sessions cannot retry a cell.

    Observation cadence is required coverage, not proof between observations.
    Unknown transport time is charged from before Play until confirmed paused.
    """

    def __init__(self, clock, scheduler, stop_adapter, play, journal, *, target, device,
                 output, playing_cap=188.0, session_cap=900.0, settle=15.0, sample=15.0,
                 ack_timeout=3.0, stop_margin=3.0, maximum_gap=1.5):
        values = (playing_cap, session_cap, settle, sample, ack_timeout, stop_margin, maximum_gap)
        if any(not math.isfinite(x) or x <= 0 for x in values):
            raise ValueError("Positive finite protocol limits required")
        if not target or not device or not output:
            raise ValueError("Exact admitted target, local device and output required")
        self.clock, self.journal, self.play = clock, journal, play
        origin = clock()
        if not math.isfinite(origin.seconds) or not origin.domain:
            raise ValueError("Valid persistent monotonic clock required")
        self.origin = self.last_clock = origin
        self.target, self.device, self.output = target, device, output
        self.playing_cap, self.session_cap = playing_cap, session_cap
        self.settle, self.sample, self.ack_timeout = settle, sample, ack_timeout
        self.stop_margin, self.maximum_gap = stop_margin, maximum_gap
        self.generation, self.phase, self.failed = 0, "idle", False
        self.charged, self.play_started = 0.0, None
        self.last_observation, self.last_delivery, self.latest = None, None, None
        self.guard = StopGuard(scheduler, stop_adapter, target, self.emit, clock, lambda: self.last_clock)
        self.emit("session-start", clockDomain=origin.domain, origin=origin.seconds)

    def emit(self, event, **fields):
        try:
            timestamp = self.clock().seconds
            self.journal.append({"event": event, "phase": self.phase,
                                 "at": timestamp if math.isfinite(timestamp) else None, **fields})
        except Exception:
            self.failed, self.phase = True, "failed"
            if self.play_started is not None:
                self.guard.stop("receipt-failure")
            raise

    def now(self):
        try:
            reading = self.clock()
            seconds, domain = reading.seconds, reading.domain
        except Exception as error:
            try:
                self.fail("clock-read-failed")
            except Exception:
                pass  # The primary clock fault survives; fail() still reaches guarded Pause.
            raise RuntimeError("Persistent clock read failed") from error
        if (domain != self.origin.domain or type(seconds) not in (int, float) or not math.isfinite(seconds)
                or seconds < self.last_clock.seconds):
            self.fail("clock-discontinuity")
            raise RuntimeError("Persistent monotonic clock changed")
        self.last_clock = reading
        return reading.seconds

    def fail(self, reason):
        self.failed = True
        self.phase = "failed"
        try:
            self.emit("excluded", reason=reason)
        finally:
            if self.play_started is not None:
                self.guard.stop(reason)

    def reset_gui(self):
        self.generation += 1
        self.emit("gui-reset", generation=self.generation)
        if self.phase not in ("idle", "complete", "failed"):
            self.fail("gui-runtime-reset")

    def begin(self, playing, window_open):
        if type(playing) is not bool or type(window_open) is not bool:
            raise ValueError("Explicit Boolean cell state required")
        now = self.now()
        if self.failed or self.phase not in ("idle", "complete"):
            raise RuntimeError("No retry or overlapping cell permitted")
        if (self.latest is None or self.latest.playing is not False
                or self.latest.gui_generation != self.generation
                or now - self.latest.at > self.maximum_gap):
            raise RuntimeError("Fresh confirmed paused admission required")
        if (self.latest.window_open != window_open or (window_open and not self.latest.window_exposed)
                or not self.latest.profiler_active):
            raise RuntimeError("Fresh window and profiler admission required")
        duration = self.settle + self.sample + self.ack_timeout + self.stop_margin
        if (now + duration > self.origin.seconds + self.session_cap
                or (playing and self.charged + duration > self.playing_cap)):
            self.fail("insufficient-budget")
            return
        self.desired_playing, self.window_open = playing, window_open
        self.last_observation, self.last_delivery = self.latest.at, now
        self.phase = "await-playing" if playing else "settling"
        self.phase_started = now
        self.emit("cell-start", playing=playing, windowOpen=window_open)
        if playing:
            self.play_started = now
            self.hard_deadline = min(now + self.playing_cap - self.charged,
                                     self.origin.seconds + self.session_cap) - self.stop_margin
            # Missing acknowledgement stops independently, even if the owner never polls.
            admission_deadline = min(now + self.ack_timeout, self.hard_deadline)
            try:
                self.guard.arm(admission_deadline)
                admitted = self.guard.scheduler.dispatch_before(
                    admission_deadline, lambda: not self.guard.requested and not self.failed,
                    lambda: self.play(self.target))
                if not admitted:
                    self.fail("play-dispatch-expired")
            except Exception as error:
                self.fail("arm-or-play-dispatch-failed:" + type(error).__name__)

    def observe(self, observation):
        now = self.now()
        if (not isinstance(observation.at, (int, float)) or isinstance(observation.at, bool)
                or not math.isfinite(observation.at)
                or type(observation.gui_generation) is not int
                or any(type(value) is not bool for value in (observation.window_open,
                                                            observation.window_exposed, observation.profiler_active))
                or (observation.playing is not None and type(observation.playing) is not bool)):
            self.fail("invalid-observation")
            return
        if (observation.gui_generation != self.generation or observation.at > now
                or now - observation.at > self.maximum_gap
                or (self.latest is not None and observation.at < self.latest.at)):
            self.fail("stale-observation")
            return
        if (observation.target != self.target or observation.local_device != self.device
                or observation.output != self.output):
            self.fail("context-changed")
            return
        self.latest = observation
        if now >= self.origin.seconds + self.session_cap:
            self.fail("session-cap")
        if self.play_started is not None and self.charged + now - self.play_started >= self.playing_cap:
            self.fail("playing-cap")
        recovered_cutoff = False
        if self.play_started is not None and self.guard.clock_failed:
            self.fail("stop-clock-unavailable")
            if self.guard.pause_call_finished and self.guard.pause_finished_at is None:
                # This trusted reading is after the completed control call. Require a later
                # observation strictly after this barrier; do not reuse the current cached sample.
                self.guard.pause_finished_at = now
                recovered_cutoff = True
                self.emit("pause-confirmation-clock-recovered", cutoff=now)
        if (observation.playing is False and self.play_started is not None
                and not recovered_cutoff
                and self.guard.requested and self.guard.pause_finished_at is not None
                and observation.at > self.guard.pause_finished_at):
            self.charged += now - self.play_started
            self.play_started = None
            try:
                self.guard.settled()
            except Exception:
                self.fail("guard-cancellation-failed")
            self.emit("paused-confirmed", chargedPlayingSeconds=self.charged)
            if self.charged >= self.playing_cap:
                self.fail("playing-cap-exceeded")
            elif not self.guard.pause_succeeded:
                self.fail("pause-request-unconfirmed")
            elif self.phase == "await-paused":
                self.phase = "complete"
                self.emit("cell-complete")
        if self.failed or self.phase in ("idle", "complete", "await-paused"):
            return
        if self.guard.requested and self.desired_playing:
            self.fail("independent-stop-during-cell")
            return
        if (observation.at - self.last_observation > self.maximum_gap
                or now - self.last_delivery > self.maximum_gap):
            self.fail("coverage-gap")
            return
        self.last_observation, self.last_delivery = observation.at, now
        if (observation.window_open != self.window_open
                or (self.window_open and not observation.window_exposed)
                or not observation.profiler_active):
            self.fail("window-or-profiler-coverage")
            return
        if self.phase == "await-playing":
            if now - self.phase_started > self.ack_timeout:
                self.fail("playing-ack-timeout")
            elif observation.playing is True:
                self.phase, self.phase_started = "settling", now
                try:
                    self.guard.move_deadline(min(now + self.settle + self.sample + self.stop_margin,
                                                 self.hard_deadline))
                except Exception:
                    self.fail("guard-replacement-failed")
                    return
                self.emit("playing-confirmed")
            return
        if observation.playing is not self.desired_playing:
            self.fail("transport-coverage")
            return
        if self.phase == "settling" and now - self.phase_started >= self.settle:
            self.phase, self.phase_started = "sampling", now
            self.emit("sample-start")
        elif self.phase == "sampling" and now - self.phase_started >= self.sample:
            self.emit("sample-end")
            if self.desired_playing:
                self.phase = "await-paused"
                self.guard.stop("sample-finished")
            else:
                self.phase = "complete"
                self.emit("cell-complete")

    def poll(self):
        now = self.now()
        if now >= self.origin.seconds + self.session_cap:
            self.fail("session-cap")
        elif self.play_started is not None and self.charged + now - self.play_started >= self.playing_cap:
            self.fail("playing-cap")
        elif self.phase == "await-playing" and now - self.phase_started > self.ack_timeout:
            self.fail("playing-ack-timeout")
        elif self.phase in ("settling", "sampling") and now - self.last_delivery > self.maximum_gap:
            self.fail("coverage-gap")
