#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(scriptDirectory);
const packageDirectory = path.join(
  root,
  "integration/dsh-home-template/profiles/web/node_modules/@tengqi/dsh-native-attachments"
);
const clientPath = path.join(packageDirectory, "lib/client.js");
const manifestPath = path.join(packageDirectory, "package.json");
const patchPath = path.join(root, "integration/cordis.macos-computer-use.patch.yml");

const source = fs.readFileSync(clientPath, "utf8");
let moduleDefinition;
const listeners = new Map();
const dispatchedEvents = [];
class FakeCustomEvent {
  constructor(type, init = {}) {
    this.type = type;
    this.detail = init.detail;
  }
}
const fakeWindow = {
  CustomEvent: FakeCustomEvent,
  __deepSeekHarnessNativeAttachmentQueue: [],
  __ModuleLoader__: {
    load(definition) {
      moduleDefinition = definition;
    }
  },
  addEventListener(name, listener) {
    let bucket = listeners.get(name);
    if (bucket === undefined) {
      bucket = new Set();
      listeners.set(name, bucket);
    }
    bucket.add(listener);
  },
  removeEventListener(name, listener) {
    listeners.get(name)?.delete(listener);
  },
  dispatchEvent(event) {
    dispatchedEvents.push(event);
    for (const listener of listeners.get(event.type) ?? []) listener(event);
    return true;
  },
  dispatch(name, detail) {
    for (const listener of listeners.get(name) ?? []) listener({ type: name, detail });
  },
  setTimeout: globalThis.setTimeout.bind(globalThis),
  clearTimeout: globalThis.clearTimeout.bind(globalThis)
};

Function("window", source)(fakeWindow);
assert.equal(moduleDefinition?.id, "@tengqi/dsh-native-attachments");

const fakeReact = {
  createElement(type, props, ...children) {
    return { type, props: { ...(props ?? {}), children } };
  },
  useEffect(effect) {
    effect();
  },
  useSyncExternalStore(_subscribe, getSnapshot) {
    return getSnapshot();
  }
};
const plugin = moduleDefinition.factory((specifier) => {
  if (specifier === "react") return fakeReact;
  throw new Error(`unexpected client require: ${specifier}`);
});

const uuid1 = "11111111-1111-4111-8111-111111111111";
const uuid2 = "22222222-2222-4222-8222-222222222222";
const uuid3 = "33333333-3333-4333-8333-333333333333";
const path1 = `Inbox/${uuid1}/paper.pdf`;
const path2 = `Inbox/${uuid2}/notes.md`;
const path3 = `Inbox/${uuid3}/table.xlsx`;

function attachment(relativePath, overrides = {}) {
  return {
    id: relativePath,
    displayName: relativePath.split("/").at(-1),
    kind: "文档",
    relativePath,
    byteCount: 1234,
    sizeDescription: "1 KB",
    ...overrides
  };
}

function payload(revision, attachments, overrides = {}) {
  return { version: 1, revision, sessionId: "session-1", attachments, ...overrides };
}

assert.equal(plugin.validatePayload(payload(1, [attachment(path1)])).ok, true);
assert.equal(plugin.validatePayload(payload(1, [attachment(path1)], { extra: true })).ok, false);
const symbolExtendedPayload = payload(1, [attachment(path1)]);
symbolExtendedPayload[Symbol("extra")] = true;
assert.equal(plugin.validatePayload(symbolExtendedPayload).ok, false);
assert.equal(plugin.validatePayload(payload(0, [attachment(path1)])).ok, false);
assert.equal(plugin.validatePayload(payload(1, [attachment(path1)], { sessionId: "" })).ok, false);
assert.equal(plugin.validatePayload(payload(1, [attachment(path1)], { sessionId: "bad\u007f-id" })).ok, false);
assert.equal(plugin.validatePayload(payload(1, [attachment("../outside")])).ok, false);
const controlPath = `Inbox/${uuid1}/bad\u0001name.txt`;
assert.equal(plugin.validatePayload(payload(1, [attachment(controlPath)])).ok, false);
assert.equal(plugin.validatePayload(payload(1, [attachment(path1), attachment(path1)])).ok, false);
assert.equal(
  plugin.validatePayload(payload(1, [attachment(path1, { byteCount: 512 * 1024 * 1024 + 1 })])).ok,
  false
);
assert.equal(plugin.validateQueueRow({ payload: payload(1, [attachment(path1)]), replay: false }).replay, false);
assert.equal(plugin.validateQueueRow(payload(1, [attachment(path1)])), undefined);
assert.equal(
  plugin.validateQueueRow({ payload: payload(1, [attachment(path1)]), replay: false, extra: true }),
  undefined
);
let adversarialGetterCalls = 0;
const accessorAttachment = attachment(path1);
Object.defineProperty(accessorAttachment, "relativePath", {
  configurable: true,
  enumerable: true,
  get() {
    adversarialGetterCalls += 1;
    return path1;
  }
});
assert.equal(plugin.validatePayload(payload(1, [accessorAttachment])).ok, false);
const accessorPayload = payload(1, [attachment(path1)]);
Object.defineProperty(accessorPayload, "sessionId", {
  configurable: true,
  enumerable: true,
  get() {
    adversarialGetterCalls += 1;
    return "session-1";
  }
});
assert.equal(plugin.validatePayload(accessorPayload).ok, false);
const accessorAttachments = [attachment(path1)];
Object.defineProperty(accessorAttachments, "0", {
  configurable: true,
  enumerable: true,
  get() {
    adversarialGetterCalls += 1;
    return attachment(path1);
  }
});
assert.equal(plugin.validatePayload(payload(1, accessorAttachments)).ok, false);
const accessorQueueRow = { replay: false };
Object.defineProperty(accessorQueueRow, "payload", {
  configurable: true,
  enumerable: true,
  get() {
    adversarialGetterCalls += 1;
    return payload(1, [attachment(path1)]);
  }
});
assert.equal(plugin.validateQueueRow(accessorQueueRow), undefined);
assert.equal(adversarialGetterCalls, 0, "native-boundary accessors must never execute");
assert.deepEqual(
  plugin.modelRouteFromState("session-1", {
    status: "ready",
    routable: true,
    current: { provider: "deepseek", model: "deepseek-v4" }
  }),
  { version: 1, sessionId: "session-1", provider: "deepseek", model: "deepseek-v4" }
);
assert.equal(
  plugin.modelRouteFromState("session-1", {
    status: "loading",
    routable: true,
    current: { provider: "deepseek", model: "deepseek-v4" }
  }),
  null
);
assert.equal(
  plugin.modelRouteFromState("session-1", {
    status: "ready",
    routable: false,
    current: { provider: "deepseek", model: "deepseek-v4" }
  }),
  null
);

const reattachStore = plugin.createAttachmentStore();
const reattachSession = "reattach-session";
const parsedRevision1 = plugin.validatePayload(payload(1, [attachment(path1)])).value;
const parsedRevision2 = plugin.validatePayload(payload(2, [attachment(path1)])).value;
const parsedRevision3 = plugin.validatePayload(payload(3, [attachment(path1)])).value;
const initialAttachPlan = reattachStore.plan(reattachSession, parsedRevision1, "原始草稿");
reattachStore.commit(initialAttachPlan);
const duplicateAttachPlan = reattachStore.plan(
  reattachSession,
  parsedRevision2,
  initialAttachPlan.nextDraft
);
assert.equal(duplicateAttachPlan.additions.length, 0, "an active attachment id must remain deduplicated");
reattachStore.commit(duplicateAttachPlan);
reattachStore.reconcile(reattachSession, "原始草稿");
const reattachPlan = reattachStore.plan(reattachSession, parsedRevision3, "原始草稿");
assert.equal(reattachPlan.additions.length, 1, "a removed attachment id must be attachable again");
assert.match(reattachPlan.nextDraft, /paper\.pdf/u);

const falseReplayStore = plugin.createAttachmentStore();
const alreadyPresentDraft = `刷新草稿\n${plugin.managedReferenceLine(path1, 1)}`;
const falseReplayPlan = falseReplayStore.plan(reattachSession, parsedRevision1, alreadyPresentDraft);
assert.equal(falseReplayPlan.additions.length, 1, "an existing line must restore its card state");
assert.equal(falseReplayPlan.nextDraft, alreadyPresentDraft, "replay=false must not duplicate an exact line");
falseReplayStore.commit(falseReplayPlan);
assert.equal(
  falseReplayStore.plan(reattachSession, parsedRevision1, alreadyPresentDraft).kind,
  "ignored",
  "an exact processed revision must remain idempotent"
);

const outOfOrderStore = plugin.createAttachmentStore();
const highRevision = plugin.validatePayload(payload(6, [attachment(path2)])).value;
const lowRevision = plugin.validatePayload(payload(5, [attachment(path1)])).value;
outOfOrderStore.commit(outOfOrderStore.plan("session-B", highRevision, "B"));
const lateLowPlan = outOfOrderStore.plan("session-A", lowRevision, "A");
assert.equal(lateLowPlan.kind, "accepted", "a later commit must not suppress an exact lower revision");
assert.equal(lateLowPlan.additions.length, 1);
outOfOrderStore.commit(lateLowPlan);
assert.equal(
  outOfOrderStore.plan("session-B", highRevision, "B").kind,
  "ignored",
  "the exact higher revision must still deduplicate"
);

const duplicateIdentityStore = plugin.createAttachmentStore();
const duplicatePath = `Inbox/${uuid3}/shared-name.txt`;
const duplicateA = plugin.validatePayload(payload(61, [attachment(duplicatePath)])).value;
const duplicateB = plugin.validatePayload(payload(62, [attachment(duplicatePath)], {
  sessionId: "session-2"
})).value;
duplicateIdentityStore.commit(duplicateIdentityStore.plan("session-1", duplicateA, "A"));
duplicateIdentityStore.commit(duplicateIdentityStore.plan("session-2", duplicateB, "B"));
assert.equal(duplicateIdentityStore.snapshotAll().length, 2, "same id across sessions must remain distinct");
assert.equal(
  duplicateIdentityStore.entryExact("session-1", 61, duplicatePath)?.sessionId,
  "session-1"
);
assert.equal(
  duplicateIdentityStore.entryExact("session-2", 62, duplicatePath)?.sessionId,
  "session-2"
);
duplicateIdentityStore.reconcile("session-1", "A");
assert.equal(
  duplicateIdentityStore.entryExact("session-2", 62, duplicatePath)?.sessionId,
  "session-2",
  "reconciling session-1 must not remove the same id from session-2"
);

const userDraft = "用户原文\n第二行";
let draft = userDraft;
let draftB = "B 会话原文";
let acceptDraftWrites = true;
let setDraftCalls = 0;
const inputFacade = {
  state: { getSnapshot: () => ({ draft }) },
  setDraft(nextDraft) {
    setDraftCalls += 1;
    if (acceptDraftWrites) draft = nextDraft;
  }
};
const actx = { session: "session-1" };
const actxB = { session: "session-2" };
const inputFacadeB = {
  state: { getSnapshot: () => ({ draft: draftB }) },
  setDraft(nextDraft) {
    draftB = nextDraft;
  }
};
const effects = [];
const sessionListListeners = new Set();
function createModelStore(initialState) {
  let state = initialState;
  const subscribers = new Set();
  return {
    getSnapshot: () => state,
    subscribe(listener) {
      subscribers.add(listener);
      return () => subscribers.delete(listener);
    },
    set(nextState) {
      state = nextState;
      for (const listener of subscribers) listener();
    },
    listenerCount: () => subscribers.size
  };
}
const modelStoreA = createModelStore({
  status: "ready",
  routable: true,
  current: { provider: "deepseek", model: "deepseek-v4" }
});
const modelStoreB = createModelStore({
  status: "ready",
  routable: true,
  current: { provider: "moonshot", model: "kimi-k2" }
});
let registered;
let warningCount = 0;
let currentSessionId = "session-1";
let directShellCalls = 0;
const previousResolver = () => "previous-session";
fakeWindow.__deepSeekHarnessResolveNativeAttachmentSession = previousResolver;
const ctx = {
  conversation: {
    input: {
      for: (candidate) => candidate === actx
        ? inputFacade
        : candidate === actxB
          ? inputFacadeB
          : undefined,
      shell(sessionId) {
        directShellCalls += 1;
        if (sessionId === "session-1") return inputFacade;
        if (sessionId === "session-2") return inputFacadeB;
        throw new Error("unknown input shell");
      }
    }
  },
  effect(setup) {
    const cleanup = setup();
    if (typeof cleanup === "function") effects.push(cleanup);
  },
  logger: { warn() { warningCount += 1; } },
  modelDirectories: {
    directoryFor(sessionId) {
      if (sessionId === "session-1") return { store: modelStoreA };
      if (sessionId === "session-2") return { store: modelStoreB };
      throw new Error("unknown model directory");
    }
  },
  sessions: {
    list: {
      getSnapshot: () => ({ current: currentSessionId }),
      subscribe(listener) {
        sessionListListeners.add(listener);
        return () => sessionListListeners.delete(listener);
      }
    },
    // Reproduce the blank-new-session window: a binding/input shell exists,
    // but the root session scope is not queryable yet.
    scope: (sessionId) => sessionId === "session-2"
        ? actxB
        : undefined
  },
  slots: {
    inject(name, setup) {
      assert.equal(name, "shell.overlay");
      return setup();
    },
    register(specification, component) {
      registered = { specification, component };
      return () => {};
    }
  }
};

fakeWindow.__deepSeekHarnessNativeAttachmentQueue.push({
  payload: payload(1, [attachment(path1)]),
  replay: false
});
plugin.apply(ctx);
assert.notEqual(fakeWindow.__deepSeekHarnessResolveNativeAttachmentSession, previousResolver);
assert.equal(fakeWindow.__deepSeekHarnessResolveNativeAttachmentSession(), "session-1");
assert.equal(registered.specification.name, "shell.overlay");
assert.equal(registered.specification.id, "native-attachments");
assert.equal(typeof registered.specification.inject, "function");
const line1 = plugin.managedReferenceLine(path1, 1);
assert.equal(draft, `${userDraft}\n${line1}`);
assert.deepEqual(fakeWindow.__deepSeekHarnessNativeAttachmentQueue, []);
assert.equal(directShellCalls > 0, true, "new-session payload did not use the direct input shell");
const modelRouteDetails = () => dispatchedEvents
  .filter((event) => event.type === plugin.MODEL_ROUTE_EVENT_NAME)
  .map((event) => event.detail);
assert.deepEqual(modelRouteDetails().slice(-2), [
  null,
  { version: 1, sessionId: "session-1", provider: "deepseek", model: "deepseek-v4" }
]);
modelStoreA.set({
  status: "ready",
  routable: true,
  current: { provider: "deepseek", model: "deepseek-v4-pro" }
});
assert.deepEqual(modelRouteDetails().at(-1), {
  version: 1,
  sessionId: "session-1",
  provider: "deepseek",
  model: "deepseek-v4-pro"
});

const sourceForSession = registered.specification.inject("session-1").source;
const rendered = registered.component({ source: sourceForSession });
assert.match(JSON.stringify(rendered), /paper\.pdf/u);
assert.match(JSON.stringify(rendered), /data-native-attachment-dock/u);
const provisionalSource = registered.specification.inject("new-session-slot-before-root-scope").source;
const provisionalRendered = registered.component({ source: provisionalSource });
assert.match(
  JSON.stringify(provisionalRendered),
  /paper\.pdf/u,
  "a blank-new-session slot id mismatch hid a committed attachment card"
);

const afterFirstRevision = draft;
let acceptedCount = 0;
fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(1, [attachment(path1)]),
  replay: false,
  accept() { acceptedCount += 1; }
});
assert.equal(draft, afterFirstRevision, "a repeated revision must not append");
assert.equal(acceptedCount, 1, "a repeated revision is consumed and acknowledged");
fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(2, [attachment(path1)]),
  replay: false,
  accept() { acceptedCount += 1; }
});
assert.equal(draft, afterFirstRevision, "a repeated id in a newer revision must not append");
assert.equal(acceptedCount, 2);

const dropTimeSession = fakeWindow.__deepSeekHarnessResolveNativeAttachmentSession();
currentSessionId = "session-2";
assert.equal(fakeWindow.__deepSeekHarnessResolveNativeAttachmentSession(), "session-2");
for (const listener of sessionListListeners) listener();
assert.deepEqual(modelRouteDetails().slice(-2), [
  null,
  { version: 1, sessionId: "session-2", provider: "moonshot", model: "kimi-k2" }
]);
modelStoreB.set({
  status: "selecting",
  routable: true,
  current: { provider: "moonshot", model: "kimi-k2.5" }
});
assert.equal(modelRouteDetails().at(-1), null, "a non-ready directory must fail closed");
modelStoreB.set({
  status: "ready",
  routable: true,
  current: { provider: "moonshot", model: "kimi-k2.5" }
});
assert.deepEqual(modelRouteDetails().at(-1), {
  version: 1,
  sessionId: "session-2",
  provider: "moonshot",
  model: "kimi-k2.5"
});
fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(3, [attachment(path2)], { sessionId: dropTimeSession }),
  replay: false,
  accept() {
    assert.equal(draft, `${userDraft}\n${line1}\n${plugin.managedReferenceLine(path2, 3)}`);
    acceptedCount += 1;
  }
});
const line2 = plugin.managedReferenceLine(path2, 3);
assert.equal(draft, `${userDraft}\n${line1}\n${line2}`);
assert.equal(draftB, "B 会话原文", "a session switch must not redirect an in-flight drop");
assert.equal(acceptedCount, 3);

const draftBeforeRejectedRemoval = draft;
currentSessionId = "session-1";
const removalRendered = registered.component({ source: sourceForSession });
const removalButtons = collectRenderedElements(
  removalRendered,
  (element) => element.type === "button" && typeof element.props?.onClick === "function"
);
assert.equal(removalButtons.length, 2, "the origin session must render both attachment removals");
acceptDraftWrites = false;
removalButtons[0].props.onClick();
assert.equal(draft, draftBeforeRejectedRemoval);
assert.match(
  JSON.stringify(registered.component({ source: sourceForSession })),
  /paper\.pdf/u,
  "a card must remain when the input machine rejects its removal"
);
acceptDraftWrites = true;
removalButtons[0].props.onClick();
assert.equal(draft, `${userDraft}\n${line2}`);
assert.equal(draft.startsWith(userDraft), true, "removing a card must preserve the user draft exactly");

draft = plugin.removeExactSegment(draft, `\n${line2}`);
assert.equal(draft, userDraft);
assert.equal(registered.component({ input: { draft }, source: sourceForSession }), null);

acceptDraftWrites = false;
fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(4, [attachment(path3)]),
  replay: false,
  accept() { acceptedCount += 1; }
});
assert.equal(draft, userDraft, "a rejected draft write must leave user text unchanged");
assert.equal(acceptedCount, 3, "a rejected draft write must not be acknowledged");

acceptDraftWrites = true;
fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(4, [attachment(path3)]),
  replay: false,
  accept() {
    assert.match(draft, /table\.xlsx/u, "acknowledgement must happen after the draft write");
    acceptedCount += 1;
  }
});
assert.match(draft, /table\.xlsx/u);
assert.equal(acceptedCount, 4);
draft = "";
assert.equal(registered.component({ input: { draft }, source: sourceForSession }), null);

const queuedPath = `Inbox/${uuid2}/queued.txt`;
const secondQueuedPath = `Inbox/${uuid3}/second-queued.txt`;
acceptDraftWrites = false;
fakeWindow.__deepSeekHarnessNativeAttachmentQueue.push({
  payload: payload(5, [attachment(queuedPath)]),
  replay: false
});
for (const listener of sessionListListeners) listener();
assert.equal(fakeWindow.__deepSeekHarnessNativeAttachmentQueue.length, 1);
assert.equal(draft, "", "a blocked queue drain must not partially update the draft");
let liveHigherRevisionAccepted = 0;
fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(6, [attachment(secondQueuedPath)], { sessionId: "session-2" }),
  replay: false,
  accept() { liveHigherRevisionAccepted += 1; }
});
assert.equal(liveHigherRevisionAccepted, 1, "a higher live revision in another session may proceed");
assert.match(draftB, /second-queued\.txt/u);
assert.equal(fakeWindow.__deepSeekHarnessNativeAttachmentQueue.length, 1);
acceptDraftWrites = true;
await new Promise((resolve) => setTimeout(resolve, 250));
assert.deepEqual(fakeWindow.__deepSeekHarnessNativeAttachmentQueue, []);
assert.match(draft, /queued\.txt/u, "a blocked draft did not retry when it became writable");

fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(5, [attachment(path1)], { version: 2 }),
  replay: false,
  accept() { acceptedCount += 1; }
});
assert.equal(warningCount, 4);
assert.equal(acceptedCount, 4, "invalid payloads must not be acknowledged");

fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(6, [attachment(path1)], { sessionId: "missing-session" }),
  replay: false,
  accept() { acceptedCount += 1; }
});
assert.equal(acceptedCount, 4, "an unknown drop-time session must not be acknowledged");

fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(7, [attachment(path1)], { sessionId: "" }),
  replay: false,
  accept() { acceptedCount += 1; }
});
assert.equal(acceptedCount, 4, "an invalid drop-time session must not be acknowledged");

fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(8, [attachment(path1)]),
  replay: "false",
  accept() { acceptedCount += 1; }
});
assert.equal(acceptedCount, 4, "replay must be a strict boolean");

const accessorEnvelope = {
  payload: payload(8, [attachment(path1)]),
  replay: false
};
Object.defineProperty(accessorEnvelope, "accept", {
  configurable: true,
  enumerable: true,
  get() {
    adversarialGetterCalls += 1;
    return () => { acceptedCount += 1; };
  }
});
fakeWindow.dispatch(plugin.EVENT_NAME, accessorEnvelope);
assert.equal(adversarialGetterCalls, 0, "event-envelope accessors must never execute");
assert.equal(acceptedCount, 4);

fakeWindow.__deepSeekHarnessNativeAttachmentQueue = new Array(1_000_000);
for (const listener of sessionListListeners) listener();
assert.equal(fakeWindow.__deepSeekHarnessNativeAttachmentQueue.length, 0, "oversized queues must truncate safely");

assert.equal(source.includes(".innerHTML"), false);
assert.equal(source.includes("dangerouslySetInnerHTML"), false);

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
assert.equal(manifest.dsh.client.platform, "web");
assert.deepEqual(manifest.dsh.client.inject, [
  "@deepseek-ai/dsh-client-runtime",
  "@deepseek-ai/dsh-client-ui-layout",
  "@deepseek-ai/dsh-client-ui-conversation",
  "@deepseek-ai/dsh-client-ui-model-selection"
]);
assert.equal(manifest.exports["./client"], "./lib/client.js");
assert.equal(
  manifest.peerDependencies["@deepseek-ai/dsh-client-ui-model-selection"],
  "^0.1.1-rc.2"
);

const patch = fs.readFileSync(patchPath, "utf8");
assert.match(patch, /id: native-attachments\s+name: '@tengqi\/dsh-native-attachments'/u);

for (const cleanup of effects.splice(0).reverse()) cleanup();
assert.equal(listeners.get(plugin.EVENT_NAME)?.size ?? 0, 0);
assert.equal(fakeWindow.__deepSeekHarnessResolveNativeAttachmentSession, previousResolver);
assert.equal(modelRouteDetails().at(-1), null, "plugin cleanup must clear the native model route");
assert.equal(modelStoreA.listenerCount(), 0);
assert.equal(modelStoreB.listenerCount(), 0);

const replayLine = plugin.managedReferenceLine(path1, 8);
draft = `刷新前用户原文\n${replayLine}`;
const draftBeforeReplay = draft;
plugin.apply(ctx);
const writesBeforeFalseReplay = setDraftCalls;
let replayAccepted = 0;
fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(8, [attachment(path1)]),
  replay: false,
  accept() { replayAccepted += 1; }
});
assert.equal(replayAccepted, 1);
assert.equal(draft, draftBeforeReplay);
assert.equal(setDraftCalls, writesBeforeFalseReplay, "replay=false must not duplicate an existing exact line");
assert.equal(draft.split(replayLine).length - 1, 1);
const falseReplaySource = registered.specification.inject("session-1").source;
assert.match(JSON.stringify(registered.component({ input: { draft }, source: falseReplaySource })), /paper\.pdf/u);
for (const cleanup of effects.splice(0).reverse()) cleanup();

fakeWindow.__deepSeekHarnessNativeAttachmentQueue.push({
  payload: payload(8, [attachment(path1)]),
  replay: true
});
const writesBeforeReplay = setDraftCalls;
plugin.apply(ctx);
assert.deepEqual(fakeWindow.__deepSeekHarnessNativeAttachmentQueue, []);
fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(8, [attachment(path1)]),
  replay: true,
  accept() { replayAccepted += 1; }
});
assert.equal(replayAccepted, 2);
assert.equal(draft, draftBeforeReplay);
assert.equal(setDraftCalls, writesBeforeReplay, "replay must never write or append a second reference");
const replaySource = registered.specification.inject("session-1").source;
assert.match(
  JSON.stringify(registered.component({ input: { draft }, source: replaySource })),
  /paper\.pdf/u,
  "replay must restore a card for an exact reference still in the draft"
);
for (const cleanup of effects.splice(0).reverse()) cleanup();

draft = "";
fakeWindow.__deepSeekHarnessNativeAttachmentQueue.push({
  payload: payload(8, [attachment(path1)]),
  replay: true
});
const writesBeforeEmptyReplay = setDraftCalls;
plugin.apply(ctx);
assert.deepEqual(fakeWindow.__deepSeekHarnessNativeAttachmentQueue, []);
fakeWindow.dispatch(plugin.EVENT_NAME, {
  payload: payload(8, [attachment(path1)]),
  replay: true,
  accept() { replayAccepted += 1; }
});
assert.equal(replayAccepted, 3, "an empty-draft replay is consumed safely");
assert.equal(draft, "", "replay must not resurrect a sent or deleted reference");
assert.equal(setDraftCalls, writesBeforeEmptyReplay, "empty-draft replay must not call setDraft");
const emptyReplaySource = registered.specification.inject("session-1").source;
assert.equal(registered.component({ input: { draft }, source: emptyReplaySource }), null);
for (const cleanup of effects.splice(0).reverse()) cleanup();
assert.equal(fakeWindow.__deepSeekHarnessResolveNativeAttachmentSession, previousResolver);
assert.equal(modelStoreA.listenerCount(), 0);
assert.equal(modelStoreB.listenerCount(), 0);

// Regression: a user deletion must win over a later lifecycle delivery of the
// same native batch. This is deliberately exercised through the rendered
// remove buttons, a model-status transition, plugin teardown/re-apply, and
// both replay classifications. PDF, PNG, and Markdown must share one policy.
const deletionRegressionUserDraft = "删除回归用户原文";
const deletionRegressionPDF = `Inbox/${uuid1}/delete-regression.pdf`;
const deletionRegressionPNG = `Inbox/${uuid2}/delete-regression.png`;
const deletionRegressionMarkdown = `Inbox/${uuid3}/delete-regression.md`;
const deletionRegressionAttachments = [
  attachment(deletionRegressionPDF, { kind: "PDF" }),
  attachment(deletionRegressionPNG, { kind: "图片" }),
  attachment(deletionRegressionMarkdown, { kind: "Markdown" })
];
const deletionRegressionPayload = payload(40, deletionRegressionAttachments);

function collectRenderedElements(value, predicate, result = []) {
  if (value === null || typeof value !== "object") return result;
  if (predicate(value)) result.push(value);
  const children = value.props?.children;
  if (Array.isArray(children)) {
    for (const child of children) collectRenderedElements(child, predicate, result);
  } else {
    collectRenderedElements(children, predicate, result);
  }
  return result;
}

draft = deletionRegressionUserDraft;
currentSessionId = "session-1";
acceptDraftWrites = true;
assert.equal(
  plugin.LIFECYCLE_EVENT_NAME,
  "deepseek-harness:native-attachment-lifecycle"
);
const lifecycleDetails = () => dispatchedEvents
  .filter((event) => event.type === plugin.LIFECYCLE_EVENT_NAME)
  .map((event) => event.detail);
const lifecycleCountBeforeDeletionRegression = lifecycleDetails().length;
fakeWindow.__deepSeekHarnessNativeAttachmentQueue.push({
  payload: deletionRegressionPayload,
  replay: false
});
plugin.apply(ctx);
assert.deepEqual(fakeWindow.__deepSeekHarnessNativeAttachmentQueue, []);
assert.deepEqual(
  lifecycleDetails().slice(lifecycleCountBeforeDeletionRegression),
  [{
    version: 1,
    type: "accepted",
    revision: 40,
    sessionId: "session-1",
    attachmentIds: [
      deletionRegressionPDF,
      deletionRegressionPNG,
      deletionRegressionMarkdown
    ]
  }],
  "draining a queued batch must publish the late native acceptance ACK"
);
for (const relativePath of [
  deletionRegressionPDF,
  deletionRegressionPNG,
  deletionRegressionMarkdown
]) {
  assert.match(draft, new RegExp(relativePath.split("/").at(-1).replace(".", "\\."), "u"));
}

const deletionRegressionSource = registered.specification.inject("session-1").source;
const deletionRegressionRendered = registered.component({
  input: { draft },
  source: deletionRegressionSource
});
const deletionRegressionRemoveButtons = collectRenderedElements(
  deletionRegressionRendered,
  (element) => element.type === "button" && typeof element.props?.onClick === "function"
);
assert.equal(deletionRegressionRemoveButtons.length, 3, "PDF/PNG/MD must expose one remove action each");
for (const [index, button] of deletionRegressionRemoveButtons.entries()) {
  button.props.onClick();
  assert.deepEqual(
    lifecycleDetails().at(-1),
    {
      version: 1,
      type: "removed",
      revision: 40,
      sessionId: "session-1",
      attachmentIds: [deletionRegressionAttachments[index].id]
    },
    "each remove action must publish one exact native tombstone"
  );
}
assert.equal(draft, deletionRegressionUserDraft, "removing PDF/PNG/MD must restore the user draft");
assert.equal(
  registered.component({ input: { draft }, source: deletionRegressionSource }),
  null,
  "all three deleted attachment cards must disappear"
);
assert.deepEqual(
  lifecycleDetails().slice(lifecycleCountBeforeDeletionRegression),
  [
    {
      version: 1,
      type: "accepted",
      revision: 40,
      sessionId: "session-1",
      attachmentIds: [
        deletionRegressionPDF,
        deletionRegressionPNG,
        deletionRegressionMarkdown
      ]
    },
    ...deletionRegressionAttachments.map((item) => ({
      version: 1,
      type: "removed",
      revision: 40,
      sessionId: "session-1",
      attachmentIds: [item.id]
    }))
  ],
  "queued acceptance followed by PDF/PNG/MD removal must be ordered and lossless"
);

modelStoreA.set({
  status: "loading",
  routable: false,
  current: { provider: "deepseek", model: "deepseek-v4-pro" }
});
await Promise.resolve();
modelStoreA.set({
  status: "ready",
  routable: true,
  current: { provider: "deepseek", model: "deepseek-v4-pro" }
});
for (const cleanup of effects.splice(0).reverse()) cleanup();

// A correctly classified replay is already conservative: without managed
// reference lines it must restore neither draft text nor cards.
fakeWindow.__deepSeekHarnessNativeAttachmentQueue.push({
  payload: deletionRegressionPayload,
  replay: true
});
const writesBeforeDeletionReplay = setDraftCalls;
const lifecycleCountBeforeDeletionReplay = lifecycleDetails().length;
plugin.apply(ctx);
assert.deepEqual(fakeWindow.__deepSeekHarnessNativeAttachmentQueue, []);
assert.equal(draft, deletionRegressionUserDraft);
assert.equal(setDraftCalls, writesBeforeDeletionReplay, "deleted replay must not rewrite the draft");
const deletionReplaySource = registered.specification.inject("session-1").source;
assert.equal(
  registered.component({ input: { draft }, source: deletionReplaySource }),
  null,
  "deleted PDF/PNG/MD must stay absent after replay"
);
assert.deepEqual(
  lifecycleDetails().slice(lifecycleCountBeforeDeletionReplay),
  [{
    version: 1,
    type: "removed",
    revision: 40,
    sessionId: "session-1",
    attachmentIds: [
      deletionRegressionPDF,
      deletionRegressionPNG,
      deletionRegressionMarkdown
    ]
  }],
  "replay after teardown must reaffirm tombstones without a new acceptance ACK"
);
for (const cleanup of effects.splice(0).reverse()) cleanup();

// If a status/navigation race loses the native acknowledgement, the same
// lifecycle delivery may arrive as replay=false after the plugin store was
// recreated. The user's explicit deletion must still be authoritative.
fakeWindow.__deepSeekHarnessNativeAttachmentQueue.push({
  payload: deletionRegressionPayload,
  replay: false
});
const writesBeforeLateDeletionDelivery = setDraftCalls;
const lifecycleCountBeforeLateDeletionDelivery = lifecycleDetails().length;
plugin.apply(ctx);
assert.deepEqual(fakeWindow.__deepSeekHarnessNativeAttachmentQueue, []);
assert.equal(
  draft,
  deletionRegressionUserDraft,
  "REGRESSION: a late lifecycle delivery resurrected deleted PDF/PNG/MD references"
);
assert.equal(
  setDraftCalls,
  writesBeforeLateDeletionDelivery,
  "a late lifecycle delivery must not rewrite the draft after explicit deletion"
);
const lateDeletionSource = registered.specification.inject("session-1").source;
assert.equal(
  registered.component({ input: { draft }, source: lateDeletionSource }),
  null,
  "deleted PDF/PNG/MD cards must not revive after a late lifecycle delivery"
);
assert.deepEqual(
  lifecycleDetails().slice(lifecycleCountBeforeLateDeletionDelivery),
  [{
    version: 1,
    type: "removed",
    revision: 40,
    sessionId: "session-1",
    attachmentIds: [
      deletionRegressionPDF,
      deletionRegressionPNG,
      deletionRegressionMarkdown
    ]
  }],
  "late replay=false delivery must reaffirm removals and emit no acceptance ACK"
);
for (const cleanup of effects.splice(0).reverse()) cleanup();

// Screenshot regression: a pure image routed through the DeepSeek text-only
// managed path must create a card in the drop-time conversation, even if the
// user switches conversations before the delivery is consumed. Deleting that
// card must survive a page/plugin refresh without restoring draft text or the
// card. This keeps the visible image case independent from the mixed PDF/PNG/MD
// regression above.
const deepSeekFlashImagePath = `Inbox/${uuid1}/deepseek-flash-drop.png`;
const deepSeekFlashImage = attachment(deepSeekFlashImagePath, { kind: "图片" });
const deepSeekFlashPayload = payload(41, [deepSeekFlashImage]);
const deepSeekFlashUserDraft = "DeepSeek 图片拖入回归";
draft = deepSeekFlashUserDraft;
acceptDraftWrites = true;
currentSessionId = "session-2";
const sessionTwoDraftBeforeImageDelivery = draftB;
const lifecycleCountBeforeImageDelivery = lifecycleDetails().length;
fakeWindow.__deepSeekHarnessNativeAttachmentQueue.push({
  payload: deepSeekFlashPayload,
  replay: false
});
plugin.apply(ctx);
assert.deepEqual(fakeWindow.__deepSeekHarnessNativeAttachmentQueue, []);
const deepSeekFlashLine = plugin.managedReferenceLine(deepSeekFlashImagePath, 41);
assert.equal(
  draft,
  `${deepSeekFlashUserDraft}\n${deepSeekFlashLine}`,
  "a DeepSeek PNG must become an exact managed reference in its drop-time session"
);
assert.equal(
  draftB,
  sessionTwoDraftBeforeImageDelivery,
  "switching conversations must not redirect a DeepSeek image drop"
);
assert.deepEqual(
  lifecycleDetails().slice(lifecycleCountBeforeImageDelivery),
  [{
    version: 1,
    type: "accepted",
    revision: 41,
    sessionId: "session-1",
    attachmentIds: [deepSeekFlashImagePath]
  }],
  "the managed DeepSeek image must acknowledge its exact drop-time session"
);
const deepSeekFlashSource = registered.specification.inject("session-1").source;
assert.equal(
  registered.component({ source: deepSeekFlashSource }),
  null,
  "an attachment from session-1 must not appear while session-2 is current"
);
currentSessionId = "session-1";
const deepSeekFlashRendered = registered.component({
  source: deepSeekFlashSource
});
const deepSeekFlashRemoveButtons = collectRenderedElements(
  deepSeekFlashRendered,
  (element) => element.type === "button" && typeof element.props?.onClick === "function"
);
assert.equal(deepSeekFlashRemoveButtons.length, 1, "a managed DeepSeek PNG must expose one remove action");
assert.match(JSON.stringify(deepSeekFlashRendered), /deepseek-flash-drop\.png/u);
deepSeekFlashRemoveButtons[0].props.onClick();
assert.equal(draft, deepSeekFlashUserDraft, "removing the PNG card must preserve user text");
assert.equal(
  registered.component({ source: deepSeekFlashSource }),
  null,
  "the removed DeepSeek PNG card must disappear immediately"
);
assert.deepEqual(
  lifecycleDetails().at(-1),
  {
    version: 1,
    type: "removed",
    revision: 41,
    sessionId: "session-1",
    attachmentIds: [deepSeekFlashImagePath]
  }
);
for (const cleanup of effects.splice(0).reverse()) cleanup();

fakeWindow.__deepSeekHarnessNativeAttachmentQueue.push({
  payload: deepSeekFlashPayload,
  replay: true
});
const writesBeforeDeepSeekImageRefresh = setDraftCalls;
const lifecycleCountBeforeDeepSeekImageRefresh = lifecycleDetails().length;
plugin.apply(ctx);
assert.deepEqual(fakeWindow.__deepSeekHarnessNativeAttachmentQueue, []);
assert.equal(draft, deepSeekFlashUserDraft, "refresh resurrected a deleted DeepSeek PNG reference");
assert.equal(
  setDraftCalls,
  writesBeforeDeepSeekImageRefresh,
  "refresh must not rewrite the draft after deleting a managed DeepSeek PNG"
);
const deepSeekFlashRefreshSource = registered.specification.inject("session-1").source;
assert.equal(
  registered.component({ input: { draft }, source: deepSeekFlashRefreshSource }),
  null,
  "refresh resurrected a deleted DeepSeek PNG card"
);
assert.deepEqual(
  lifecycleDetails().slice(lifecycleCountBeforeDeepSeekImageRefresh),
  [{
    version: 1,
    type: "removed",
    revision: 41,
    sessionId: "session-1",
    attachmentIds: [deepSeekFlashImagePath]
  }],
  "refresh must reaffirm the PNG tombstone without a new acceptance ACK"
);
for (const cleanup of effects.splice(0).reverse()) cleanup();

console.log("NATIVE_ATTACHMENTS_PLUGIN_OK image_card_session_delete_refresh=1");
