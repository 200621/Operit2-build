/**
 * Installs the existing v1 dispatch family over the conditional runtime script package.
 * @param {Record<string, any>} runtime
 */
function __operitInstallV1Runtime(runtime) {
    var api = runtime.__operitToolPkgApi;
    var canonical = runtime.__operitCanonicalTools;
    var originalToolCall = runtime.toolCall;
    var routes = Object.freeze({
        'super_admin:terminal': 'v1_runtime:terminal',
        'code_runner:run_javascript_node': 'v1_runtime:run_javascript_node',
        'ffmpeg:ffmpeg_execute': 'v1_runtime:ffmpeg_execute',
        'ffmpeg:ffmpeg_info': 'v1_runtime:ffmpeg_info',
    });

    /** Decodes the script-package executor's JSON text without hiding provider failures.
     * @param {unknown} value
     * @returns {any}
     */
    function decoded(value) {
        if (typeof value !== 'string') throw new TypeError('V1 runtime package must return serialized JSON');
        return JSON.parse(value);
    }

    /** Calls one exact runtime tool through the original structured host transport.
     * @param {string} method
     * @param {Record<string, any>} params
     * @returns {Promise<any>}
     */
    function invoke(method, params) {
        return originalToolCall('v1_runtime:' + method, params).then(decoded);
    }

    /** Rewrites only admitted legacy package identities while preserving every public overload.
     * @param {...any} args
     * @returns {Promise<any>}
     */
    function legacyToolCall(...args) {
        var rewritten = args.slice();
        var name;
        var type = 'default';
        var index = 0;
        if (args[0] !== null && typeof args[0] === 'object') {
            name = args[0].name;
            type = args[0].type === undefined ? 'default' : args[0].type;
        } else {
            if (typeof args[1] === 'string') { type = args[0]; index = 1; }
            name = args[index];
        }
        if (type === 'default' && Object.prototype.hasOwnProperty.call(routes, name)) {
            var target = routes[/** @type {keyof typeof routes} */ (name)];
            if (args[0] !== null && typeof args[0] === 'object') rewritten[0] = Object.assign({}, args[0], { name: target });
            else rewritten[index] = target;
            return originalToolCall.apply(runtime, rewritten).then(decoded);
        }
        return originalToolCall.apply(runtime, args);
    }
    runtime.__operitExpose('toolCall', api.method()
        .between('1.0.0', '2.0.0', legacyToolCall)
        .since('2.0.0', originalToolCall)
        .build('toolCall'));

    var terminal = canonical.System.terminal;
    var currentTerminal = runtime.Tools.System.terminal;
    currentTerminal.create = api.method()
        .between('1.0.0', '2.0.0',
            /** Creates a legacy session using the package state selected by Rust.
             * @param {string} sessionName
             */
            function(sessionName) { return invoke('create_session', { sessionName: sessionName }); })
        .since('2.0.0', terminal.create).build('Tools.System.terminal.create');
    currentTerminal.exec = api.method()
        .between('1.0.0', '2.0.0',
            /** Executes in the exact compatibility session without selecting another interpreter.
             * @param {string} sessionId
             * @param {string} command
             * @param {number | string} [timeoutMs]
             */
            function(sessionId, command, timeoutMs) {
                var params = { sessionId: sessionId, command: command };
                if (timeoutMs !== undefined) /** @type {Record<string, any>} */ (params).timeoutMs = timeoutMs;
                return invoke('execute', params);
            })
        .since('2.0.0', terminal.exec).build('Tools.System.terminal.exec');

    /** Identifies the explicit legacy Linux VFS namespace by complete path segments.
     * @param {unknown} path
     * @returns {path is string}
     */
    function isLinux(path) { return typeof path === 'string' && (path === '/mnt/linux' || path.startsWith('/mnt/linux/')); }

    /** Converts one explicit Linux VFS address into the selected runtime's absolute path.
     * @param {string} path
     */
    function linuxPath(path) {
        if (!isLinux(path)) throw new Error('V1 runtime file operation requires a Linux VFS address');
        var suffix = path.slice('/mnt/linux'.length);
        return suffix === '' ? '/' : suffix;
    }

    /** Runs one file operation and restores its canonical VFS result path for the existing Files adapter.
     * @param {string} operation
     * @param {Record<string, any>} args
     * @returns {Promise<any>}
     */
    async function file(operation, args) {
        var value = await invoke('file', { operation: operation, args: args });
        value.path = '/mnt/linux' + (value.path === '/' ? '' : value.path);
        return value;
    }
    var files = Object.assign({}, canonical.Files);
    for (var method of ['read', 'readBinary', 'write', 'writeBinary', 'exists', 'mkdir', 'deleteFile', 'move', 'copy', 'unzip']) {
        /** Installs a single known filesystem operation without mutating the canonical namespace.
         * @param {string} name
         */
        (function(name) {
            /** Routes the explicit Linux namespace to its actual managed runtime filesystem.
             * @param {...any} args
             */
            files[name] = async function(...args) {
                var path = name === 'read' && typeof args[0] === 'object' && args[0] !== null ? args[0].path : args[0];
                var sourceLinux = isLinux(path);
                var hasDestination = name === 'move' || name === 'copy' || name === 'unzip';
                var destinationLinux = hasDestination && isLinux(args[1]);
                if (!sourceLinux && !destinationLinux) return canonical.Files[name].apply(canonical.Files, args);
                if (name === 'copy' && sourceLinux !== destinationLinux) {
                    if (args[2] === true) throw new Error('V1 cross-environment directory copy requires an explicit archive');
                    var data = sourceLinux ? await file('readBinary', { path: linuxPath(path) }) : await canonical.Files.readBinary(path);
                    var copied = destinationLinux
                        ? await file('writeBinary', { path: linuxPath(args[1]), contentBase64: data.contentBase64 })
                        : await canonical.Files.writeBinary(args[1], data.contentBase64);
                    return Object.assign({}, copied, { operation: 'copy', path: path });
                }
                if (hasDestination && (!sourceLinux || !destinationLinux)) throw new Error('V1 ' + name + ' requires both paths in the same runtime filesystem');
                var params = { path: linuxPath(path) };
                switch (name) {
                    case 'read':
                        if (typeof args[0] === 'object' && Object.keys(args[0]).some(
                            /** Identifies actual read options without inspecting text contents. */
                            function(key) { return key !== 'path'; })) throw new Error('V1 runtime read supports text paths; semantic and image reads require their host API');
                        break;
                    case 'write': Object.assign(params, { content: args[1], append: args[2] === true }); break;
                    case 'writeBinary': Object.assign(params, { contentBase64: args[1] }); break;
                    case 'mkdir': Object.assign(params, { createParents: args[1] === true }); break;
                    case 'deleteFile': Object.assign(params, { recursive: args[1] === true }); break;
                    case 'move': case 'copy': case 'unzip': Object.assign(params, { destination: linuxPath(args[1]), recursive: args[2] === true }); break;
                }
                return file(name, params);
            };
        })(method);
    }
    var legacyFiles = __operitCreateV1Files(files);
    for (var name of Object.keys(legacyFiles)) {
        runtime.Tools.Files[name] = api.method()
            .between('1.0.0', '2.0.0', legacyFiles[/** @type {keyof typeof legacyFiles} */ (name)])
            .since('2.0.0', canonical.Files[/** @type {keyof typeof canonical.Files} */ (name)])
            .build('Tools.Files.' + name);
    }
    runtime.Tools.Files.makeDirectory = api.method()
        .between('1.0.0', '2.0.0', legacyFiles.mkdir)
        .build('Tools.Files.makeDirectory');
}
