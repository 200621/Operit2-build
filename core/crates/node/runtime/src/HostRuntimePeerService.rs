//! 生产节点通信：唯一的配对/鉴权入口，所有 I/O 委托 PeerLink 和 Host。
//! 未鉴权只接受 hello/authorize；已鉴权 Call/Watch/Push 交给 Router。
use crate::{CoreNodeRouter::CoreNodeRouter, NodeServices::*, PeerStateStore::{PeerStateStore, StoredInbound, StoredOutbound, PAIRING_SERVICE_VERSION},
    RuntimePeerService::RuntimePeerService};
use async_trait::async_trait;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use operit_host_api::{HostManager::HostManager, TimeUtils::currentTimeMillis};
use operit_link::*;
use operit_peer_link::{HostPeerLink, PeerConnection, PeerLink, PeerListener, PeerMessage};
use operit_util::RuntimeStorageLayout::*;
use serde::{Deserialize, Serialize};
use std::{collections::{BTreeMap, BTreeSet}, sync::{Arc, Mutex, Weak}};
use tokio::sync::{broadcast, Mutex as AsyncMutex};
#[path = "peer/crypto.rs"] mod crypto;
use crypto::{Channel, ChannelLease, MultiplexedChannel, error};
#[path = "peer/heartbeat.rs"] mod heartbeat;
#[path = "peer/live_channel.rs"] mod live_channel;
use live_channel::LiveChannel;
#[path = "peer/dispatch.rs"] mod dispatch;
#[path = "peer/space_channel.rs"] mod space_channel;
#[path = "peer/availability.rs"] mod availability;
const HANDSHAKE: &str = "$peer.pairing";

const PAIRING_LIFETIME_MS: i64 = 300_000;
const MAX_POOLED_CHANNELS_PER_PEER: usize = 8;
const MAX_LOGICAL_LEASES_PER_CHANNEL: usize = 16;

#[derive(Clone, Serialize, Deserialize)]
struct Pending {
    version: u32, id: String, clientDeviceId: String, peerNodeId: String,
    endpoint: String, transport: PeerTransport, info: LinkDeviceInfo,
    root: Vec<u8>, expires: i64, attempts: u8,
    #[serde(default)] confirmationCode: Option<String>,
}
#[derive(Serialize, Deserialize)]
struct Hello {
    version: u32, nodeId: String, expectedNodeId: String, info: LinkDeviceInfo,
    public: Vec<u8>, purpose: String, sessionId: String,
}
#[derive(Serialize, Deserialize)]
struct HelloReply { transcript: crypto::Transcript, info: LinkDeviceInfo, tokenRequired: bool }
#[derive(Serialize, Deserialize)]
struct Authorization { tokenProof: Vec<u8>, keyProof: Vec<u8> }
#[derive(Serialize, Deserialize)]
struct Authorized { proof: Vec<u8>, pairingId: String }

struct State {
    host: Arc<HostManager>, link: HostPeerLink, store: PeerStateStore,
    nodeId: String, info: LinkDeviceInfo, router: Weak<CoreNodeRouter>,
    listeners: AsyncMutex<BTreeMap<PeerTransport, Arc<dyn PeerListener>>>,
    connections: Mutex<BTreeMap<String, Vec<Weak<dyn PeerConnection>>>>,
    pooledChannels: Mutex<BTreeMap<String, Arc<AsyncMutex<Vec<Arc<MultiplexedChannel>>>>>>,
    liveChannels: Mutex<BTreeMap<String, Vec<Weak<LiveChannel>>>>,
    advertisements: Mutex<Vec<Box<dyn operit_host_api::ServiceDiscovery::DiscoveryAdvertisement>>>,
    slots: Arc<tokio::sync::Semaphore>,
    active: Mutex<BTreeSet<String>>, changes: broadcast::Sender<()>,
    availability: Mutex<Option<availability::AvailabilityWorker>>,
    lifecycle: AsyncMutex<()>,
    /// 本节点的配对/撤销持久化操作串行化，不持锁执行网络 I/O。
    mutation: Mutex<()>,
}
#[derive(Clone)]
pub struct HostRuntimePeerService { state: Arc<State> }
impl HostRuntimePeerService {
    /// Creates shared peer services and starts availability checks on the supplied Host scheduler.
    pub fn new(host: Arc<HostManager>, router: &Arc<CoreNodeRouter>, info: LinkDeviceInfo) -> Result<Arc<Self>, String> {
        let storage = host.runtimeStorageHost.clone().ok_or("Runtime storage Host is not installed")?;
        let service = Arc::new(Self { state: Arc::new(State {
            host, link: HostPeerLink::default(), store: PeerStateStore::new(storage),
            nodeId: router.localNodeId(), info, router: Arc::downgrade(router),
            listeners: AsyncMutex::new(BTreeMap::new()), connections: Mutex::new(BTreeMap::new()),
            pooledChannels: Mutex::new(BTreeMap::new()), liveChannels: Mutex::new(BTreeMap::new()),
            advertisements: Mutex::new(Vec::new()), slots: Arc::new(tokio::sync::Semaphore::new(64)),
            active: Mutex::new(BTreeSet::new()), changes: broadcast::channel(32).0,
            availability: Mutex::new(None), lifecycle: AsyncMutex::new(()),
            mutation: Mutex::new(()),
        }) });
        service.startAvailabilityWorker().map_err(|error| error.to_string())?;
        Ok(service)
    }
    fn router(&self) -> Result<CoreNodeRouter, CoreLinkError> {
        self.state.router.upgrade().map(|r| (*r).clone()).ok_or_else(|| error("Node application has stopped"))
    }
    fn changed(&self) { let _ = self.state.changes.send(()); }
    fn track(&self, node: &str, raw: &Arc<dyn PeerConnection>) {
        let mut connections = self.state.connections.lock().unwrap();
        let list = connections.entry(node.into()).or_default();
        list.retain(|c| c.strong_count() != 0); list.push(Arc::downgrade(raw));
    }
    fn pending(&self, inbound: bool, id: &str) -> Result<Pending, CoreLinkError> {
        let path = if inbound { RUNTIME_LINK_ACCESS_PENDING_PAIRINGS_PATH } else { RUNTIME_LINK_ACCESS_PENDING_OUTBOUND_PAIRINGS_PATH };
        let p = self.pendingRecords(path)?.remove(id)
            .ok_or_else(|| error("Pairing transaction not found"))?;
        if p.expires <= currentTimeMillis() { self.state.store.deleteRecord(path, id).map_err(error)?; return Err(error("Pairing transaction expired")); }
        Ok(p)
    }
    fn inboundCredentials(&self) -> Result<BTreeMap<String, StoredInbound>, CoreLinkError> {
        self.state.store.records(RUNTIME_LINK_ACCESS_INBOUND_SESSIONS_PATH).map_err(error)
    }
    fn pendingRecords(&self, path: &str) -> Result<BTreeMap<String, Pending>, CoreLinkError> {
        let raw = self.state.store.records::<serde_json::Value>(path).map_err(error)?;
        raw.into_iter().filter(|(_, r)| r.get("version").and_then(|v| v.as_u64()) == Some(PAIRING_SERVICE_VERSION as u64))
            .map(|(id, r)| serde_json::from_value(r).map(|r| (id, r)).map_err(|e| error(e.to_string()))).collect()
    }
    fn outbound(&self, node: &str) -> Result<StoredOutbound, CoreLinkError> {
        self.state.store.records::<StoredOutbound>(RUNTIME_LINK_ACCESS_OUTBOUND_SESSIONS_PATH).map_err(error)?
            .into_values().find(|c| c.peerNodeId == node && c.pairingServiceVersion == PAIRING_SERVICE_VERSION)
            .ok_or_else(|| CoreLinkError::new("PEER_OUTBOUND_NOT_AUTHORIZED", "No current outbound authorization for node"))
    }
    /// Rejects an existing device authorization in either pairing direction.
    fn ensureDeviceUnpaired(&self, peerNodeId: &str) -> Result<(), CoreLinkError> {
        if self.state.store.pairedPeers(&self.state.nodeId).map_err(error)?.iter().any(|peer| peer.nodeId == peerNodeId) {
            return Err(CoreLinkError::new("PEER_ALREADY_PAIRED", "Device is already paired"));
        }
        Ok(())
    }
    async fn raw(&self, target: PeerEndpoint, transport: PeerTransport) -> Result<Arc<dyn PeerConnection>, CoreLinkError> {
        self.state.link.connect(self.state.host.clone(), PeerEndpoint { nodeId: self.state.nodeId.clone(), address: String::new() }, target, transport).await.map_err(error)
    }
    /// 主动端与接收端共用握手，无论 HTTP/WS/TCP/串口/蓝牙。
    async fn handshake(&self, raw: Arc<dyn PeerConnection>, purpose: &str, sessionId: &str,
        saved: Option<&[u8]>, token: Option<&str>,
    ) -> Result<(Arc<Channel>, String, LinkDeviceInfo, Vec<u8>, String), CoreLinkError> {
        let (private, public) = crypto::ephemeral()?;
        let hello = Hello { version: PAIRING_SERVICE_VERSION, nodeId: self.state.nodeId.clone(),
            expectedNodeId: raw.target().nodeId.clone(), info: self.state.info.clone(), public: public.clone(),
            purpose: purpose.into(), sessionId: sessionId.into() };
        let reply: HelloReply = rawCall(&raw, "hello", &hello).await?;
        let t = &reply.transcript;
        if t.version != PAIRING_SERVICE_VERSION || t.clientNodeId != self.state.nodeId || t.clientPublic != public
            || (!raw.target().nodeId.is_empty() && t.serverNodeId != raw.target().nodeId)
            || t.serverNodeId == self.state.nodeId || t.serverPublic.len() != 32 || t.challenge.len() != 32
            || (!sessionId.is_empty() && t.sessionId != sessionId) {
            return Err(error("Handshake identity/transcript mismatch"));
        }
        let context = crypto::transcript(t)?;
        let dh = crypto::agree(private, &t.serverPublic)?;
        let root = crypto::derive(&dh, &context, b"operit-pairing-root-v1")?;
        let key = match saved { Some(saved) => crypto::derive(&dh, saved, &context)?, None => root };
        let tokenProof = if purpose == "start" && reply.tokenRequired {
            crypto::proof(token.ok_or_else(|| error("Token required for non-LAN pairing"))?.as_bytes(), &context, b"token")
        } else { vec![] };
        let accepted: Authorized = rawCall(&raw, "authorize", &Authorization {
            tokenProof, keyProof: crypto::proof(&key, &context, b"client"),
        }).await?;
        crypto::verify(&key, &context, b"server", &accepted.proof)?;
        if accepted.pairingId != t.sessionId { return Err(error("Pairing correlation mismatch")); }
        let id = t.sessionId.clone(); let peerNodeId = t.serverNodeId.clone(); let info = reply.info;
        Ok((Channel::new(raw, &key, &context, true)?, id, info, root.to_vec(), peerNodeId))
    }
    /// Gets the per-peer pool lock without retaining a global lock during network I/O.
    fn channelPool(&self, node: &str) -> Arc<AsyncMutex<Vec<Arc<MultiplexedChannel>>>> {
        self.state.pooledChannels.lock().unwrap().entry(node.into())
            .or_insert_with(|| Arc::new(AsyncMutex::new(Vec::new()))).clone()
    }

    /// Tracks an authenticated connection generation and its terminal availability changes.
    fn startLiveChannel(&self, node: &str, channel: Arc<Channel>) -> Result<Arc<LiveChannel>, CoreLinkError> {
        let state = Arc::downgrade(&self.state);
        let peer = node.to_string();
        let scheduler = self.state.host.hostRuntimeTaskSchedulerHost.clone()
            .ok_or_else(|| error("Host scheduler is not installed"))?;
        let channel = LiveChannel::start(channel, scheduler, move || {
            if let Some(state) = state.upgrade() {
                HostRuntimePeerService { state }.refreshPeerAvailability(&peer);
            }
        })?;
        {
            let mut channels = self.state.liveChannels.lock().unwrap();
            let channels = channels.entry(node.into()).or_default();
            channels.retain(|channel| channel.strong_count() != 0);
            channels.push(Arc::downgrade(&channel));
        }
        self.refreshPeerAvailability(node);
        Ok(channel)
    }

    /// Derives peer availability from all current authenticated connection generations.
    fn refreshPeerAvailability(&self, node: &str) {
        let channels = self.state.liveChannels.lock().unwrap();
        let available = self.requirePeerConnectionAllowed(node).is_ok()
            && channels.get(node).is_some_and(|channels| channels.iter()
                .filter_map(Weak::upgrade).any(|channel| channel.isAvailable()));
        let mut active = self.state.active.lock().unwrap();
        let changed = if available { active.insert(node.into()) } else { active.remove(node) };
        drop(active);
        drop(channels);
        if changed { self.changed(); }
    }

    /// Reports whether any current authenticated channel can still carry peer traffic.
    fn hasLiveChannel(&self, node: &str) -> bool {
        self.state.liveChannels.lock().unwrap().get(node).is_some_and(|channels| channels.iter()
            .filter_map(Weak::upgrade).any(|channel| channel.isAvailable()))
    }
    /// Acquires a lazily created multiplexed channel from the fixed per-peer pool.
    pub(super) async fn acquirePooledChannel(&self, node: &str) -> Result<ChannelLease, CoreLinkError> {
        self.requirePeerConnectionAllowed(node)?;
        let pool = self.channelPool(node);
        let mut channels = pool.lock().await;
        channels.retain(|channel| !channel.isFailed());
        if let Some(channel) = channels.iter().min_by_key(|channel| channel.activeLeases()) {
            if channel.activeLeases() < MAX_LOGICAL_LEASES_PER_CHANNEL || channels.len() >= MAX_POOLED_CHANNELS_PER_PEER {
                match self.outbound(node) {
                    Ok(record) => {
                        if !channel.hasSpaceOffer(&record.sessionId).await
                            && self.offerSpaceChannelMultiplexed(node, &record.sessionId, channel).await? {
                            channel.markSpaceOffer(&record.sessionId).await;
                        }
                    }
                    Err(error) if error.code == "PEER_OUTBOUND_NOT_AUTHORIZED" => {}
                    Err(error) => return Err(error),
                }
                return Ok(channel.lease());
            }
        }
        let raw = self.connectAuthorized(node).await?;
        let scheduler = self.state.host.hostRuntimeTaskSchedulerHost.clone()
            .ok_or_else(|| error("Host scheduler is not installed"))?;
        let channel = MultiplexedChannel::start(raw, scheduler)?;
        channels.push(channel.clone());
        Ok(channel.lease())
    }

    /// Returns the number of live pooled channels for one peer in test builds.
    #[cfg(test)]
    pub(crate) async fn pooledChannelCount(&self, node: &str) -> usize {
        self.channelPool(node).lock().await.len()
    }

    async fn connectAuthorized(&self, node: &str) -> Result<Arc<LiveChannel>, CoreLinkError> {
        self.requirePeerConnectionAllowed(node)?;
        let (purpose, sessionId, secret, endpoint, transport) = match self.outbound(node) {
            Ok(record) => ("session", record.sessionId, record.sessionSecret, record.endpoint, parseTransport(&record.transport)?),
            Err(e) if e.code == "PEER_OUTBOUND_NOT_AUTHORIZED" => {
                let grant = self.spaceOutbound(node)?;
                ("space", grant.id, grant.secret, grant.endpoint, grant.transport)
            }
            Err(e) => return Err(e),
        };
        let root = BASE64.decode(&secret).map_err(|_| error("Invalid stored credential"))?;
        let raw = self.raw(PeerEndpoint { nodeId: node.into(), address: endpoint }, transport).await?;
        let result = self.handshake(raw.clone(), purpose, &sessionId, Some(&root), None).await;
        let (channel, _, _, _, _) = match result { Ok(result) => result, Err(e) => { raw.close().await; return Err(e); } };
        self.track(node, &raw);
        let channel = self.startLiveChannel(node, channel)?;
        if purpose == "session" {
            if let Err(e) = self.offerSpaceChannel(node, &sessionId, &channel).await { raw.close().await; return Err(e); }
        }
        if let Err(e) = self.requirePeerConnectionAllowed(node) { raw.close().await; return Err(e); }
        Ok(channel)
    }
    async fn readHandshake(&self, raw: &Arc<dyn PeerConnection>, method: &str) -> Result<CoreCallRequest, CoreLinkError> {
        let delay = self.state.host.hostRuntimeTaskSchedulerHost.as_ref().ok_or_else(|| error("Host scheduler missing"))?.waitForHostRuntimeDelay(15_000);
        tokio::select! { r = readCall(raw, method) => r, _ = delay => Err(error("Unauthenticated handshake deadline reached")) }
    }
    async fn serve(&self, raw: Arc<dyn PeerConnection>) -> Result<(), CoreLinkError> {
        let helloRequest = self.readHandshake(&raw, "hello").await?;
        let hello: Hello = fromCoreValue(helloRequest.args.clone()).map_err(|e| error(e.to_string()))?;
        if hello.version != PAIRING_SERVICE_VERSION || hello.nodeId.is_empty() || hello.nodeId == self.state.nodeId
            || (!hello.expectedNodeId.is_empty() && hello.expectedNodeId != self.state.nodeId)
            || !matches!(hello.purpose.as_str(), "start" | "finish" | "session" | "space") {
            return sendError(&raw, helloRequest.requestId, error("Invalid pairing identity/purpose")).await;
        }
        if matches!(hello.purpose.as_str(), "session" | "space") {
            self.requirePeerConnectionAllowed(&hello.nodeId)?;
        }
        // 沿用持久化的 sessionId/sessionSecret；配对事务仍受过期时间和尝试上限保护。
        let saved = match hello.purpose.as_str() {
            "start" => None,
            "finish" => { let p = self.pending(true, &hello.sessionId)?;
                if p.clientDeviceId != hello.nodeId { return Err(error("Pairing identity mismatch")); }
                Some(p.root) },
            "space" => Some(BASE64.decode(&self.spaceInbound(&hello.sessionId, &hello.nodeId)?.secret)
                .map_err(|_| error("Invalid Space credential"))?),
            _ => {
                let records = self.inboundCredentials()?;
                let record = records.get(&hello.sessionId).ok_or_else(|| error("Inbound authorization not found"))?;
                if record.deviceId != hello.nodeId || record.pairingServiceVersion != PAIRING_SERVICE_VERSION { return Err(error("Inbound identity/version mismatch")); }
                Some(BASE64.decode(&record.sessionSecret).map_err(|_| error("Invalid stored credential"))?)
            },
        };
        let config = self.state.store.hostConfig().map_err(error)?.ok_or_else(|| error("Listener not configured"))?;
        // 免 token 必须同时开启本地发现，且来源是 Host 实际接入地址；未知来源 fail closed。
        let lan = config.discoveryEnabled && raw.remoteAddress().is_some_and(|a| isLocalAddress(a.ip()));
        let tokenRequired = hello.purpose == "start" && !lan;
        let (private, public) = crypto::ephemeral()?;
        let id = if hello.purpose == "start" { uuid::Uuid::new_v4().to_string() } else { hello.sessionId.clone() };
        let transcript = crypto::Transcript { version: PAIRING_SERVICE_VERSION, sessionId: id.clone(),
            clientNodeId: hello.nodeId.clone(), serverNodeId: self.state.nodeId.clone(),
            clientPublic: hello.public, serverPublic: public, challenge: crypto::random()?.to_vec() };
        let context = crypto::transcript(&transcript)?;
        let dh = crypto::agree(private, &transcript.clientPublic)?;
        let root = crypto::derive(&dh, &context, b"operit-pairing-root-v1")?;
        let key = match &saved { Some(saved) => crypto::derive(&dh, saved, &context)?, None => root };
        sendValue(&raw, helloRequest.requestId, HelloReply { transcript, info: self.state.info.clone(), tokenRequired }).await?;
        let request = self.readHandshake(&raw, "authorize").await?;
        let authorization: Authorization = fromCoreValue(request.args).map_err(|e| error(e.to_string()))?;
        let admission = (|| {
            if tokenRequired {
                if config.token.is_empty() { return Err(error("Non-LAN pairing token is not configured")); }
                crypto::verify(config.token.as_bytes(), &context, b"token", &authorization.tokenProof)?;
            }
            crypto::verify(&key, &context, b"client", &authorization.keyProof)?;
            if hello.purpose == "start" {
                let _guard = self.state.mutation.lock().unwrap();
                self.ensureDeviceUnpaired(&hello.nodeId)?;
                let pending = self.pendingRecords(RUNTIME_LINK_ACCESS_PENDING_PAIRINGS_PATH)?;
                if pending.values().filter(|p| p.expires > currentTimeMillis()).count() >= 32 { return Err(error("Pending pairing capacity reached")); }
                self.state.store.putRecord(RUNTIME_LINK_ACCESS_PENDING_PAIRINGS_PATH, &id, &Pending {
                    version: PAIRING_SERVICE_VERSION, id: id.clone(), clientDeviceId: hello.nodeId.clone(), peerNodeId: self.state.nodeId.clone(),
                    endpoint: String::new(), transport: raw.transport(), info: hello.info.clone(),
                    root: root.to_vec(), expires: currentTimeMillis() + PAIRING_LIFETIME_MS, attempts: 0,
                    confirmationCode: Some(crypto::pairingCode()?),
                }).map_err(error)?;
                self.changed();
            }
            Ok(())
        })();
        if let Err(e) = admission { return sendError(&raw, request.requestId, e).await; }
        sendValue(&raw, request.requestId, Authorized { proof: crypto::proof(&key, &context, b"server"), pairingId: id.clone() }).await?;
        if hello.purpose == "start" { return Ok(()); }
        let channel = Channel::new(raw.clone(), &key, &context, false)?;
        self.track(&hello.nodeId, &raw);
        if hello.purpose == "finish" {
            let Some(PeerMessage::Request(CoreLinkRequest::Call(request))) = channel.receive().await? else { return Err(error("Encrypted confirmation Call required")); };
            if request.target != HANDSHAKE || request.methodName != "finish" { return Err(error("Confirmation required before business")); }
            let proof: Vec<u8> = fromCoreValue(request.args).map_err(|e| error(e.to_string()))?;
            let result = (|| {
                let _guard = self.state.mutation.lock().unwrap();
                let mut pending = self.pending(true, &id)?;
                self.ensureDeviceUnpaired(&hello.nodeId)?;
                if pending.attempts >= 5 { return Err(error("Confirmation attempt limit reached")); }
                pending.attempts += 1;
                self.state.store.putRecord(RUNTIME_LINK_ACCESS_PENDING_PAIRINGS_PATH, &id, &pending).map_err(error)?;
                let code = pending.confirmationCode.as_deref().ok_or_else(|| error("Receiver confirmation missing"))?;
                crypto::verify(&pending.root, id.as_bytes(), code.as_bytes(), &proof)?;
                let record = StoredInbound { deviceId: hello.nodeId.clone(), deviceInfo: hello.info.clone(),
                    pairingServiceVersion: PAIRING_SERVICE_VERSION, sessionSecret: BASE64.encode(&pending.root) };
                self.state.store.putRecord(RUNTIME_LINK_ACCESS_INBOUND_SESSIONS_PATH, &id, &record).map_err(error)?;
                self.state.store.deleteRecord(RUNTIME_LINK_ACCESS_PENDING_PAIRINGS_PATH, &id).map_err(error)?;
                // The receiver just verified a live authenticated Mac too. Do not
                // wait for Mac to make a subsequent application call to show it online.
                self.state.active.lock().unwrap().insert(hello.nodeId.clone());
                self.changed(); Ok(CoreValue::Null)
            })();
            channel.send(PeerMessage::Response(CoreLinkResponse::Call(CoreCallResponse { requestId: request.requestId, result }))).await?;
            return Ok(());
        }
        let channel = self.startLiveChannel(&hello.nodeId, channel)?;
        dispatch::serve(self.clone(), channel, hello.nodeId, id, hello.purpose == "space").await
    }
}

fn failureProvesPeerUnavailable(error: &CoreLinkError) -> bool {
    error.code != "PEER_OUTBOUND_NOT_AUTHORIZED"
}

async fn readCall(raw: &Arc<dyn PeerConnection>, method: &str) -> Result<CoreCallRequest, CoreLinkError> {
    match raw.receive().await.map_err(error)? {
        Some(PeerMessage::Request(CoreLinkRequest::Call(r))) if r.target == HANDSHAKE && r.methodName == method => Ok(r),
        _ => Err(error("Unauthenticated operation is not in the pairing whitelist")),
    }
}
async fn rawCall<T: Serialize, R: serde::de::DeserializeOwned>(raw: &Arc<dyn PeerConnection>, method: &str, args: &T) -> Result<R, CoreLinkError> {
    let id = CoreRequestId::new(uuid::Uuid::new_v4().to_string());
    raw.send(PeerMessage::Request(CoreLinkRequest::Call(CoreCallRequest::new(id.0.clone(), HANDSHAKE, method,
        toCoreValue(args).map_err(|e| error(e.to_string()))?)))).await.map_err(error)?;
    match raw.receive().await.map_err(error)? {
        Some(PeerMessage::Response(CoreLinkResponse::Call(r))) if r.requestId == id => fromCoreValue(r.result?).map_err(|e| error(e.to_string())),
        _ => Err(error("Pairing response correlation mismatch")),
    }
}
async fn sendValue(raw: &Arc<dyn PeerConnection>, id: CoreRequestId, value: impl Serialize) -> Result<(), CoreLinkError> {
    raw.send(PeerMessage::Response(CoreLinkResponse::Call(CoreCallResponse::ok(id, toCoreValue(value).map_err(|e| error(e.to_string()))?))))
        .await.map_err(error)
}
async fn sendError(raw: &Arc<dyn PeerConnection>, id: CoreRequestId, e: CoreLinkError) -> Result<(), CoreLinkError> {
    raw.send(PeerMessage::Response(CoreLinkResponse::Call(CoreCallResponse::err(id, e)))).await.map_err(error)
}
fn transportName(t: PeerTransport) -> &'static str { match t {
    PeerTransport::Http => "http", PeerTransport::WebSocket => "ws", PeerTransport::Tcp => "tcp",
    PeerTransport::Serial => "serial", PeerTransport::Bluetooth => "bluetooth",
} }
fn parseTransport(t: &str) -> Result<PeerTransport, CoreLinkError> { match t {
    "http" => Ok(PeerTransport::Http), "ws" => Ok(PeerTransport::WebSocket), "tcp" => Ok(PeerTransport::Tcp),
    "serial" => Ok(PeerTransport::Serial), "bluetooth" => Ok(PeerTransport::Bluetooth), _ => Err(error("Unknown transport")),
} }
fn isLocalAddress(address: std::net::IpAddr) -> bool { match address {
    std::net::IpAddr::V4(ip) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
    std::net::IpAddr::V6(ip) => ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local()
        || ip.to_ipv4_mapped().is_some_and(|ip| isLocalAddress(ip.into())),
} }

#[async_trait(?Send)]
impl RuntimePeerService for HostRuntimePeerService {
    /// Returns only unpaired candidates using the current state after discovery completes.
    async fn discoverPeers(&self, timeoutMs: u64) -> Result<Vec<DiscoveredPeer>, CoreLinkError> {
        let host = self.state.host.serviceDiscoveryHost.clone().ok_or_else(|| error("Discovery Host is not installed"))?;
        let scheduler = self.state.host.hostRuntimeTaskSchedulerHost.as_ref().ok_or_else(|| error("Host scheduler is not installed"))?;
        let (tx, rx) = tokio::sync::oneshot::channel();
        scheduler.scheduleHostRuntimeTask("peer-discovery", Box::new(move || {
            let result = host.discover("_operit-link._tcp.local.", timeoutMs); let _ = tx.send(result);
        })).map_err(|e| error(e.to_string()))?;
        let records = rx.await.map_err(|_| error("Discovery cancelled"))?.map_err(|e| error(e.to_string()))?;
        let pairedNodeIds = self.state.store.pairedPeers(&self.state.nodeId).map_err(error)?
            .into_iter().map(|peer| peer.nodeId).collect::<BTreeSet<_>>();
        Ok(discoveredPeers(records, &self.state.nodeId, &pairedNodeIds))
    }
    /// Checks the known identity and the handshake result before creating a pairing transaction.
    async fn startPairing(&self, target: PeerEndpoint, transport: PeerTransport, token: Option<&str>) -> Result<PendingPairing, CoreLinkError> {
        if !target.nodeId.is_empty() {
            let _guard = self.state.mutation.lock().unwrap();
            self.ensureDeviceUnpaired(&target.nodeId)?;
        }
        let raw = self.raw(target.clone(), transport).await?;
        let result = self.handshake(raw.clone(), "start", "", None, token).await;
        raw.close().await;
        let (_, id, info, root, node) = result?;
        {
            let _guard = self.state.mutation.lock().unwrap();
            self.ensureDeviceUnpaired(&node)?;
            self.state.store.putRecord(RUNTIME_LINK_ACCESS_PENDING_OUTBOUND_PAIRINGS_PATH, &id, &Pending {
                version: PAIRING_SERVICE_VERSION, id: id.clone(), clientDeviceId: self.state.nodeId.clone(), peerNodeId: node.clone(), endpoint: target.address,
                transport, info: info.clone(), root, expires: currentTimeMillis() + PAIRING_LIFETIME_MS, attempts: 0, confirmationCode: None,
            }).map_err(error)?;
        }
        self.changed(); Ok(PendingPairing { pairingId: id, peerNodeId: node, displayName: info.displayName() })
    }
    /// Rechecks device uniqueness at each serialized confirmation boundary.
    async fn finishPairing(&self, id: &str, code: &str) -> Result<PairedPeer, CoreLinkError> {
        let pending = {
            let _guard = self.state.mutation.lock().unwrap();
            let mut p = self.pending(false, id)?;
            self.ensureDeviceUnpaired(&p.peerNodeId)?;
            if p.attempts >= 5 { return Err(error("Confirmation attempt limit reached")); }
            p.attempts += 1;
            self.state.store.putRecord(RUNTIME_LINK_ACCESS_PENDING_OUTBOUND_PAIRINGS_PATH, id, &p).map_err(error)?;
            // The receiver alone generates the six-digit user code. The encrypted
            // confirmation proof remains bound to this pairing's shared root/id;
            // the receiver checks the code and enforces expiration/attempt limits.
            if code.len() != 6 || !code.bytes().all(|c| c.is_ascii_digit()) {
                return Err(error("Enter the six-digit pairing code shown on the receiving device"));
            }
            p
        };
        let raw = self.raw(PeerEndpoint { nodeId: pending.peerNodeId.clone(), address: pending.endpoint.clone() }, pending.transport).await?;
        let result = async {
            let (channel, _, _, _, _) = self.handshake(raw.clone(), "finish", id, Some(&pending.root), None).await?;
            let request = CoreCallRequest::new(uuid::Uuid::new_v4().to_string(), HANDSHAKE, "finish",
                toCoreValue(crypto::proof(&pending.root, id.as_bytes(), code.as_bytes())).map_err(|e| error(e.to_string()))?);
            match channel.exchange(CoreLinkRequest::Call(request.clone())).await? {
                CoreLinkResponse::Call(r) if r.requestId == request.requestId => { r.result?; },
                _ => return Err(error("Confirmation response mismatch")),
            }
            Ok::<_, CoreLinkError>(())
        }.await;
        raw.close().await; result?;
        {
            let _guard = self.state.mutation.lock().unwrap();
            self.pending(false, id)?; // 撤销/取消不能被正在完成的网络事务重新授予权限。
            self.ensureDeviceUnpaired(&pending.peerNodeId)?;
            self.state.store.putRecord(RUNTIME_LINK_ACCESS_OUTBOUND_SESSIONS_PATH, id, &StoredOutbound {
                endpoint: pending.endpoint, sessionId: id.into(), deviceId: self.state.nodeId.clone(), peerNodeId: pending.peerNodeId.clone(),
                peerDeviceInfo: pending.info.clone(), pairingServiceVersion: PAIRING_SERVICE_VERSION,
                sessionSecret: BASE64.encode(&pending.root), transport: transportName(pending.transport).into(),
            }).map_err(error)?;
            self.state.store.deleteRecord(RUNTIME_LINK_ACCESS_PENDING_OUTBOUND_PAIRINGS_PATH, id).map_err(error)?;
            self.state.active.lock().unwrap().insert(pending.peerNodeId.clone());
        }
        self.changed();
        Ok(PairedPeer { nodeId: pending.peerNodeId, displayName: pending.info.displayName(), inbound: false, outbound: true })
    }
    async fn cancelPairing(&self, id: &str) -> Result<(), CoreLinkError> {
        let _guard = self.state.mutation.lock().unwrap();
        self.state.store.deleteRecord(RUNTIME_LINK_ACCESS_PENDING_OUTBOUND_PAIRINGS_PATH, id).map_err(error)?;
        self.changed(); Ok(())
    }
    /// Reports the operation capabilities supplied by this node's actual Host providers.
    fn listenerCapabilities(&self) -> operit_peer_link::PeerListenerCapabilities {
        HostPeerLink::listenerCapabilities(&self.state.host)
    }

    /// Validates every requested transport before opening the selected listeners.
    async fn startListening(&self, transports: &[PeerTransport]) -> Result<(), CoreLinkError> {
        let capabilities = self.listenerCapabilities();
        for transport in transports {
            if !capabilities.transports.contains(transport) {
                return Err(error(format!("Host does not support {transport:?} peer listeners")));
            }
        }
        let _lifecycle = self.state.lifecycle.lock().await;
        use crate::PeerStateStore::PeerHostPortMode;
        let mut config = self.state.store.hostConfig().map_err(error)?.ok_or_else(|| error("Configure bindAddress/token/transports before listening"))?;
        let scheduler = self.state.host.hostRuntimeTaskSchedulerHost.clone().ok_or_else(|| error("Host scheduler is not installed"))?;
        let mut listeners = self.state.listeners.lock().await;
        let requested: BTreeSet<_> = listeners.keys().copied().chain(transports.iter().copied()).collect();
        if requested.contains(&PeerTransport::Tcp) && (requested.contains(&PeerTransport::Http) || requested.contains(&PeerTransport::WebSocket)) {
            return Err(error("TCP cannot share a listener port with HTTP/WebSocket"));
        }
        let mut opened = BTreeMap::<PeerTransport, Arc<dyn PeerListener>>::new();
        let previousAddress = config.bindAddress.clone();
        let result = async {
            for transport in transports {
                if listeners.contains_key(transport) || opened.contains_key(transport) { continue; }
                // Choose an address only for the first network listener. HTTP and
                // WS must then attach to the same server, never select two ports.
                let canMove = config.portMode == PeerHostPortMode::Automatic
                    && !listeners.keys().chain(opened.keys()).any(|t| isNetworkTransport(*t));
                let (listener, address) = listenWithPortFallback(&self.state.link, self.state.host.clone(),
                    PeerEndpoint { nodeId: self.state.nodeId.clone(), address: config.bindAddress.clone() },
                    *transport, canMove).await.map_err(error)?;
                config.bindAddress = address;
                opened.insert(*transport, listener);
            }
            let mut advertisements = Vec::new();
            if config.discoveryEnabled && capabilities.discoveryAdvertisement && requested.iter().any(|t| isNetworkTransport(*t)) {
                let host = self.state.host.serviceDiscoveryHost.as_ref().ok_or_else(|| error("Discovery enabled but Host not installed"))?;
                let socket: std::net::SocketAddr = config.bindAddress.parse().map_err(|_| error("Discovery requires a concrete network bindAddress"))?;
                let properties = [("nodeId".into(), self.state.nodeId.clone()), ("displayName".into(), self.state.info.displayName()),
                    ("transports".into(), requested.iter().filter(|t| isNetworkTransport(**t)).map(|t| transportName(*t)).collect::<Vec<_>>().join(","))].into();
                if !opened.is_empty() || self.state.advertisements.lock().unwrap().is_empty() {
                    advertisements.push(host.advertise(operit_host_api::ServiceDiscovery::ServiceAdvertisement {
                        serviceType: "_operit-link._tcp.local.".into(), instance: self.state.nodeId.clone(),
                        hostname: format!("{}.local.", self.state.nodeId), port: socket.port(), properties,
                    }).map_err(|e| error(e.to_string()))?);
                }
            }
            for listener in opened.values() {
                let service = self.clone(); let accepting = listener.clone(); let tasks = scheduler.clone();
                scheduler.scheduleHostRuntimeAsyncTask("peer-listen", Box::new(move || Box::pin(async move {
                    while let Ok(Some(raw)) = accepting.accept().await {
                        let Ok(permit) = service.state.slots.clone().try_acquire_owned() else { raw.close().await; continue; };
                        service.track("", &raw);
                        let service = service.clone(); let connection = raw.clone();
                        if tasks.scheduleHostRuntimeAsyncTask("peer-connection", Box::new(move || Box::pin(async move {
                            let _permit = permit;
                            let result = service.serve(connection.clone()).await;
                            if let Err(e) = result { operit_util::AppLogger::AppLogger::w("RuntimePeerService", &e.to_string()); }
                            connection.close().await;
                        }))).is_err() { raw.close().await; }
                    }
                }))).map_err(|e| error(e.to_string()))?;
            }
            if config.bindAddress != previousAddress {
                config.updatedAt = currentTimeMillis();
                self.state.store.saveHostConfig(&config).map_err(error)?;
                operit_util::AppLogger::AppLogger::i("RuntimePeerService", &format!("Listener port occupied; moved from {previousAddress} to {}", config.bindAddress));
            }
            Ok::<_, CoreLinkError>(advertisements)
        }.await;
        match result {
            Ok(advertisements) => {
                listeners.extend(opened);
                if !advertisements.is_empty() { *self.state.advertisements.lock().unwrap() = advertisements; }
                self.startAvailabilityWorker()?;
                self.changed(); Ok(())
            }
            Err(e) => {
                // Do not leave partially started transports behind on failure.
                for listener in opened.into_values() { listener.close().await; }
                Err(e)
            }
        }
    }
    async fn stop(&self) -> Result<(), CoreLinkError> {
        let _lifecycle = self.state.lifecycle.lock().await;
        self.stopAvailabilityWorker().await;
        self.state.advertisements.lock().unwrap().clear();
        let listeners = std::mem::take(&mut *self.state.listeners.lock().await);
        for listener in listeners.into_values() { listener.close().await; }
        let connections = std::mem::take(&mut *self.state.connections.lock().unwrap());
        for raw in connections.into_values().flatten().filter_map(|v| v.upgrade()) { raw.close().await; }
        self.state.pooledChannels.lock().unwrap().clear();
        self.state.liveChannels.lock().unwrap().clear();
        self.state.active.lock().unwrap().clear(); self.changed(); Ok(())
    }
    async fn call(&self, node: &str, request: RoutedCoreRequest<CoreCallRequest>) -> CoreCallResponse {
        let id = request.payload.requestId.clone();
        let result = async {
            let channel = self.acquirePooledChannel(node).await?;
            let wire = dispatch::routedCall(request)?;
            let result = channel.channel().exchange(CoreLinkRequest::Call(wire)).await;
            match result? { CoreLinkResponse::Call(r) if r.requestId == id => Ok(r.result), _ => Err(error("Call response mismatch")) }
        }.await;
        if result.as_ref().err().is_some_and(failureProvesPeerUnavailable) {
            self.refreshPeerAvailability(node);
        }
        // Remote business errors prove a working authenticated link, not an offline peer.
        CoreCallResponse { requestId: id, result: result.and_then(|remote| remote) }
    }
    async fn watchSnapshot(&self, node: &str, request: RoutedCoreRequest<CoreWatchRequest>) -> Result<CoreEvent, CoreLinkError> {
        dispatch::watchSnapshot(self, node, request).await
    }
    async fn watch(&self, node: &str, request: RoutedCoreRequest<CoreWatchRequest>) -> Result<CoreEventStream, CoreLinkError> {
        dispatch::watch(self, node, request).await
    }
    async fn openPush(&self, node: &str, request: RoutedCoreRequest<CorePushRequest>) -> Result<Box<dyn CoreLinkPushSession>, CoreLinkError> {
        dispatch::openPush(self, node, request).await
    }
    fn pairedPeers(&self) -> Result<Vec<PairedPeer>, CoreLinkError> { self.state.store.pairedPeers(&self.state.nodeId).map_err(error) }
    fn outboundPeerNodeIds(&self) -> Result<BTreeSet<String>, CoreLinkError> { Ok(self.pairedPeers()?.into_iter().filter(|p| p.outbound).map(|p| p.nodeId).collect()) }
    fn activePeerNodeIds(&self) -> Result<BTreeSet<String>, CoreLinkError> { Ok(self.state.active.lock().unwrap().clone()) }
    fn subscribePeerChanges(&self) -> broadcast::Receiver<()> { self.state.changes.subscribe() }
    fn pairingPrompts(&self) -> Result<Vec<PairingPrompt>, CoreLinkError> {
        Ok(self.pendingRecords(RUNTIME_LINK_ACCESS_PENDING_PAIRINGS_PATH)?.into_values()
            .filter(|p| p.expires > currentTimeMillis()).map(|p| PairingPrompt { pairingId: p.id,
                peerNodeId: p.clientDeviceId, displayName: p.info.displayName(), confirmationCode: p.confirmationCode.unwrap_or_default() }).collect())
    }
    async fn disconnectPeer(&self, node: &str) -> Result<(), CoreLinkError> {
        let connections = self.state.connections.lock().unwrap().remove(node).unwrap_or_default();
        for raw in connections.into_iter().filter_map(|v| v.upgrade()) { raw.close().await; }
        self.state.pooledChannels.lock().unwrap().remove(node);
        self.state.liveChannels.lock().unwrap().remove(node);
        self.state.active.lock().unwrap().remove(node); self.changed(); Ok(())
    }
    async fn removePairedPeer(&self, node: &str) -> Result<(), CoreLinkError> {
        { let _guard = self.state.mutation.lock().unwrap(); self.state.store.removePairedPeer(node).map_err(error)?; self.removeSpaceChannels(node)?; }
        self.disconnectPeer(node).await
    }
}

/// Produces one addable candidate per unpaired node across all interfaces and transports.
fn discoveredPeers(records: Vec<operit_host_api::ServiceDiscovery::DiscoveredService>, localNodeId: &str,
    pairedNodeIds: &BTreeSet<String>,
) -> Vec<DiscoveredPeer> {
    let mut peers = BTreeMap::new();
    for record in records {
        let Some(node) = record.properties.get("nodeId").filter(|n| n.as_str() != localNodeId) else { continue; };
        if pairedNodeIds.contains(node) { continue; }
        let modes = record.properties.get("transports").map(String::as_str).unwrap_or("tcp");
        for mode in modes.split(',') {
            for ip in &record.addresses {
                if ip.is_unspecified() || ip.is_multicast()
                    || matches!(ip, std::net::IpAddr::V6(v6) if v6.is_unicast_link_local()) {
                    continue;
                }
                let socket = std::net::SocketAddr::new(*ip, record.port).to_string();
                let address = match mode { "http" => format!("http://{socket}/link"), "ws" => format!("ws://{socket}/link"), "tcp" => socket, _ => continue };
                let candidate = DiscoveredPeer { nodeId: node.clone(), address,
                    displayName: record.properties.get("displayName").cloned().unwrap_or_else(|| node.clone()) };
                // One device, not one row per NIC, IP family and transport.
                let rank = discoveryEndpointRank(*ip, mode);
                if peers.get(node).is_none_or(|(old, _)| rank < *old) {
                    peers.insert(node.clone(), (rank, candidate));
                }
            }
        }
    }
    peers.into_values().map(|(_, peer)| peer).collect()
}

/// Prefer LAN IPv4, then routable IPv6, with loopback only as a last resort.
fn discoveryEndpointRank(ip: std::net::IpAddr, mode: &str) -> (u8, u8, String) {
    let family = if ip.is_loopback() { 3 } else if ip.is_ipv4() { 0 } else { 1 };
    let transport = match mode { "http" => 0, "ws" => 1, _ => 2 };
    (family, transport, ip.to_string())
}

#[cfg(test)]
mod discovery_ranking_tests {
    use super::{discoveryEndpointRank, BTreeSet};
    /// Keeps different unpaired nodes distinct even when their display names match.
    #[test]
    fn groups_addresses_and_transports_by_node_not_display_name() {
        use operit_host_api::ServiceDiscovery::DiscoveredService;
        let record = |node: &str, addresses: &[&str]| DiscoveredService {
            fullName: "test".into(), hostname: "test.local.".into(), port: 37195,
            addresses: addresses.iter().map(|ip| ip.parse().unwrap()).collect(),
            properties: [("nodeId".into(), node.into()), ("displayName".into(), "Same name".into()),
                ("transports".into(), "ws,http,tcp".into())].into_iter().collect(),
        };
        let peers = super::discoveredPeers(vec![
            record("one", &["fd00::2", "fd00::3", "192.168.1.2", "fe80::1"]),
            record("one", &["192.168.1.2"]),
            record("two", &["fd00::4"]),
            record("self", &["192.168.1.9"]),
            record("invalid", &["::", "ff02::1", "fe80::2"]),
        ], "self", &BTreeSet::new());
        assert_eq!(peers.len(), 2);
        assert_eq!(peers[0].nodeId, "one");
        assert_eq!(peers[0].address, "http://192.168.1.2:37195/link");
        assert_eq!(peers[1].nodeId, "two");
        assert_eq!(peers[1].address, "http://[fd00::4]:37195/link");
    }
    /// Excludes all advertisements of paired nodes without excluding equal display names.
    #[test]
    fn excludes_paired_nodes_from_all_discovery_records() {
        use operit_host_api::ServiceDiscovery::DiscoveredService;
        let record = |node: &str, ip: &str| DiscoveredService {
            fullName: "test".into(), hostname: "test.local.".into(), port: 37195,
            addresses: vec![ip.parse().unwrap()],
            properties: [("nodeId".into(), node.into()), ("displayName".into(), "Same name".into()),
                ("transports".into(), "tcp,http,ws".into())].into_iter().collect(),
        };
        let paired = ["paired".to_string()].into_iter().collect();
        let records = vec![record("paired", "192.168.1.2"), record("paired", "fd00::2"), record("new", "192.168.1.3")];
        let peers = super::discoveredPeers(records.clone(), "self", &paired);
        assert_eq!(peers.iter().map(|peer| peer.nodeId.as_str()).collect::<Vec<_>>(), vec!["new"]);
        assert_eq!(super::discoveredPeers(records, "self", &BTreeSet::new()).len(), 2);
    }

    /// Preserves endpoint ordering for unpaired nodes.
    #[test]
    fn prefers_lan_ipv4_over_ipv6_and_loopback() {
        let rank = |ip: &str| discoveryEndpointRank(ip.parse().unwrap(), "http");
        assert!(rank("192.168.1.2") < rank("fd00::2"));
        assert!(rank("fd00::2") < rank("127.0.0.1"));
    }
}

fn isNetworkTransport(transport: PeerTransport) -> bool {
    matches!(transport, PeerTransport::Http | PeerTransport::WebSocket | PeerTransport::Tcp)
}

// PeerLink currently exposes Host bind errors as strings. Only address-in-use
// errors qualify for retry; permissions, invalid addresses and missing Hosts do not.
fn isAddressInUse(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    message.contains("address already in use") || message.contains("os error 48")
        || message.contains("os error 98") || message.contains("os error 10048")
}

async fn listenWithPortFallback(
    link: &dyn PeerLink, host: Arc<HostManager>, mut endpoint: PeerEndpoint,
    transport: PeerTransport, automatic: bool,
) -> Result<(Arc<dyn PeerListener>, String), String> {
    let mut socket = if isNetworkTransport(transport) {
        Some(endpoint.address.parse::<std::net::SocketAddr>().map_err(|_| "Listener requires an IP address and port".to_string())?)
    } else { None };
    // Port zero cannot be advertised correctly by the current PeerListener API.
    if let Some(address) = socket.as_mut() {
        if address.port() == 0 {
            if !automatic { return Err("Fixed listener port must be nonzero".into()); }
            address.set_port(37195);
            endpoint.address = address.to_string();
        }
    }
    for attempt in 0..128 {
        match link.listen(host.clone(), endpoint.clone(), transport).await {
            Ok(listener) => return Ok((listener, endpoint.address)),
            Err(e) if automatic && socket.is_some() && isAddressInUse(&e) && attempt < 127 => {
                let address = socket.as_mut().unwrap();
                address.set_port(if address.port() == u16::MAX { 49152 } else { address.port() + 1 });
                endpoint.address = address.to_string();
            }
            Err(e) => return Err(format!("Cannot listen on {}: {e}", endpoint.address)),
        }
    }
    unreachable!()
}

#[cfg(test)]
mod port_fallback_tests {
    use super::*;
    struct Listener;
    #[async_trait]
    impl PeerListener for Listener {
        async fn accept(&self) -> Result<Option<Arc<dyn PeerConnection>>, String> { Ok(None) }
        async fn close(&self) {}
    }
    struct Link {
        addresses: Mutex<Vec<String>>,
        failures: usize,
        error: &'static str,
    }
    #[async_trait]
    impl PeerLink for Link {
        async fn connect(&self, _: Arc<HostManager>, _: PeerEndpoint, _: PeerEndpoint, _: PeerTransport) -> Result<Arc<dyn PeerConnection>, String> { unreachable!() }
        async fn listen(&self, _: Arc<HostManager>, source: PeerEndpoint, _: PeerTransport) -> Result<Arc<dyn PeerListener>, String> {
            let mut addresses = self.addresses.lock().unwrap();
            addresses.push(source.address);
            if addresses.len() <= self.failures { Err(self.error.into()) } else { Ok(Arc::new(Listener)) }
        }
    }
    async fn bind(link: &Link, address: &str, automatic: bool) -> Result<(Arc<dyn PeerListener>, String), String> {
        listenWithPortFallback(link, Arc::new(HostManager::default()), PeerEndpoint { nodeId: "test".into(), address: address.into() }, PeerTransport::Http, automatic).await
    }
    #[tokio::test]
    async fn automatic_skips_multiple_occupied_ports() {
        let link = Link { addresses: Mutex::new(vec![]), failures: 2, error: "Address already in use (os error 48)" };
        assert_eq!(bind(&link, "0.0.0.0:37195", true).await.unwrap().1, "0.0.0.0:37197");
        assert_eq!(*link.addresses.lock().unwrap(), ["0.0.0.0:37195", "0.0.0.0:37196", "0.0.0.0:37197"]);
    }
    #[tokio::test]
    async fn fixed_and_non_collision_errors_do_not_retry() {
        for (automatic, error) in [(false, "Address already in use (os error 98)"), (true, "Permission denied"), (true, "HTTP server Host is not installed")] {
            let link = Link { addresses: Mutex::new(vec![]), failures: 200, error };
            assert!(bind(&link, "127.0.0.1:37195", automatic).await.is_err());
            assert_eq!(link.addresses.lock().unwrap().len(), 1);
        }
    }
    #[tokio::test]
    async fn ipv6_wraps_without_selecting_zero_and_retries_are_bounded() {
        let link = Link { addresses: Mutex::new(vec![]), failures: 1, error: "os error 10048" };
        assert_eq!(bind(&link, "[::]:65535", true).await.unwrap().1, "[::]:49152");
        let link = Link { addresses: Mutex::new(vec![]), failures: 200, error: "os error 98" };
        assert!(bind(&link, "127.0.0.1:37195", true).await.is_err());
        assert_eq!(link.addresses.lock().unwrap().len(), 128);
    }
}

#[cfg(test)]
mod online_direction_tests {
    use super::*;
    #[test]
    fn inbound_peer_is_not_offline_just_because_reverse_pairing_is_missing() {
        let missing = CoreLinkError::new("PEER_OUTBOUND_NOT_AUTHORIZED", "No current outbound authorization for node");
        assert!(!failureProvesPeerUnavailable(&missing));
        assert!(failureProvesPeerUnavailable(&error("Connection refused")));
    }
}
