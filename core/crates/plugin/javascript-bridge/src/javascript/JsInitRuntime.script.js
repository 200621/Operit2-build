(function() {
    var root = typeof globalThis !== 'undefined'
        ? globalThis
        : (typeof window !== 'undefined' ? window : this);
    var windowRef = typeof window !== 'undefined' ? window : root;

    function expose(name, value) {
        var key = name == null ? '' : String(name).trim();
        if (!key || value === undefined) {
            return;
        }
        root[key] = value;
        windowRef[key] = value;
    }

    expose('__operitExpose', expose);
    root.window = windowRef;

    /** Implements standard cancellation consistently in every plugin runtime. */
    class AbortSignal {
        /** Creates an initially active cancellation signal. */
        constructor() { this.aborted = false; this.reason = undefined; this.listeners = new Set(); }
        /** Registers a listener for the standard abort event. */
        addEventListener(type, listener) { if (type === 'abort') this.listeners.add(listener); }
        /** Removes an abort listener by identity. */
        removeEventListener(type, listener) { if (type === 'abort') this.listeners.delete(listener); }
        /** Throws the exact abort reason after cancellation. */
        throwIfAborted() { if (this.aborted) throw this.reason; }
    }
    /** Owns a standard AbortSignal independently of platform APIs. */
    class AbortController {
        /** Creates one signal for this controller. */
        constructor() { this.signal = new AbortSignal(); }
        /** Publishes cancellation once to all currently registered listeners. */
        abort(reason) {
            if (this.signal.aborted) return;
            if (reason === undefined) { reason = new Error('The operation was aborted'); reason.name = 'AbortError'; }
            this.signal.aborted = true;
            this.signal.reason = reason;
            var event = { type: 'abort', target: this.signal };
            this.signal.listeners.forEach(/** Delivers the standard abort event. */ function(listener) { listener(event); });
            this.signal.listeners.clear();
        }
    }
    expose('AbortController', AbortController);

    function ensureCallRegistry() {
        var registry = root.__operitExecutionCallRegistry;
        if (!registry || typeof registry !== 'object') {
            registry = {};
            root.__operitExecutionCallRegistry = registry;
        }
        return registry;
    }

    function normalizeCallId(callId) {
        return callId == null ? '' : String(callId).trim();
    }

    function getCallState(callId) {
        var resolvedCallId = normalizeCallId(callId);
        if (!resolvedCallId) {
            return null;
        }
        return ensureCallRegistry()[resolvedCallId] || null;
    }

    /** Returns an id only while its session still exists, so a finished call is never restored. */
    function liveCallId(callId) {
        var resolvedCallId = normalizeCallId(callId);
        return resolvedCallId && getCallState(resolvedCallId) ? resolvedCallId : '';
    }

    var callActivationSequence = 0;

    /** Advances the ordering that selects the most recently activated live call. */
    function nextCallActivation() {
        callActivationSequence += 1;
        return callActivationSequence;
    }

    /** Picks the newest call that can still own JavaScript work besides the excluded one. */
    function mostRecentLiveCallId(excludeCallId) {
        var registry = ensureCallRegistry();
        var excluded = normalizeCallId(excludeCallId);
        var selected = '';
        var selectedAt = -1;
        Object.keys(registry).forEach(function(callId) {
            var state = registry[callId];
            if (!state || state.completed || callId === excluded) return;
            var activatedAt = Number(state.activatedAt || 0);
            if (activatedAt >= selectedAt) {
                selectedAt = activatedAt;
                selected = callId;
            }
        });
        return selected;
    }

    /** Restores a live call, preferring the supplied id before the newest active call. */
    function restoreLiveCallId(preferredCallId, excludeCallId) {
        var preferred = liveCallId(preferredCallId);
        if (preferred) return preferred;
        return mostRecentLiveCallId(excludeCallId);
    }

    function registerCallSession(callId, params) {
        var resolvedCallId = normalizeCallId(callId);
        if (!resolvedCallId) {
            throw new Error('callId is required');
        }
        var registry = ensureCallRegistry();
        var state = registry[resolvedCallId];
        var callState = state && typeof state === 'object' ? state : {};
        callState.callId = resolvedCallId;
        callState.activatedAt = nextCallActivation();
        callState.params = params && typeof params === 'object' ? params : {};
        callState.completed = false;
        callState.resultCompleted = false;
        callState.detached = false;
        callState.detachedCleanup = null;
        callState.pendingReferences = 0;
        callState.safetyTimeout = null;
        callState.safetyTimeoutFinal = null;
        callState.lastExecStage = '';
        callState.lastExecFunction = '';
        callState.lastModulePath = '';
        callState.lastRequireRequest = '';
        callState.lastRequireFrom = '';
        callState.lastRequireResolved = '';
        callState.currentModule = null;
        callState.currentModuleExports = null;
        callState.timerIds = {};
        callState.previousCallId = '';
        callState.previousCallRuntime = null;
        registry[resolvedCallId] = callState;
        return callState;
    }

    function registerCallTimer(callId, timerId) {
        var callState = getCallState(callId);
        if (!callState) {
            return;
        }
        if (!callState.timerIds || typeof callState.timerIds !== 'object') {
            callState.timerIds = {};
        }
        callState.timerIds[String(timerId)] = true;
        callState.pendingReferences += 1;
    }

    function unregisterCallTimer(callId, timerId) {
        var callState = getCallState(callId);
        if (!callState || !callState.timerIds || typeof callState.timerIds !== 'object') {
            return;
        }
        var key = String(timerId);
        if (!callState.timerIds[key]) return;
        delete callState.timerIds[key];
        releaseCallReference(callId);
    }

    function retainCallReference(callId) {
        var callState = getCallState(callId);
        if (callState) callState.pendingReferences = Number(callState.pendingReferences || 0) + 1;
    }

    function releaseCallReference(callId) {
        var callState = getCallState(callId);
        if (!callState) return;
        callState.pendingReferences = Math.max(0, Number(callState.pendingReferences || 0) - 1);
    }

    /** Finalizes one detached call after its queued JavaScript jobs are delivered. */
    function finalizeDetachedCall(callId) {
        var callState = getCallState(callId);
        if (!callState || !callState.detached || Number(callState.pendingReferences || 0) > 0) {
            return false;
        }
        if (typeof callState.detachedCleanup === 'function') {
            try {
                callState.detachedCleanup();
            } catch (_cleanupError) {
            }
            callState.detachedCleanup = null;
        }
        cleanupCallSession(callId);
        return true;
    }

    /** Reports only the explicit detached flag instead of exposing the whole call object to Rust. */
    function isCallDetached(callId) {
        var state = getCallState(callId);
        return Boolean(state && state.detached === true);
    }

    /** Returns the structured registration capture required by the runtime lifecycle contract. */
    function readRegistrationCapture() {
        return root.__operitToolPkgRegistrationCapture;
    }

    function detachedCallIds() {
        var registry = ensureCallRegistry();
        var result = [];
        Object.keys(registry).forEach(function(callId) {
            var state = registry[callId];
            if (state && state.detached && Number(state.pendingReferences || 0) > 0) result.push(callId);
        });
        return result;
    }

    function activateCall(callId) {
        var state = getCallState(callId);
        if (!state || state.completed) return false;
        state.activatedAt = nextCallActivation();
        root.__operitCurrentCallId = callId;
        root.__operit_call_runtime_ref = state.callRuntime;
        return true;
    }

    // Explicit Promise continuations (including lowered async functions) belong to
    // their subscribing call, not to the call which happens to resolve a shared Promise.
    var originalThen = Promise.prototype.then;
    /** Captures subscription ownership even after that call's session was cancelled. */
    Promise.prototype.then = function(onFulfilled, onRejected) {
        var ownerCallId = normalizeCallId(root.__operitCurrentCallId);
        if (!ownerCallId) {
            return originalThen.call(this, onFulfilled, onRejected);
        }
        /** Runs each continuation under its subscribing call's exact identity. */
        function bindContinuation(handler) {
            if (typeof handler !== 'function') return handler;
            /** Isolates cancelled callbacks from the surrounding live runtime. */
            return function(value) {
                var ownerState = getCallState(ownerCallId);
                var previousCallId = normalizeCallId(root.__operitCurrentCallId);
                var previousRuntime = root.__operit_call_runtime_ref;
                if (!ownerState) {
                    root.__operitCurrentCallId = ownerCallId;
                    delete root.__operit_call_runtime_ref;
                    try { return handler(value); }
                    finally {
                        if (normalizeCallId(root.__operitCurrentCallId) === ownerCallId) {
                            root.__operitCurrentCallId = liveCallId(previousCallId);
                            if (root.__operitCurrentCallId && previousRuntime && typeof previousRuntime === 'object') {
                                root.__operit_call_runtime_ref = previousRuntime;
                            } else {
                                delete root.__operit_call_runtime_ref;
                            }
                        }
                    }
                }
                ownerState.activatedAt = nextCallActivation();
                root.__operitCurrentCallId = ownerCallId;
                root.__operit_call_runtime_ref = ownerState.callRuntime;
                try { return handler(value); }
                finally {
                    // Completing the owning call already restored the surviving context.
                    // Writing the captured value back would resurrect a cleaned call id and
                    // leave an unrelated suspended call pointing at a deleted session.
                    if (normalizeCallId(root.__operitCurrentCallId) === ownerCallId) {
                        root.__operitCurrentCallId = restoreLiveCallId(previousCallId, ownerCallId);
                        if (previousRuntime && typeof previousRuntime === 'object') {
                            root.__operit_call_runtime_ref = previousRuntime;
                        } else if (root.__operit_call_runtime_ref === ownerState.callRuntime) {
                            delete root.__operit_call_runtime_ref;
                        }
                    }
                }
            };
        }
        return originalThen.call(this, bindContinuation(onFulfilled), bindContinuation(onRejected));
    };

    /** Activates one detached call before its queued JavaScript jobs are resumed. */
    function prepareDetachedCall(callId) {
        var state = getCallState(callId);
        if (!state || state.completed || !state.detached || Number(state.pendingReferences || 0) <= 0) {
            return false;
        }
        return activateCall(callId);
    }

    /** Cancels every timer owned by the session through the host Promise bridge. */
    function clearCallTimers(callState) {
        if (!callState || !callState.timerIds || typeof callState.timerIds !== 'object') {
            return;
        }
        var timerIds = Object.keys(callState.timerIds);
        for (var index = 0; index < timerIds.length; index += 1) {
            root.clearTimeout(timerIds[index]);
        }
        callState.timerIds = {};
    }

    function cleanupCallSession(callId) {
        var resolvedCallId = normalizeCallId(callId);
        if (!resolvedCallId) {
            return;
        }
        var registry = ensureCallRegistry();
        clearCallTimers(registry[resolvedCallId]);
        delete registry[resolvedCallId];
    }

    function cancelCallSession(callId) {
        var resolvedCallId = normalizeCallId(callId);
        if (!resolvedCallId) {
            return;
        }
        var callState = getCallState(resolvedCallId);
        if (!callState) {
            return;
        }
        callState.completed = true;
        if (root.__operitCurrentCallId === resolvedCallId) {
            root.__operitCurrentCallId = restoreLiveCallId(callState.previousCallId, resolvedCallId);
        }
        if (root.__operit_call_runtime_ref === callState.callRuntime) {
            if (callState.previousCallRuntime && typeof callState.previousCallRuntime === 'object') {
                root.__operit_call_runtime_ref = callState.previousCallRuntime;
            } else {
                delete root.__operit_call_runtime_ref;
            }
        }
        cleanupCallSession(resolvedCallId);
    }

    function buildRuntimeContext(callId) {
        var callState = getCallState(callId);
        var mapping = [
            ['lastExecStage', 'stage'],
            ['lastExecFunction', 'function'],
            ['lastModulePath', 'module'],
            ['lastRequireRequest', 'require'],
            ['lastRequireFrom', 'from'],
            ['lastRequireResolved', 'resolved']
        ];
        var parts = [];
        for (var i = 0; i < mapping.length; i += 1) {
            var key = mapping[i][0];
            var label = mapping[i][1];
            var value = callState ? callState[key] : undefined;
            if (value != null && String(value).trim().length > 0) {
                parts.push(label + '=' + String(value));
            }
        }
        return parts.join(', ');
    }

    expose('__operitGetCallState', getCallState);
    expose('__operitRegisterCallSession', registerCallSession);
    expose('__operitRegisterCallTimer', registerCallTimer);
    expose('__operitUnregisterCallTimer', unregisterCallTimer);
    expose('__operitRetainCallReference', retainCallReference);
    expose('__operitReleaseCallReference', releaseCallReference);
    expose('__operitGetDetachedCallIds', detachedCallIds);
    expose('__operitIsCallDetached', isCallDetached);
    expose('__operitReadRegistrationCapture', readRegistrationCapture);
    expose('__operitActivateCall', activateCall);
    expose('__operitPrepareDetachedCall', prepareDetachedCall);
    expose('__operitFinalizeDetachedCall', finalizeDetachedCall);
    /** Forwards the detached-call notification through its mandatory structured host binding. */
    expose('__operitNotifyDetachedCall', function(callId) {
        root.__operitNativeNotifyDetachedCall(normalizeCallId(callId));
    });
    expose('__operitCleanupCallSession', cleanupCallSession);
    expose('__operitCancelCallSession', cancelCallSession);
    expose('__operitRestoreLiveCallId', restoreLiveCallId);
    expose('__operitBuildRuntimeContext', buildRuntimeContext);

    expose('__operitGetActiveModuleExports', function() {
        if (
            root.__operitActiveModule &&
            typeof root.__operitActiveModule === 'object' &&
            root.__operitActiveModule.exports
        ) {
            return root.__operitActiveModule.exports;
        }
        var exportsRef = root.__operitActiveModuleExports;
        return exportsRef && typeof exportsRef === 'object' ? exportsRef : exportsRef || null;
    });
})();
