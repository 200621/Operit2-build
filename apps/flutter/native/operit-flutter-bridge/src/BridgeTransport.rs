//! Shared push ordering, watch cancellation, and subscription ownership.
//! Host dispatchers decide how to execute tasks and deliver encoded frames.

use std::collections::{hash_map::Entry, HashMap};
use std::sync::{Arc, Mutex};

use operit_link::{
    CoreEvent, CoreEventKind, CoreEventStream, CoreLinkError, CoreLinkPushSession,
    CoreLinkSharedClient, CorePushItem, CorePushRequest, CoreWatchRequest,
};
use operit_proxy_local::LocalCoreProxy;
use tokio::sync::oneshot;

use crate::OperitFlutterBridge;

type PushSession = Arc<tokio::sync::Mutex<Option<Box<dyn CoreLinkPushSession>>>>;

/// Tracks one actual local push session and its next accepted sequence.
#[derive(Clone)]
pub(crate) struct PushStreamState {
    session: PushSession,
    nextSequence: u64,
}

/// Carries one validated push item to the host's execution boundary.
pub(crate) struct PushItemTask {
    session: PushSession,
    item: CorePushItem,
}

impl PushItemTask {
    /// Delivers the validated item to its original session without choosing another route.
    pub(crate) async fn execute(self) -> Result<(), CoreLinkError> {
        self.session
            .lock()
            .await
            .as_mut()
            .ok_or_else(|| CoreLinkError::new("PUSH_CLOSED", "Link push stream is closed"))?
            .send(self.item.args)
            .await
    }
}

/// Owns removal and closure of one client-owned push session.
pub(crate) struct PushCloseTask {
    session: PushSession,
}

impl PushCloseTask {
    /// Closes the removed session exactly once.
    pub(crate) async fn execute(self) -> Result<(), CoreLinkError> {
        let session = self
            .session
            .lock()
            .await
            .take()
            .ok_or_else(|| CoreLinkError::new("PUSH_CLOSED", "Link push stream is closed"))?;
        session.close().await
    }
}

/// Carries one snapshot request without retaining a borrowed bridge handle.
pub(crate) struct WatchSnapshotTask {
    core: Arc<LocalCoreProxy>,
    request: CoreWatchRequest,
}

impl WatchSnapshotTask {
    /// Reads the same snapshot implementation on every host.
    pub(crate) async fn execute(self) -> Result<CoreEvent, CoreLinkError> {
        CoreLinkSharedClient::watchSnapshot(self.core.as_ref(), self.request).await
    }
}

/// Identifies one registration generation and its cancellation sender.
pub(crate) struct WatchSubscription {
    generation: Arc<()>,
    cancel: oneshot::Sender<()>,
}

/// Removes only the registration generation owned by this running watch.
struct WatchLease {
    id: String,
    generation: Arc<()>,
    subscriptions: Arc<Mutex<HashMap<String, WatchSubscription>>>,
}

impl Drop for WatchLease {
    /// Prevents an old finishing watch from deleting a newly reused subscription id.
    fn drop(&mut self) {
        if let Ok(mut subscriptions) = self.subscriptions.lock() {
            let ownsRegistration = subscriptions
                .get(&self.id)
                .is_some_and(|entry| Arc::ptr_eq(&entry.generation, &self.generation));
            if ownsRegistration {
                subscriptions.remove(&self.id);
            }
        }
    }
}

/// Reserves cancellation before opening the watch's actual Core source.
pub(crate) struct WatchOpenTask {
    core: Arc<LocalCoreProxy>,
    request: CoreWatchRequest,
    lease: WatchLease,
    cancelled: oneshot::Receiver<()>,
}

impl WatchOpenTask {
    /// Reports source-open errors and cancellation instead of acknowledging a dead stream.
    pub(crate) async fn open(mut self) -> Result<OpenedWatch, CoreLinkError> {
        let events = tokio::select! {
            _ = &mut self.cancelled => {
                return Err(CoreLinkError::new("WATCH_CLOSED", "Watch was cancelled while opening"));
            }
            opened = CoreLinkSharedClient::watch(self.core.as_ref(), self.request) => opened?,
        };
        Ok(OpenedWatch {
            events,
            lease: self.lease,
            cancelled: self.cancelled,
        })
    }
}

/// Owns an opened source and forwards events through an explicitly supplied transport sink.
pub(crate) struct OpenedWatch {
    events: CoreEventStream,
    lease: WatchLease,
    cancelled: oneshot::Receiver<()>,
}

impl OpenedWatch {
    /// Preserves source event ordering and releases the registration on every exit path.
    pub(crate) async fn forward(
        mut self,
        mut deliver: impl FnMut(&str, CoreEvent) -> Result<(), CoreLinkError>,
    ) -> Result<(), CoreLinkError> {
        loop {
            let event = tokio::select! {
                _ = &mut self.cancelled => None,
                event = self.events.recv() => event,
            };
            let Some(event) = event else {
                return Ok(());
            };
            let completed = event.kind == CoreEventKind::Completed;
            deliver(&self.lease.id, event)?;
            if completed {
                return Ok(());
            }
        }
    }
}

impl OperitFlutterBridge {
    /// Registers one local push without replacing an existing session on duplicate ids.
    pub(crate) fn pushOpen(&self, request: CorePushRequest) -> Result<String, CoreLinkError> {
        let id = request.requestId.0.clone();
        let mut pushes = self.pushStreams.lock().map_err(|error| {
            CoreLinkError::internal(format!("push stream lock poisoned: {error}"))
        })?;
        match pushes.entry(id.clone()) {
            Entry::Occupied(_) => Err(CoreLinkError::new(
                "PUSH_ALREADY_EXISTS",
                "Link push stream already exists",
            )),
            Entry::Vacant(entry) => {
                let session = self.localCore.openPushLocal(request)?;
                entry.insert(PushStreamState {
                    session: Arc::new(tokio::sync::Mutex::new(Some(session))),
                    nextSequence: 0,
                });
                Ok(id)
            }
        }
    }

    /// Validates sequence ownership once before scheduling a push item.
    pub(crate) fn preparePushItem(
        &self,
        item: CorePushItem,
    ) -> Result<PushItemTask, CoreLinkError> {
        let mut pushes = self.pushStreams.lock().map_err(|error| {
            CoreLinkError::internal(format!("push stream lock poisoned: {error}"))
        })?;
        let state = pushes
            .get_mut(&item.pushId)
            .ok_or_else(|| CoreLinkError::new("PUSH_NOT_FOUND", "Link push stream not found"))?;
        if item.sequence != state.nextSequence {
            return Err(CoreLinkError::new(
                "PUSH_SEQUENCE_MISMATCH",
                format!(
                    "Link push sequence is {}, expected {}",
                    item.sequence, state.nextSequence
                ),
            ));
        }
        state.nextSequence = state.nextSequence.checked_add(1).ok_or_else(|| {
            CoreLinkError::new("PUSH_SEQUENCE_OVERFLOW", "Link push sequence overflowed")
        })?;
        Ok(PushItemTask {
            session: state.session.clone(),
            item,
        })
    }

    /// Removes a push before scheduling its sole close operation.
    pub(crate) fn preparePushClose(&self, id: &str) -> Result<PushCloseTask, CoreLinkError> {
        let state = self
            .pushStreams
            .lock()
            .map_err(|error| {
                CoreLinkError::internal(format!("push stream lock poisoned: {error}"))
            })?
            .remove(id)
            .ok_or_else(|| CoreLinkError::new("PUSH_NOT_FOUND", "Link push stream not found"))?;
        Ok(PushCloseTask {
            session: state.session,
        })
    }

    /// Prepares the same snapshot task for asynchronous and blocking ABI callers.
    pub(crate) fn prepareWatchSnapshot(&self, request: CoreWatchRequest) -> WatchSnapshotTask {
        WatchSnapshotTask {
            core: self.localCore.clone(),
            request,
        }
    }

    /// Reserves one watch generation atomically before its source is opened.
    pub(crate) fn prepareWatchStream(
        &self,
        id: String,
        request: CoreWatchRequest,
    ) -> Result<WatchOpenTask, CoreLinkError> {
        let generation = Arc::new(());
        let (cancel, cancelled) = oneshot::channel();
        let mut subscriptions = self.watchSubscriptions.lock().map_err(|error| {
            CoreLinkError::internal(format!("watch subscription lock poisoned: {error}"))
        })?;
        match subscriptions.entry(id.clone()) {
            Entry::Occupied(_) => {
                return Err(CoreLinkError::new(
                    "WATCH_ALREADY_EXISTS",
                    "Watch subscription already exists",
                ))
            }
            Entry::Vacant(entry) => {
                entry.insert(WatchSubscription {
                    generation: generation.clone(),
                    cancel,
                });
            }
        }
        Ok(WatchOpenTask {
            core: self.localCore.clone(),
            request,
            cancelled,
            lease: WatchLease {
                id,
                generation,
                subscriptions: self.watchSubscriptions.clone(),
            },
        })
    }

    /// Cancels the exact registered watch on every transport.
    pub(crate) fn closeWatchStream(&self, id: &str) {
        if let Ok(mut subscriptions) = self.watchSubscriptions.lock() {
            if let Some(subscription) = subscriptions.remove(id) {
                let _ = subscription.cancel.send(());
            }
        }
    }
}
