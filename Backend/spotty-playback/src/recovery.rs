//! One recovery owner. Cancellation wakes backoff; construction still settles under LIFECYCLE.
use crate::*;

#[derive(Default)]
struct RecoveryOwner {
    next_ticket: u64,
    active: Option<(u64, tokio::sync::watch::Sender<bool>)>,
}

static RECOVERY: Lazy<Mutex<RecoveryOwner>> = Lazy::new(|| Mutex::new(RecoveryOwner::default()));

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RecoveryOutcome {
    Ready,
    CredentialsRejected,
    Stopped,
    Superseded,
    Interrupted,
}

#[derive(Debug)]
pub(crate) struct RecoveryReport {
    pub(crate) outcome: RecoveryOutcome,
    pub(crate) attempts: u32,
    pub(crate) elapsed: Duration,
}

/// A lease can finish only its own run, even after sleep/logout has admitted a replacement.
pub(crate) struct RecoveryLease {
    ticket: u64,
    cancelled: tokio::sync::watch::Receiver<bool>,
    started: std::time::Instant,
    attempts: u32,
    reported: bool,
}

pub(crate) fn recovery_is_active() -> bool {
    RECOVERY
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .active
        .is_some()
}

pub(crate) fn cancel_recovery() {
    with_generation_mutation(|| {
        let mut owner = RECOVERY.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((_, cancellation)) = owner.active.take() {
            let _ = cancellation.send(true);
        }
    });
}

impl RecoveryLease {
    pub(crate) fn claim() -> Option<Self> {
        let mut owner = RECOVERY.lock().unwrap_or_else(|e| e.into_inner());
        if owner.active.is_some() || teardown_in_progress() {
            return None;
        }
        owner.next_ticket = owner
            .next_ticket
            .checked_add(1)
            .expect("recovery ticket exhausted");
        let ticket = owner.next_ticket;
        let (sender, cancelled) = tokio::sync::watch::channel(false);
        owner.active = Some((ticket, sender));
        Some(Self {
            ticket,
            cancelled,
            started: std::time::Instant::now(),
            attempts: 0,
            reported: false,
        })
    }

    pub(crate) fn next_delay(&self) -> Duration {
        recovery_delay(self.attempts)
    }

    pub(crate) fn begin_attempt(&mut self) -> u32 {
        self.attempts = self.attempts.saturating_add(1);
        self.attempts
    }

    pub(crate) fn finish(mut self, outcome: RecoveryOutcome) -> RecoveryReport {
        self.report(outcome)
    }

    fn report(&mut self, outcome: RecoveryOutcome) -> RecoveryReport {
        self.reported = true;
        let report = RecoveryReport {
            outcome,
            attempts: self.attempts,
            elapsed: self.started.elapsed(),
        };
        debug!(
            "Recovery settled: outcome={:?}; attempts={}; elapsed_ms={}",
            report.outcome,
            report.attempts,
            report.elapsed.as_millis()
        );
        report
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        *self.cancelled.borrow()
    }

    /// Only sleeps outside construction. Dropping a partially built engine is not cancellation.
    pub(crate) async fn wait(&mut self, delay: Duration) -> bool {
        if self.is_cancelled() {
            return false;
        }
        tokio::select! {
            _ = self.cancelled.changed() => false,
            _ = tokio::time::sleep(delay) => !self.is_cancelled(),
        }
    }
}

impl Drop for RecoveryLease {
    fn drop(&mut self) {
        if !self.reported {
            let outcome = if self.is_cancelled() {
                RecoveryOutcome::Stopped
            } else {
                RecoveryOutcome::Interrupted
            };
            self.report(outcome);
        }
        let mut owner = RECOVERY.lock().unwrap_or_else(|e| e.into_inner());
        if owner
            .active
            .as_ref()
            .is_some_and(|(ticket, _)| *ticket == self.ticket)
        {
            owner.active = None;
        }
    }
}

pub(crate) fn recovery_delay(attempt: u32) -> Duration {
    Duration::from_secs(match attempt {
        0 => 0,
        1 => 2,
        2 => 5,
        3 => 10,
        _ => 30,
    })
}
