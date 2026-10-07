"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.registerToolPkg = registerToolPkg;
exports.onClock = onClock;
exports.onOpen = onOpen;
exports.onResume = onResume;
const reminders_1 = require("./reminders");
// Tools, clock events and lifecycle events share this main-runtime storage owner.
ToolPkg.ipc.on("daily_life.reminders", reminders_1.receiveReminder);
/** Registers reminder scheduling through existing platform-neutral Host capabilities. */
function registerToolPkg() {
    ToolPkg.registerHostEventHook({
        id: "daily_life_reminder_clock", source: "interval",
        trigger: { kind: "interval", intervalMs: 60000 }, function: onClock,
    });
    ToolPkg.registerAppLifecycleHook({
        id: "daily_life_reminder_start", event: "application_on_create", function: onOpen,
    });
    ToolPkg.registerHostEventHook({
        id: "daily_life_reminder_resume", source: "broadcast",
        trigger: { kind: "broadcast", topic: "app.lifecycle.resumed" }, function: onResume,
    });
    return true;
}
/** Delivers due reminders when the Host emits the registered minute clock. */
async function onClock() {
    await (0, reminders_1.deliverReminders)();
}
/** Checks persisted overdue reminders after the application starts. */
async function onOpen() {
    await (0, reminders_1.deliverReminders)();
}
/** Checks persisted overdue reminders when the application resumes. */
async function onResume() {
    await (0, reminders_1.deliverReminders)();
}
