//! Durable application records, not storage-engine changes. A paired gateway
//! coordinates one request; only its assigned, authorized reviewer may decide.
//! Applicant traffic stays direct. Reviewer traffic uses authenticated Space routes.
use super::*;
use crate::PeerStateStore::PeerStateStore;
use operit_store::CoreSpaceStore::CoreSpaceDeviceConnection;
use operit_store::NetworkControlStore::{NetworkControlCommand, NetworkControlCommandRecord};
use std::collections::{BTreeSet, VecDeque};
use std::sync::Mutex;

// Group consent uses its own durable schema; single-device approval records are not group approvals.
const INBOUND: &str = "runtime/link_access/space_merge_inbound.preferences.json";
const OUTBOUND: &str = "runtime/link_access/space_merge_outbound.preferences.json";
const INBOX: &str = "runtime/link_access/space_merge_review_inbox.preferences.json";
const RESULTS: &str = "runtime/link_access/space_merge_review_results.preferences.json";
const LIFETIME_MS: i64 = 15 * 60 * 1000;
const OFFLINE_GRACE_MS: i64 = 30_000;
static MUTATION: Mutex<()> = Mutex::new(());

#[derive(Clone, Serialize, Deserialize)]
struct Record {
    request: SpaceJoinRequest,
    sourceSpaceId: String,
    sourceRevision: i64,
    targetSpaceId: String,
    profile: CoreSpaceDeviceProfile,
    source: PeerSpaceSnapshot,
    accepted: Option<PeerSpaceJoin>,
    #[serde(default)]
    unavailableSince: Option<i64>,
    #[serde(default)]
    approvedDecision: Option<bool>,
}
#[derive(Serialize, Deserialize)]
struct Submission {
    requestId: String,
    sourceSpaceId: String,
    sourceRevision: i64,
    targetSpaceId: String,
    profile: CoreSpaceDeviceProfile,
    source: PeerSpaceSnapshot,
}
#[derive(Serialize, Deserialize)]
struct Decision {
    requestId: String,
    assignmentVersion: u64,
    approve: bool,
}
#[derive(Serialize, Deserialize)]
struct Claim {
    record: Record,
    current: PeerSpaceJoin,
}
#[derive(Serialize, Deserialize)]
struct Outcome {
    decision: Decision,
    admission: Option<SyncOperation>,
    revision: i64,
}
fn store(service: &RuntimeRemoteLinkService) -> PeerStateStore {
    PeerStateStore::new(service.localRuntime.runtimeStorageHost())
}
fn active(status: &SpaceJoinStatus) -> bool {
    matches!(status, SpaceJoinStatus::Pending | SpaceJoinStatus::Approving | SpaceJoinStatus::Approved)
}
fn expire(record: &mut Record, now: i64, spaceId: &str) {
    // An approved admission is already durable membership, not an expiring offer.
    // A claimed decision is pinned for retry/recovery, never assigned twice.
    if record.request.status == SpaceJoinStatus::Pending {
        if record.targetSpaceId != spaceId {
            record.request.status = SpaceJoinStatus::Cancelled;
        } else if record.request.expiresAt <= now {
            record.request.status = SpaceJoinStatus::Expired;
        }
    }
}
fn load(service: &RuntimeRemoteLinkService, path: &str, id: &str) -> Result<Record, String> {
    store(service).records::<Record>(path)?.remove(id).ok_or_else(|| "Join request not found".into())
}
fn canReview(service: &RuntimeRemoteLinkService, node: &str) -> Result<bool, String> {
    Ok(!service.networkControlStore.nodeIsDisconnected(node)?
        && service.networkControlStore.nodeHasCapability(node, "network.members.join", None)?
        && service.networkControlStore.nodeHasCapability(node, "network.approval", None)?)
}
fn paired(service: &RuntimeRemoteLinkService, peer: &str, inbound: bool) -> Result<(), String> {
    if !service.nodeServices()?.peers().pairedPeers().map_err(|e| e.to_string())?.iter()
        .any(|p| p.nodeId == peer && if inbound { p.inbound } else { p.outbound }) {
        return Err("Join request requires a current directional pairing".into());
    }
    Ok(())
}

/// Hop distance from the gateway, respecting directed links and relay permission.
/// Applicant-to-gateway adds one identical hop to every candidate. Never use RTT
/// as an unannounced replacement for hop count; ties use stable device identity.
fn hopDistances(source: &str, edges: &[CoreSpaceDeviceConnection], transit: &BTreeSet<String>) -> BTreeMap<String, u32> {
    let mut distances = BTreeMap::from([(source.to_owned(), 0)]);
    let mut queue = VecDeque::from([source.to_owned()]);
    while let Some(node) = queue.pop_front() {
        if node != source && !transit.contains(&node) { continue; }
        let nextDistance = distances[&node] + 1;
        for edge in edges.iter().filter(|e| e.firstDeviceId == node) {
            if !distances.contains_key(&edge.secondDeviceId) {
                distances.insert(edge.secondDeviceId.clone(), nextDistance);
                queue.push_back(edge.secondDeviceId.clone());
            }
        }
    }
    distances
}
/// Assigns the nearest authorized reviewer without consulting topology for a local decision.
fn assign(service: &RuntimeRemoteLinkService, record: &mut Record, now: i64) -> Result<(), String> {
    if record.request.status != SpaceJoinStatus::Pending { return Ok(()); }
    let local = service.nodeRouter.localNodeId();
    let space = service.spaceStore.initialize()?;
    let capable = |node: &str| -> Result<bool, String> {
        Ok(space.members.iter().any(|n| n == node) && canReview(service, node)?)
    };
    if let Some(node) = record.request.reviewerDeviceId.as_deref() {
        if capable(node)? {
            if service.nodeRouter.nodeIsReachable(node)? {
                record.unavailableSince = None;
                return Ok(()); // Stable assignment: do not bounce between equally close peers.
            }
            let since = *record.unavailableSince.get_or_insert(now);
            if now.saturating_sub(since) < OFFLINE_GRACE_MS { return Ok(()); }
        }
    }
    let chosen = if capable(&local)? {
        Some((0, local.clone()))
    } else {
        let peers = service.nodeServices()?.peers().activePeerNodeIds().map_err(|e| e.to_string())?;
        let mut edges = service.spaceStore.deviceConnections()?;
        edges.retain(|e| e.firstDeviceId != local);
        edges.extend(peers.into_iter().filter(|p| space.members.contains(p)).map(|p| CoreSpaceDeviceConnection {
            firstDeviceId: local.clone(), secondDeviceId: p,
        }));
        let distances = hopDistances(&local, &edges, &service.networkControlStore.relayNodeIds()?);
        let mut candidates = Vec::new();
        for (node, hops) in distances {
            if capable(&node)? && service.nodeRouter.nodeIsReachable(&node)? { candidates.push((hops, node)); }
        }
        candidates.sort();
        candidates.into_iter().next()
    };
    let newId = chosen.as_ref().map(|(_, node)| node.clone());
    if newId != record.request.reviewerDeviceId {
        record.request.assignmentVersion = record.request.assignmentVersion.checked_add(1).ok_or("Assignment overflow")?;
    }
    record.request.reviewerName = match newId.as_ref() {
        Some(node) => service.spaceStore.deviceProfiles()?.get(node).map(|p| p.displayName.clone()).or_else(|| Some(node.clone())),
        None => None,
    };
    record.request.reviewerDeviceId = newId;
    record.request.reviewerHops = chosen.map(|(hops, _)| hops + 1);
    record.unavailableSince = None;
    Ok(())
}
fn reconcile(service: &RuntimeRemoteLinkService, record: &mut Record) -> Result<(), String> {
    let now = currentTimeMillis();
    expire(record, now, &service.spaceStore.initialize()?.spaceId);
    assign(service, record, now)
}

/// Captures the complete source membership for one explicit Space merge request.
pub(super) async fn request(service: &RuntimeRemoteLinkService, deviceId: String) -> Result<SpaceJoinRequest, String> {
    paired(service, &deviceId, false)?;
    if let Some(old) = outgoing(service)?.into_iter().find(|r| r.targetDeviceId == deviceId && active(&r.status)) {
        return refresh(service, old.requestId).await;
    }
    let snapshot: PeerSpaceSnapshot = service.callPeerSpace(&deviceId, "snapshot", CoreValue::Null).await?;
    if !snapshot.space.members.contains(&deviceId) { return Err("Target is not in its advertised Space".into()); }
    let source = service.peerSpaceSnapshot()?;
    let local = source.space.clone();
    let localId = service.nodeRouter.localNodeId();
    if local.spaceId == snapshot.space.spaceId && snapshot.space.members.contains(&localId) {
        return Err("This device is already a member of the target Space".into());
    }
    let profile = source.deviceProfiles.iter().find(|p| p.nodeId == localId)
        .cloned().ok_or("Local device profile missing")?;
    let applicantName = source.deviceProfiles.iter()
        .filter(|p| source.space.members.iter().any(|node| node == &p.nodeId))
        .map(|p| p.displayName.clone()).collect::<Vec<_>>().join(", ");
    let now = currentTimeMillis();
    let record = Record {
        request: SpaceJoinRequest { requestId: uuid::Uuid::new_v4().to_string(), targetDeviceId: deviceId,
            applicantDeviceId: localId, applicantName, spaceName: snapshot.space.spaceName,
            status: SpaceJoinStatus::Pending, createdAt: now, expiresAt: now + LIFETIME_MS, canApprove: false,
            reviewerDeviceId: None, reviewerName: None, reviewerHops: None, assignmentVersion: 0, decisionApprove: None },
        sourceSpaceId: local.spaceId, sourceRevision: local.spaceRevision,
        targetSpaceId: snapshot.space.spaceId, profile, source, accepted: None, unavailableSince: None, approvedDecision: None,
    };
    store(service).putRecord(OUTBOUND, &record.request.requestId, &record)?;
    // refresh also handles a result already approved after a lost initial reply.
    refresh(service, record.request.requestId).await
}
/// Resends the immutable source snapshot associated with this request.
async fn sendSubmission(service: &RuntimeRemoteLinkService, record: &Record) -> Result<Record, String> {
    service.callPeerSpace(&record.request.targetDeviceId, "requestJoin", toCoreValue(Submission {
        requestId: record.request.requestId.clone(), sourceSpaceId: record.sourceSpaceId.clone(),
        sourceRevision: record.sourceRevision, targetSpaceId: record.targetSpaceId.clone(), profile: record.profile.clone(), source: record.source.clone(),
    }).map_err(|e| e.to_string())?).await
}
fn validateResponse(local: &Record, remote: &Record) -> Result<(), String> {
    if local.request.requestId != remote.request.requestId
        || local.request.applicantDeviceId != remote.request.applicantDeviceId
        || local.request.targetDeviceId != remote.request.targetDeviceId
        || local.targetSpaceId != remote.targetSpaceId || local.sourceSpaceId != remote.sourceSpaceId {
        return Err("Join response identity mismatch".into());
    }
    Ok(())
}
pub(super) fn outgoing(service: &RuntimeRemoteLinkService) -> Result<Vec<SpaceJoinRequest>, String> {
    let mut records: Vec<_> = store(service).records::<Record>(OUTBOUND)?.into_values().map(|r| r.request).collect();
    // Do not expire locally: a lost reply may hide a completed remote approval.
    records.sort_by_key(|r| r.createdAt);
    Ok(records)
}

/// Receives applicant commands; cancellation never depends on reviewer discovery.
pub(super) fn receive(service: &RuntimeRemoteLinkService, peer: &str, request: CoreCallRequest) -> Result<CoreValue, String> {
    let _lock = MUTATION.lock().map_err(|e| e.to_string())?;
    paired(service, peer, true)?;
    let current = service.spaceStore.initialize()?;
    let now = currentTimeMillis();
    let cancellation = request.methodName == "cancelJoin";
    let mut record = if request.methodName == "requestJoin" || cancellation {
        let input: Submission = fromCoreValue(request.args).map_err(|e| e.to_string())?;
        if !cancellation {
            CoreSpaceStore::validateSpaceProfiles(&input.source.space, &input.source.deviceProfiles)?;
            if input.source.space.spaceId != input.sourceSpaceId || input.source.space.spaceRevision != input.sourceRevision
                || !input.source.space.members.iter().any(|node| node == peer)
                || !input.source.deviceProfiles.iter().any(|profile| profile == &input.profile) {
                return Err("Join source snapshot does not match its applicant".into());
            }
        }
        uuid::Uuid::parse_str(&input.requestId).map_err(|_| "Invalid join request id")?;
        if input.profile.nodeId != peer || input.sourceRevision <= 0 || (!cancellation && input.targetSpaceId != current.spaceId)
            || input.sourceSpaceId.is_empty() || input.profile.displayName.len() > 512 {
            return Err("Join request identity/Space mismatch".into());
        }
        let records = store(service).records::<Record>(INBOUND)?;
        if let Some(old) = records.get(&input.requestId) {
            if old.request.applicantDeviceId != peer || old.targetSpaceId != input.targetSpaceId
                || old.sourceSpaceId != input.sourceSpaceId || old.sourceRevision != input.sourceRevision {
                return Err("Join request id belongs to another submission".into());
            }
            old.clone()
        } else {
            if !cancellation && records.values().filter(|r| active(&r.request.status) && r.request.expiresAt > now).count() >= 64 {
                return Err("Too many pending join requests".into());
            }
            if !cancellation && records.values().any(|r| r.request.applicantDeviceId == peer && r.targetSpaceId == current.spaceId
                && active(&r.request.status) && (r.request.status != SpaceJoinStatus::Pending || r.request.expiresAt > now)) {
                return Err("An active join request already exists".into());
            }
            Record {
                request: SpaceJoinRequest { requestId: input.requestId, targetDeviceId: service.nodeRouter.localNodeId(),
                    applicantDeviceId: peer.into(), applicantName: input.source.deviceProfiles.iter()
                        .filter(|p| input.source.space.members.iter().any(|node| node == &p.nodeId))
                        .map(|p| p.displayName.clone()).collect::<Vec<_>>().join(", "),
                    spaceName: current.spaceName.clone(), status: SpaceJoinStatus::Pending,
                    createdAt: now, expiresAt: now + LIFETIME_MS, canApprove: false,
                    reviewerDeviceId: None, reviewerName: None, reviewerHops: None, assignmentVersion: 0, decisionApprove: None },
                sourceSpaceId: input.sourceSpaceId, sourceRevision: input.sourceRevision,
                targetSpaceId: input.targetSpaceId, profile: input.profile, source: input.source, accepted: None,
                unavailableSince: None, approvedDecision: None,
            }
        }
    } else {
        let id: String = fromCoreValue(request.args).map_err(|e| e.to_string())?;
        let record = load(service, INBOUND, &id)?;
        if record.request.applicantDeviceId != peer { return Err("Join request belongs to another device".into()); }
        record
    };
    if request.methodName == "cancelJoin" {
        if record.request.status == SpaceJoinStatus::Pending {
            record.request.status = SpaceJoinStatus::Cancelled;
        }
    } else {
        reconcile(service, &mut record)?;
    }
    store(service).putRecord(INBOUND, &record.request.requestId, &record)?;
    toCoreValue(record).map_err(|e| e.to_string())
}

async fn approvalCall<T: serde::de::DeserializeOwned>(service: &RuntimeRemoteLinkService, node: &str, method: &str, args: CoreValue) -> Result<T, String> {
    let request = CoreCallRequest::new(format!("space-approval-{}", uuid::Uuid::new_v4()), NODE_SPACE_APPROVAL_TARGET, method, args);
    let value = if node == service.nodeRouter.localNodeId() {
        receiveApproval(service, node, request)?
    } else {
        service.nodeRouter.callNode(node.to_owned(), request).await.result.map_err(|e| e.to_string())?
    };
    fromCoreValue(value).map_err(|e| e.to_string())
}
/// Every reviewer pulls only its assignments from reachable same-Space gateways.
/// No applicant data is replicated/broadcast and no other admin gets a popup.
pub(super) async fn incoming(service: &RuntimeRemoteLinkService) -> Result<Vec<SpaceJoinRequest>, String> {
    let local = service.nodeRouter.localNodeId();
    if !canReview(service, &local)? { return Ok(Vec::new()); }
    let mut result = Vec::new();
    for node in service.spaceStore.initialize()?.members {
        if !service.nodeRouter.nodeIsReachable(&node)? { continue; }
        let records = match approvalCall::<Vec<Record>>(service, &node, "assigned", CoreValue::Null).await {
            Ok(records) => records,
            Err(error) => {
                operit_util::AppLogger::AppLogger::d("SpaceJoin", &format!("Assignment source unavailable {node}: {error}"));
                continue;
            }
        };
        for mut record in records {
            if record.request.targetDeviceId != node || record.request.reviewerDeviceId.as_deref() != Some(local.as_str())
                || record.targetSpaceId != service.spaceStore.initialize()?.spaceId { continue; }
            record.request.canApprove = true;
            store(service).putRecord(INBOX, &record.request.requestId, &record)?;
            result.push(record.request);
        }
    }
    result.sort_by_key(|r| r.createdAt);
    Ok(result)
}
fn validateAssignment(service: &RuntimeRemoteLinkService, record: &Record, origin: &str, decision: &Decision) -> Result<(), String> {
    if record.request.reviewerDeviceId.as_deref() != Some(origin)
        || record.request.assignmentVersion != decision.assignmentVersion
        || record.targetSpaceId != service.spaceStore.initialize()?.spaceId
        || !canReview(service, origin)? {
        return Err("Join assignment changed or this device has no approval permission".into());
    }
    Ok(())
}
/// Claims and commits the exact group membership selected by the reviewer.
pub(super) fn receiveApproval(service: &RuntimeRemoteLinkService, origin: &str, request: CoreCallRequest) -> Result<CoreValue, String> {
    let _lock = MUTATION.lock().map_err(|e| e.to_string())?;
    let current = service.spaceStore.initialize()?;
    if !current.members.iter().any(|n| n == origin) || service.networkControlStore.nodeIsDisconnected(origin)? {
        return Err("Approval requires an active member of this Space".into());
    }
    match request.methodName.as_str() {
        "assigned" => {
            let mut assigned = Vec::new();
            for mut record in store(service).records::<Record>(INBOUND)?.into_values() {
                reconcile(service, &mut record)?;
                store(service).putRecord(INBOUND, &record.request.requestId, &record)?;
                if record.targetSpaceId == current.spaceId && record.request.reviewerDeviceId.as_deref() == Some(origin)
                    && matches!(record.request.status, SpaceJoinStatus::Pending | SpaceJoinStatus::Approving)
                    && canReview(service, origin)? { assigned.push(record); }
            }
            toCoreValue(assigned).map_err(|e| e.to_string())
        }
        "claim" => {
            let decision: Decision = fromCoreValue(request.args).map_err(|e| e.to_string())?;
            let mut record = load(service, INBOUND, &decision.requestId)?;
            reconcile(service, &mut record)?;
            // Persist reassignment/expiry even when a stale reviewer tries to claim.
            store(service).putRecord(INBOUND, &decision.requestId, &record)?;
            validateAssignment(service, &record, origin, &decision)?;
            if record.request.status == SpaceJoinStatus::Pending {
                paired(service, &record.request.applicantDeviceId, true)?;
                record.request.status = SpaceJoinStatus::Approving;
                record.approvedDecision = Some(decision.approve);
                record.request.decisionApprove = Some(decision.approve);
                store(service).putRecord(INBOUND, &decision.requestId, &record)?;
            } else if record.approvedDecision != Some(decision.approve)
                || !matches!(record.request.status, SpaceJoinStatus::Approving | SpaceJoinStatus::Approved | SpaceJoinStatus::Rejected) {
                return Err("Join request is no longer awaiting this decision".into());
            }
            toCoreValue(Claim { record, current: service.peerSpaceSnapshot()? }).map_err(|e| e.to_string())
        }
        "complete" => {
            let outcome: Outcome = fromCoreValue(request.args).map_err(|e| e.to_string())?;
            let mut record = load(service, INBOUND, &outcome.decision.requestId)?;
            validateAssignment(service, &record, origin, &outcome.decision)?;
            if record.approvedDecision != Some(outcome.decision.approve) { return Err("Decision does not match its claim".into()); }
            if matches!(record.request.status, SpaceJoinStatus::Approved | SpaceJoinStatus::Rejected) {
                return toCoreValue(record).map_err(|e| e.to_string());
            }
            if record.request.status != SpaceJoinStatus::Approving { return Err("Decision was not claimed".into()); }
            if outcome.decision.approve {
                let operation = outcome.admission.as_ref().ok_or("Approval has no admission operation")?;
                let command: NetworkControlCommandRecord = serde_json::from_value(operation.payload.clone()).map_err(|e| e.to_string())?;
                if command.spaceId != record.targetSpaceId || command.issuerNodeId != origin
                    || !matches!(command.command, NetworkControlCommand::AdmitSpace { ref sourceSpaceId, ref nodeIds }
                        if sourceSpaceId == &record.sourceSpaceId && nodeIds == &record.source.space.members.iter().cloned().collect()) {
                    return Err("Approval operation is not this reviewer's admission for this applicant".into());
                }
                let members = record.source.space.members.iter().cloned().collect();
                let mut operations = service.networkControlStore.currentSpaceOperations()?;
                if !operations.iter().any(|existing| existing.opId == operation.opId) { operations.push(operation.clone()); }
                service.networkControlStore.validateSpaceAdmission(&record.targetSpaceId,
                    &record.sourceSpaceId, &members, &operations)?;
                service.spaceStore.importDeviceProfiles(record.source.deviceProfiles.clone())?;
                service.spaceStore.importTopologyRecords(record.source.topology.clone())?;
                service.networkControlStore.applyBootstrapOperation(operation)?;
                let mut joined = current;
                joined.members.extend(record.source.space.members.clone());
                joined.members.sort();
                joined.members.dedup();
                joined.spaceRevision = joined.spaceRevision.max(outcome.revision).max(record.sourceRevision).checked_add(1).ok_or("Space revision overflow")?;
                service.spaceStore.adopt(joined)?;
                record.accepted = Some(service.peerSpaceSnapshot()?);
                record.request.status = SpaceJoinStatus::Approved;
            } else {
                if outcome.admission.is_some() { return Err("Rejection must not contain an admission".into()); }
                record.request.status = SpaceJoinStatus::Rejected;
            }
            store(service).putRecord(INBOUND, &record.request.requestId, &record)?;
            toCoreValue(record).map_err(|e| e.to_string())
        }
        _ => Err("Unknown Space approval method".into()),
    }
}

/// Approves the complete source Space in one policy operation before publishing membership.
pub(super) async fn decide(service: &RuntimeRemoteLinkService, id: String, version: u64, approve: bool) -> Result<SpaceJoinRequest, String> {
    let local = service.nodeRouter.localNodeId();
    if !canReview(service, &local)? { return Err("This device cannot approve Space join requests".into()); }
    let inbox = load(service, INBOX, &id)?;
    let claim: Claim = approvalCall(service, &inbox.request.targetDeviceId, "claim", toCoreValue(Decision {
        requestId: id.clone(), assignmentVersion: version, approve,
    }).map_err(|e| e.to_string())?).await?;
    validateResponse(&inbox, &claim.record)?;
    if matches!(claim.record.request.status, SpaceJoinStatus::Approved | SpaceJoinStatus::Rejected) { return Ok(claim.record.request); }
    let saved = store(service).records::<Outcome>(RESULTS)?.remove(&id);
    let outcome = if let Some(saved) = saved {
        if saved.decision.assignmentVersion != version || saved.decision.approve != approve { return Err("Stored decision differs from the claim".into()); }
        saved
    } else {
        let mut revision = claim.current.space.spaceRevision;
        let admission = if approve {
            CoreSpaceStore::validateSpaceProfiles(&claim.current.space, &claim.current.deviceProfiles)?;
            service.spaceStore.importDeviceProfiles(claim.current.deviceProfiles.clone())?;
            service.spaceStore.importTopologyRecords(claim.current.topology.clone())?;
            for operation in &claim.current.controlOperations { service.networkControlStore.applyBootstrapOperation(operation)?; }
            let mut joined = service.spaceStore.initialize()?;
            if joined.spaceId != claim.record.targetSpaceId { return Err("Reviewer changed Space".into()); }
            for node in claim.current.space.members { if !joined.members.contains(&node) { joined.members.push(node); } }
            CoreSpaceStore::validateSpaceProfiles(&claim.record.source.space, &claim.record.source.deviceProfiles)?;
            service.spaceStore.importDeviceProfiles(claim.record.source.deviceProfiles.clone())?;
            service.spaceStore.importTopologyRecords(claim.record.source.topology.clone())?;
            let operation = service.networkControlStore.admitSpace(claim.record.sourceSpaceId.clone(),
                claim.record.source.space.members.iter().cloned().collect())?;
            joined.members.extend(claim.record.source.space.members.clone());
            joined.members.sort();
            joined.members.dedup();
            revision = revision.max(joined.spaceRevision).max(claim.record.sourceRevision).checked_add(1).ok_or("Space revision overflow")?;
            joined.spaceRevision = revision;
            service.spaceStore.adopt(joined)?;
            Some(operation)
        } else { None };
        let outcome = Outcome { decision: Decision { requestId: id.clone(), assignmentVersion: version, approve }, admission, revision };
        store(service).putRecord(RESULTS, &id, &outcome)?;
        outcome
    };
    let record: Record = approvalCall(service, &inbox.request.targetDeviceId, "complete", toCoreValue(outcome).map_err(|e| e.to_string())?).await?;
    validateResponse(&inbox, &record)?;
    Ok(record.request)
}

/// Applies the approved group merge with profiles and policy preceding member publication.
pub(super) async fn refresh(service: &RuntimeRemoteLinkService, id: String) -> Result<SpaceJoinRequest, String> {
    let local = load(service, OUTBOUND, &id)?;
    if !active(&local.request.status) { return Ok(local.request); }
    paired(service, &local.request.targetDeviceId, false)?;
    let mut remote = sendSubmission(service, &local).await?;
    validateResponse(&local, &remote)?;
    if remote.request.status == SpaceJoinStatus::Approved {
        let current = service.spaceStore.initialize()?;
        let accepted = remote.accepted.as_ref().ok_or("Approved join has no membership result")?;
        if accepted.space.spaceId != local.targetSpaceId
            || !accepted.space.members.contains(&service.nodeRouter.localNodeId())
            || !accepted.space.members.contains(&local.request.targetDeviceId) {
            return Err("Approved membership does not match the request".into());
        }
        if current.spaceId != local.sourceSpaceId && current.spaceId != local.targetSpaceId {
            return Err("Local Space changed while waiting; join will not be applied".into());
        }
        // Read the current target revision, not an obsolete approval snapshot.
        let snapshot: PeerSpaceSnapshot = service.callPeerSpace(&local.request.targetDeviceId, "snapshot", CoreValue::Null).await?;
        if snapshot.space.spaceId != local.targetSpaceId || !snapshot.space.members.contains(&local.request.applicantDeviceId) {
            return Err("Approved target membership changed".into());
        }
        CoreSpaceStore::validateSpaceProfiles(&snapshot.space, &snapshot.deviceProfiles)?;
        let members = local.source.space.members.iter().cloned().collect();
        service.networkControlStore.validateSpaceAdmission(&snapshot.space.spaceId,
            &local.sourceSpaceId, &members, &snapshot.controlOperations)?;
        let currentMembers = current.members.iter().collect::<BTreeSet<_>>();
        let approvedMembers = snapshot.space.members.iter().collect::<BTreeSet<_>>();
        if !currentMembers.is_subset(&approvedMembers) {
            return Err("Source Space gained members after approval; submit a new merge request".into());
        }
        service.spaceStore.importDeviceProfiles(snapshot.deviceProfiles)?;
        service.spaceStore.importTopologyRecords(snapshot.topology)?;
        for operation in &snapshot.controlOperations { service.networkControlStore.applyBootstrapOperation(operation)?; }
        service.spaceStore.adopt(snapshot.space)?;
        remote.request.status = SpaceJoinStatus::Joined;
    }
    remote.request.canApprove = false;
    let published = publishOutgoingResponse(service, &id, &remote)?;
    if published.status == SpaceJoinStatus::Joined {
        if let Err(e) = service.persistenceSyncService().synchronizeReachablePeer(local.request.targetDeviceId, 512, true).await {
            operit_util::AppLogger::AppLogger::w("SpaceJoin", &format!("Join approved; initial data sync failed: {e}"));
        }
    }
    Ok(published)
}

/// Publishes a response without allowing an older poll to resurrect a terminal request.
fn publishOutgoingResponse(service: &RuntimeRemoteLinkService, id: &str, remote: &Record) -> Result<SpaceJoinRequest, String> {
    let _lock = MUTATION.lock().map_err(|e| e.to_string())?;
    let current = load(service, OUTBOUND, id)?;
    if preserveOutgoingStatus(&current.request.status, &remote.request.status) {
        return Ok(current.request);
    }
    store(service).putRecord(OUTBOUND, id, remote)?;
    Ok(remote.request.clone())
}

/// Prevents delayed responses from rolling a durable request back to an earlier state.
fn preserveOutgoingStatus(current: &SpaceJoinStatus, incoming: &SpaceJoinStatus) -> bool {
    !active(current)
        || (*current == SpaceJoinStatus::Approving && *incoming == SpaceJoinStatus::Pending)
        || (*current == SpaceJoinStatus::Approved
            && matches!(incoming, SpaceJoinStatus::Pending | SpaceJoinStatus::Approving))
}

/// Cancels a pending request and persists its acknowledged state before any stale poll can finish.
pub(super) async fn cancel(service: &RuntimeRemoteLinkService, id: String) -> Result<SpaceJoinRequest, String> {
    let local = load(service, OUTBOUND, &id)?;
    let remote: Record = service.callPeerSpace(&local.request.targetDeviceId, "cancelJoin", toCoreValue(Submission {
        requestId: id.clone(), sourceSpaceId: local.sourceSpaceId.clone(),
        sourceRevision: local.sourceRevision, targetSpaceId: local.targetSpaceId.clone(), profile: local.profile.clone(), source: local.source.clone(),
    }).map_err(|e| e.to_string())?).await?;
    validateResponse(&local, &remote)?;
    let published = publishOutgoingResponse(service, &id, &remote)?;
    // A simultaneous claim/approval wins. Apply it rather than pretend cancellation succeeded.
    if active(&published.status) { return refresh(service, id).await; }
    Ok(published)
}

#[cfg(test)]
mod device_space_state_tests {
    include!(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/device_space/join_state_machine.rs"));
}
