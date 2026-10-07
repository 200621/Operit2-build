"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.parseDueDate = parseDueDate;
exports.receiveReminder = receiveReminder;
exports.deliverReminders = deliverReminders;
let database = null;
let ownerQueue = Promise.resolve();
let persistenceFailure = null;
/** Requires non-empty reminder input without rewriting its content. */
function requireText(value, field) {
    if (typeof value !== "string" || value.trim() === "") {
        throw new Error(`${field} must be a non-empty string`);
    }
    return value;
}
/** Parses an explicit ISO 8601 instant and rejects normalized invalid calendar dates. */
function parseDueDate(value) {
    requireText(value, "due_date");
    const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?(Z|[+-]\d{2}:\d{2})$/.exec(value);
    if (match === null)
        throw new Error("due_date must be an ISO 8601 date-time with Z or an explicit UTC offset");
    const year = Number(match[1]);
    const month = Number(match[2]);
    const day = Number(match[3]);
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (month < 1 || month > 12 || day < 1 || day > days[month - 1] ||
        Number(match[4]) > 23 || Number(match[5]) > 59 ||
        (match[6] !== undefined && Number(match[6]) > 59)) {
        throw new Error("due_date contains an invalid calendar date or time");
    }
    const offset = match[8];
    if (offset !== "Z" && (Number(offset.slice(1, 3)) > 23 || Number(offset.slice(4, 6)) > 59)) {
        throw new Error("due_date contains an invalid UTC offset");
    }
    const timestamp = Date.parse(value);
    if (!Number.isSafeInteger(timestamp))
        throw new Error("due_date is not a supported instant");
    return timestamp;
}
/** Validates persistent records rather than silently replacing corrupt plugin storage. */
function validateDatabase(db) {
    if (db.version !== 1 || !Array.isArray(db.reminders))
        throw new Error("Invalid daily_life reminder database");
    const ids = new Set();
    for (const reminder of db.reminders) {
        if (reminder === null || typeof reminder !== "object")
            throw new Error("Invalid reminder record");
        requireText(reminder.id, "reminder.id");
        requireText(reminder.title, "reminder.title");
        requireText(reminder.description, "reminder.description");
        if (parseDueDate(reminder.due_date) !== reminder.due_timestamp ||
            !Number.isFinite(Date.parse(reminder.created_at)) || ids.has(reminder.id) ||
            !["pending", "delivering", "delivered", "cancelled", "failed"].includes(reminder.status) ||
            (reminder.delivered_at !== null && !Number.isFinite(Date.parse(reminder.delivered_at))) ||
            (reminder.error !== null && typeof reminder.error !== "string")) {
            throw new Error(`Invalid stored reminder: ${reminder.id}`);
        }
        ids.add(reminder.id);
    }
}
/** Opens plugin-owned storage and records interrupted deliveries as explicit unknown outcomes. */
async function initialize() {
    const db = await PluginConfig.use("reminders", { version: 1, reminders: [] });
    validateDatabase(db);
    const interrupted = db.reminders.some(reminder => reminder.status === "delivering");
    if (interrupted) {
        db.reminders = db.reminders.map(reminder => reminder.status === "delivering" ? {
            ...reminder, status: "failed",
            error: "Notification delivery was interrupted; its outcome is unknown. It has not been resent.",
        } : reminder);
        await persist(db);
    }
    return db;
}
/** Shares the one storage owner across tool calls and Host event callbacks. */
function load() {
    if (persistenceFailure !== null)
        return Promise.reject(persistenceFailure);
    if (database === null)
        database = initialize();
    return database;
}
/** Stops this owner after a storage failure instead of delivering uncommitted reminders. */
async function persist(db) {
    try {
        await PluginConfig.flush(db);
    }
    catch (error) {
        persistenceFailure = new Error(`Reminder storage failed; this runtime has stopped delivery: ${String(error)}`);
        throw persistenceFailure;
    }
}
/** Releases queue ownership without changing the original caller's success or failure. */
function releaseOwnerQueue() { }
/** Serializes tool mutations and scheduled delivery without retrying failed operations. */
function owned(operation) {
    const result = ownerQueue.then(operation);
    ownerQueue = result.then(releaseOwnerQueue, releaseOwnerQueue);
    return result;
}
/** Returns a detached reminder record so callers cannot mutate plugin storage. */
function copy(reminder) {
    return { ...reminder };
}
/** Commits one exact reminder update before reporting success. */
async function update(db, reminder) {
    db.reminders = db.reminders.map(item => item.id === reminder.id ? reminder : item);
    await persist(db);
}
/** Executes validated reminder operations inside the main-runtime owner. */
async function dispatch(request) {
    const db = await load();
    switch (request.action) {
        case "create": {
            const title = requireText(request.title, "title");
            const description = requireText(request.description, "description");
            const dueTimestamp = parseDueDate(request.due_date);
            const now = Date.now();
            if (dueTimestamp <= now)
                throw new Error("due_date must be in the future");
            const reminder = {
                id: `reminder-${now}-${Math.random().toString(36).slice(2, 12)}`,
                title, description, due_date: new Date(dueTimestamp).toISOString(),
                due_timestamp: dueTimestamp, created_at: new Date(now).toISOString(),
                status: "pending", delivered_at: null, error: null,
            };
            if (db.reminders.some(item => item.id === reminder.id))
                throw new Error("Reminder ID collision");
            db.reminders = [...db.reminders, reminder];
            await persist(db);
            return copy(reminder);
        }
        case "list":
            return db.reminders.map(copy).sort((left, right) => left.due_timestamp - right.due_timestamp);
        case "cancel": {
            const id = requireText(request.id, "id");
            const reminder = db.reminders.find(item => item.id === id);
            if (reminder === undefined)
                throw new Error(`Reminder not found: ${id}`);
            if (reminder.status !== "pending")
                throw new Error(`Cannot cancel reminder in ${reminder.status} state: ${id}`);
            const cancelled = { ...reminder, status: "cancelled" };
            await update(db, cancelled);
            return copy(cancelled);
        }
        default:
            throw new Error("Unknown daily_life reminder operation");
    }
}
/** Routes reminder IPC through the same serialized owner used by delivery. */
function receiveReminder(request) {
    return owned(() => dispatch(request));
}
/** Claims due reminders durably and records the actual notification outcome once. */
async function deliver() {
    const db = await load();
    const due = db.reminders.filter(reminder => reminder.status === "pending" && reminder.due_timestamp <= Date.now());
    const failures = [];
    for (const reminder of due) {
        const delivering = { ...reminder, status: "delivering" };
        await update(db, delivering);
        try {
            await Tools.System.sendNotification(reminder.description, reminder.title);
        }
        catch (error) {
            const message = String(error);
            await update(db, { ...delivering, status: "failed", error: message });
            failures.push(`${reminder.id}: ${message}`);
            continue;
        }
        await update(db, { ...delivering, status: "delivered", delivered_at: new Date().toISOString() });
    }
    if (failures.length > 0)
        throw new Error(`Reminder delivery failed: ${failures.join("; ")}`);
}
/** Processes persisted due reminders when the existing Host emits a lifecycle or clock event. */
function deliverReminders() {
    return owned(deliver);
}
