#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(scriptDirectory);
const integrationRoot = path.join(root, "integration");
const packageDirectory = path.join(
  integrationRoot,
  "dsh-home-template/profiles/web/node_modules/@tengqi/dsh-capability-catalog"
);
const clientPath = path.join(packageDirectory, "lib/client.js");
const hostPath = path.join(packageDirectory, "lib/index.js");
const manifestPath = path.join(packageDirectory, "package.json");
const patchPath = path.join(integrationRoot, "cordis.macos-computer-use.patch.yml");

for (const requiredPath of [clientPath, hostPath, manifestPath, patchPath]) {
  assert.equal(fs.existsSync(requiredPath), true, `missing capability-catalog file: ${requiredPath}`);
}

const source = fs.readFileSync(clientPath, "utf8");
let moduleDefinition;
const fakeWindow = {
  __ModuleLoader__: {
    load(definition) {
      moduleDefinition = definition;
    }
  }
};
Function("window", source)(fakeWindow);
assert.equal(moduleDefinition?.id, "@tengqi/dsh-capability-catalog");

function element(type, props, ...children) {
  return { type, props: { ...(props ?? {}), children } };
}

const stateSlots = [];
const fakeReact = {
  createElement: element,
  useMemo(factory) {
    return factory();
  },
  useState(initial) {
    const index = stateSlots.length;
    stateSlots.push(typeof initial === "function" ? initial() : initial);
    return [stateSlots[index], (next) => {
      stateSlots[index] = typeof next === "function" ? next(stateSlots[index]) : next;
    }];
  },
  useSyncExternalStore(_subscribe, getSnapshot) {
    return getSnapshot();
  }
};

function FakeMenu() {}
function fakeIcon(name) {
  return function Icon(props) {
    return element(name, props);
  };
}
const primitives = {
  Menu: FakeMenu,
  IconApiOutline14: fakeIcon("IconApiOutline14"),
  IconBrowseOutline16: fakeIcon("IconBrowseOutline16"),
  IconCodeOutline16: fakeIcon("IconCodeOutline16"),
  IconCordisPluginOutline14: fakeIcon("IconCordisPluginOutline14"),
  IconDataOutline16: fakeIcon("IconDataOutline16"),
  IconFolderOpenOutline16: fakeIcon("IconFolderOpenOutline16"),
  IconGoalOutline16: fakeIcon("IconGoalOutline16"),
  IconPaperclipOutline16: fakeIcon("IconPaperclipOutline16"),
  IconRefreshOutline16: fakeIcon("IconRefreshOutline16"),
  IconSkillOutline16: fakeIcon("IconSkillOutline16"),
  IconSparkle16: fakeIcon("IconSparkle16")
};

const plugin = moduleDefinition.factory((specifier) => {
  if (specifier === "react") return fakeReact;
  if (specifier === "@deepseek-ai/dsh-client-ui-primitives") return primitives;
  throw new Error(`unexpected client require: ${specifier}`);
});

assert.equal(plugin.name, "capability-catalog");
assert.deepEqual(plugin.inject, [
  "slots",
  "sessions",
  "connection",
  "remote",
  "remote.commands",
  "remote.pluginInventory"
]);

assert.equal(plugin.invocationModeForSkill({ modelInvocable: true }), "automatic");
assert.equal(plugin.invocationModeForSkill({ modelInvocable: false }), "manual");
assert.equal(plugin.invocationModeForPlugin({ entryId: "mcp-artifacts", moduleName: "@deepseek-ai/dsh-mcp-client" }), "after-import");
assert.equal(plugin.invocationModeForPlugin({ entryId: "native-attachments", moduleName: "@tengqi/dsh-native-attachments" }), "after-import");
assert.equal(plugin.invocationModeForPlugin({ entryId: "mcp-macos-computer-use", moduleName: "@deepseek-ai/dsh-mcp-client" }), "after-attach");
assert.equal(plugin.invocationModeForPlugin({ entryId: "tool-web", moduleName: "@deepseek-ai/dsh-tool-web" }), "on-demand");

const slash = plugin.appendSlashInvocation("已有研究问题", "pdf");
assert.equal(slash, "已有研究问题\n/pdf ");
assert.equal(plugin.appendSlashInvocation("", "plan"), "/plan ");
assert.equal(plugin.appendSlashInvocation("已有内容\n", "goal"), "已有内容\n/goal ");
assert.equal(plugin.appendSlashInvocation("unchanged", "bad name"), "unchanged");

const fixtureSecret = ["sk", "fixturevalue123"].join("-");
const commands = [
  { name: "goal", description: "Set a durable goal" },
  { name: "export", description: `Export without leaking ${fixtureSecret}` },
  { name: "bad name", description: "must be rejected" }
];
const skills = [
  { name: "pdf", description: "Read and verify PDF files", modelInvocable: true },
  { name: "latex", description: "Compile LaTeX manually", modelInvocable: false }
];
const inventory = [
  { entryId: "include:mcp-artifacts", moduleName: "@deepseek-ai/dsh-mcp-client", enabled: true, fiberPhase: "active" },
  { entryId: "include:mcp-artifacts", moduleName: "@deepseek-ai/dsh-mcp-client", enabled: true, fiberPhase: "active" },
  { entryId: "include:mcp-macos-computer-use", moduleName: "@deepseek-ai/dsh-mcp-client", enabled: true, fiberPhase: "loading" },
  { entryId: "include:native-attachments", moduleName: "@tengqi/dsh-native-attachments", enabled: false, fiberPhase: null },
  { entryId: "tool-web", moduleName: "@deepseek-ai/dsh-tool-web", enabled: false, fiberPhase: null },
  { entryId: "host-placeholder", moduleName: "@deepseek-ai/dsh-tool-placeholder", enabled: true, fiberPhase: "active" },
  { entryId: "core-runtime", moduleName: "@deepseek-ai/dsh-runtime", enabled: true, fiberPhase: "active" }
];

const derived = plugin.deriveCatalog({ commands, skills, plugins: inventory }, "zh");
assert.equal(derived.some((item) => item.id === "command:goal" && item.invocation === "manual" && item.selectable), true);
assert.equal(derived.some((item) => item.id === "skill:pdf" && item.invocation === "automatic" && item.selectable), true);
assert.equal(derived.some((item) => item.id === "skill:latex" && item.invocation === "manual" && item.selectable), true);
assert.equal(derived.some((item) => item.id === "plugin:mcp-artifacts" && item.invocation === "after-import" && !item.selectable), true);
assert.equal(derived.some((item) => item.id === "plugin:mcp-macos-computer-use" && item.invocation === "after-attach"), true);
assert.equal(derived.some((item) => item.id === "plugin:mcp-macos-computer-use" && item.statusLabel === "加载中"), true);
assert.equal(derived.some((item) => item.id === "plugin:native-attachments" && item.statusLabel === "已停用"), true);
assert.equal(derived.some((item) => item.id === "plugin:tool-web"), false);
assert.equal(derived.some((item) => item.id === "plugin:host-placeholder"), false, "raw host placeholders must not enter the capability menu");
assert.equal(derived.some((item) => item.id === "plugin:core-runtime"), false, "core infrastructure must not flood the capability menu");
assert.deepEqual(
  derived.filter((item) => item.kind === "plugin").map((item) => item.id).sort(),
  ["plugin:mcp-artifacts", "plugin:mcp-macos-computer-use", "plugin:native-attachments"],
  "only the three companion capabilities may be projected from raw plugin inventory"
);
assert.equal(JSON.stringify(derived).includes(fixtureSecret), false, "credential-looking text must be redacted");
assert.equal(derived.every((item) => ["research", "code", "computer", "workflow", "system"].includes(item.group)), true);

const menuEntries = plugin.menuEntriesFor(derived, "zh");
assert.equal(menuEntries.some((entry) => entry.type === "label" && entry.text === "研究与文件"), true);
assert.equal(menuEntries.some((entry) => entry.type === "label" && entry.text === "浏览器与电脑"), true);
assert.equal(menuEntries.some((entry) => entry.id === "skill:pdf" && entry.icon), true);
assert.equal(menuEntries.some((entry) => entry.id === "plugin:mcp-artifacts" && entry.disabled === true), true, "plugin rows are status-only and must not look actionable");
assert.equal(menuEntries.some((entry) => entry.id === "plugin:native-attachments" && entry.disabled === true), true);
const pdfMenuRow = menuEntries.find((entry) => entry.id === "skill:pdf");
assert.equal(JSON.stringify(pdfMenuRow.label).includes("Read and verify PDF files"), false, "shortcut rows must stay one-line and compact");
assert.equal(JSON.stringify(pdfMenuRow.label).includes("模型可自动选择"), true);
assert.equal(JSON.stringify(menuEntries.find((entry) => entry.id === "plugin:mcp-artifacts").label).includes("运行中"), true);
assert.equal(JSON.stringify(menuEntries.find((entry) => entry.id === "plugin:mcp-macos-computer-use").label).includes("加载中"), true);
assert.equal(JSON.stringify(menuEntries.find((entry) => entry.id === "plugin:native-attachments").label).includes("已停用"), true);

let commandCalls = 0;
let skillCalls = 0;
let pluginCalls = 0;
const controller = plugin.createCatalogController({
  sessionId: "session-1",
  locale: "zh",
  async listCommands(sessionId) {
    commandCalls += 1;
    assert.equal(sessionId, "session-1");
    return commands;
  },
  async listSkills(sessionId) {
    skillCalls += 1;
    assert.equal(sessionId, "session-1");
    return skills;
  },
  async listPlugins() {
    pluginCalls += 1;
    return inventory;
  }
});
assert.equal(controller.getSnapshot().status, "idle");
await controller.open();
assert.equal(controller.getSnapshot().open, true);
assert.equal(controller.getSnapshot().status, "ready");
assert.deepEqual([commandCalls, skillCalls, pluginCalls], [1, 1, 1], "every open must read all three live catalogs");
controller.close();
await controller.open();
assert.deepEqual([commandCalls, skillCalls, pluginCalls], [2, 2, 2], "reopening must not serve a stale one-shot catalog");

let releaseFirst;
const staleController = plugin.createCatalogController({
  sessionId: "session-stale",
  locale: "en",
  listCommands: async () => new Promise((resolve) => { releaseFirst = resolve; }),
  listSkills: async () => [],
  listPlugins: async () => []
});
const firstRefresh = staleController.refresh();
staleController.replaceLoaders({
  listCommands: async () => [{ name: "newer", description: "new" }],
  listSkills: async () => [],
  listPlugins: async () => []
});
await staleController.refresh();
releaseFirst([{ name: "older", description: "old" }]);
await firstRefresh;
assert.equal(staleController.getSnapshot().items.some((item) => item.id === "command:newer"), true);
assert.equal(staleController.getSnapshot().items.some((item) => item.id === "command:older"), false, "older response must not overwrite the latest catalog");

let registered;
const effects = [];
const eventHandlers = new Map();
const ctx = {
  logger: { warn() {} },
  slots: {
    inject(name, factory) {
      assert.equal(name, "conversation.input.left");
      factory();
    },
    register(specification, component) {
      registered = { specification, component };
      return () => {};
    }
  },
  sessions: {
    subagentAddress() {
      return undefined;
    }
  },
  remote: {
    commands: {
      async list(sessionId) {
        assert.equal(sessionId, "session-1");
        return { ok: true, value: commands };
      }
    },
    pluginInventory: {
      async list() {
        return { ok: true, value: { entries: inventory } };
      }
    },
    $on(name, handler) {
      eventHandlers.set(name, handler);
      return () => eventHandlers.delete(name);
    }
  },
  on(name, handler) {
    eventHandlers.set(name, handler);
    return () => eventHandlers.delete(name);
  },
  get(name) {
    if (name === "connection") {
      return {
        api: {
          skills: {
            async list({ sessionId }) {
              assert.equal(sessionId, "session-1");
              return { result: { ok: true, value: { skills } } };
            }
          }
        }
      };
    }
    throw new Error(`unexpected service lookup: ${name}`);
  },
  effect(effect) {
    const cleanup = effect();
    if (typeof cleanup === "function") effects.push(cleanup);
    return cleanup;
  }
};

plugin.apply(ctx);
assert.equal(registered?.specification.name, "conversation.input.left");
assert.equal(registered?.specification.id, "capability-catalog");
const injected = registered.specification.inject("session-1");
assert.equal(typeof injected.catalog.open, "function");
await injected.catalog.open();

stateSlots.length = 0;
const draftWrites = [];
let submitCalls = 0;
const rendered = registered.component({
  sessionId: "session-1",
  session: {},
  input: { draft: "研究这份材料" },
  inputActions: {
    setDraft(next) {
      draftWrites.push(next);
    },
    submit() {
      submitCalls += 1;
    }
  },
  catalog: injected.catalog
});
assert.equal(rendered.type, FakeMenu, "surface must use the official primitives Menu");
assert.equal(rendered.props.side, "top");
assert.equal(rendered.props.portal, true);
rendered.props.onSelect("skill:pdf");
assert.deepEqual(draftWrites, ["研究这份材料\n/pdf "]);
assert.equal(submitCalls, 0, "manual catalog choices must never submit the composer");
rendered.props.onSelect("plugin:mcp-artifacts");
assert.equal(draftWrites.length, 1, "status-only plugin rows must never write the draft");

for (const cleanup of effects.splice(0).reverse()) cleanup();

assert.equal(source.includes(".innerHTML"), false);
assert.equal(source.includes("dangerouslySetInnerHTML"), false);
assert.equal(source.includes("querySelector"), false, "client plugin must not monkey-patch the upstream DOM");
assert.equal(source.includes(".submit("), false, "client plugin must not submit on behalf of the user");
assert.match(source, /ctx\.remote\.commands\.list/u);
assert.match(source, /ctx\.remote\.pluginInventory\.list/u);
assert.match(source, /\.api\.skills\.list/u);
assert.match(source, /conversation\.input\.left/u);
assert.match(source, /primitives\.Menu/u);

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
assert.equal(manifest.private, true);
assert.equal(manifest.license, "MIT");
assert.equal(manifest.dsh.client.platform, "web");
assert.deepEqual(manifest.dsh.client.inject, [
  "@deepseek-ai/dsh-api-remotes",
  "@deepseek-ai/dsh-client-runtime",
  "@deepseek-ai/dsh-client-ui-conversation"
]);
assert.equal(manifest.exports["./client"], "./lib/client.js");
assert.equal(manifest.peerDependencies["@deepseek-ai/dsh-client-ui-primitives"], "^0.1.0-rc.6");
assert.equal(manifest.peerDependencies["@deepseek-ai/dsh-client-connection"], "^0.1.0-rc.6");

const hostSource = fs.readFileSync(hostPath, "utf8");
assert.match(hostSource, /function apply\(\) \{\}/u);
assert.equal(hostSource.includes("process.env"), false);

const patch = fs.readFileSync(patchPath, "utf8");
assert.match(patch, /id: capability-catalog\s+name: '@tengqi\/dsh-capability-catalog'/u);

console.log("CAPABILITY_CATALOG_QA_OK");
