//! Idle authenticated-channel liveness, independent of routed operations.

const IDLE_MS: u64 = 3_000;
const MIN_TIMEOUT_MS: u64 = 5_000;
const MAX_TIMEOUT_MS: u64 = 60_000;

/// Describes the next control action without performing transport I/O.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum HeartbeatAction { None, Ping(String), Suspect, Expired }

struct Probe {
    id: String,
    startedAt: u64,
    receiveRevision: u64,
    deadline: u64,
    suspect: bool,
}

/// Maintains one outstanding probe and adaptive timing for one connection generation.
pub(super) struct Heartbeat {
    lastReceiveAt: u64,
    receiveRevision: u64,
    nextId: u64,
    pending: Option<Probe>,
    rtt: Option<(u64, u64)>,
}

impl Heartbeat {
    /// Starts with the authenticated handshake as the initial receive evidence.
    pub(super) fn new(now: u64) -> Self {
        Self { lastReceiveAt: now, receiveRevision: 0, nextId: 0, pending: None, rtt: None }
    }

    /// Records any authenticated frame, irrespective of its logical operation.
    pub(super) fn received(&mut self, now: u64) {
        self.lastReceiveAt = now;
        self.receiveRevision += 1;
    }

    /// Measures only the response to the current probe; stale pongs carry no RTT sample.
    pub(super) fn pong(&mut self, id: &str, now: u64) {
        if !self.pending.as_ref().is_some_and(|probe| probe.id == id) { return; }
        let probe = self.pending.take().unwrap();
        let sample = now.saturating_sub(probe.startedAt);
        self.rtt = Some(match self.rtt {
            None => (sample, sample / 2),
            Some((rtt, variation)) => ((7 * rtt + sample) / 8, (3 * variation + rtt.abs_diff(sample)) / 4),
        });
    }

    /// Computes a bounded response budget from measured round-trip time and variation.
    pub(super) fn timeoutMs(&self) -> u64 {
        match self.rtt {
            None => MIN_TIMEOUT_MS,
            Some((rtt, variation)) => (rtt + 4 * variation).clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS),
        }
    }

    /// Probes idle connections and requires a second silent deadline before expiration.
    pub(super) fn tick(&mut self, now: u64) -> HeartbeatAction {
        let timeout = self.timeoutMs();
        if let Some(probe) = self.pending.as_mut() {
            if now < probe.deadline { return HeartbeatAction::None; }
            if self.receiveRevision != probe.receiveRevision {
                self.pending = None;
                return HeartbeatAction::None;
            }
            if probe.suspect { return HeartbeatAction::Expired; }
            probe.suspect = true;
            probe.deadline = now + (2 * timeout).max(15_000);
            return HeartbeatAction::Suspect;
        }
        if now.saturating_sub(self.lastReceiveAt) < IDLE_MS { return HeartbeatAction::None; }
        let id = self.nextId.to_string();
        self.nextId += 1;
        self.pending = Some(Probe {
            id: id.clone(), startedAt: now, receiveRevision: self.receiveRevision,
            deadline: now + timeout, suspect: false,
        });
        HeartbeatAction::Ping(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Suppresses probes while authenticated traffic remains active.
    #[test]
    fn traffic_suppresses_probes() {
        let mut state = Heartbeat::new(0);
        for now in (1_000..=20_000).step_by(1_000) {
            state.received(now);
            assert_eq!(state.tick(now), HeartbeatAction::None);
        }
    }

    /// Keeps a single outstanding probe and separates suspicion from expiration.
    #[test]
    fn one_probe_requires_two_silent_deadlines() {
        let mut state = Heartbeat::new(0);
        assert_eq!(state.tick(3_000), HeartbeatAction::Ping("0".into()));
        assert_eq!(state.tick(4_000), HeartbeatAction::None);
        assert_eq!(state.tick(8_000), HeartbeatAction::Suspect);
        assert_eq!(state.tick(22_999), HeartbeatAction::None);
        assert_eq!(state.tick(23_000), HeartbeatAction::Expired);
    }

    /// Prevents a timed-out probe from overriding newer receive evidence.
    #[test]
    fn traffic_after_probe_prevents_expiration() {
        let mut state = Heartbeat::new(0);
        state.tick(3_000);
        state.received(7_000);
        assert_eq!(state.tick(8_000), HeartbeatAction::None);
        assert_eq!(state.tick(10_000), HeartbeatAction::Ping("1".into()));
        assert_eq!(state.tick(15_000), HeartbeatAction::Suspect);
        state.received(29_000);
        assert_eq!(state.tick(30_000), HeartbeatAction::None);
    }

    /// Accepts delayed pongs during suspicion and adapts the next response budget.
    #[test]
    fn delayed_pong_adapts_timeout_and_stale_pong_does_not() {
        let mut state = Heartbeat::new(0);
        state.tick(3_000);
        assert_eq!(state.tick(8_000), HeartbeatAction::Suspect);
        state.received(13_000);
        state.pong("0", 13_000);
        assert_eq!(state.timeoutMs(), 30_000);
        assert_eq!(state.tick(16_000), HeartbeatAction::Ping("1".into()));
        state.pong("0", 16_001);
        assert_eq!(state.timeoutMs(), 30_000);
        assert_eq!(state.tick(21_000), HeartbeatAction::None);
    }
}
