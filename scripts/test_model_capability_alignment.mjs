#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(scriptDirectory);
const registryPath = path.join(root, "integration/model-capabilities.json");
const profilePatchPath = path.join(root, "integration/dsh-home-template/profiles/web/cordis.patch.yml");
const migrationPath = path.join(root, "app/Sources/DeepSeekHarnessMac/Services/DeepSeekModelCatalogMigration.swift");
const artifactBridgePath = path.join(root, "app/Sources/DeepSeekArtifactBridge/main.swift");

const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
const profilePatch = fs.readFileSync(profilePatchPath, "utf8");
const migration = fs.readFileSync(migrationPath, "utf8");
const artifactBridge = fs.readFileSync(artifactBridgePath, "utf8");

const provider = registry.providers.find((entry) => entry.id === "deepseek-official");
assert.ok(provider, "DeepSeek provider is missing from the capability registry");
assert.equal(provider.input?.image, "supported", "DeepSeek provider must permit the one exact Vision model");

const imageEnabled = (provider.models ?? [])
  .filter((model) => model.lifecycle === "active" && model.input?.includes("image"))
  .map((model) => model.id);
assert.deepEqual(
  imageEnabled,
  ["deepseek-v4-flash-vision-exp"],
  "only the verified exact DeepSeek Vision model may be image-enabled"
);
assert.match(profilePatch, /- id: deepseek-v4-flash-vision-exp[\s\S]*?inputModalities: \[text, image\]/u);
assert.match(profilePatch, /- id: deepseek-v4-flash[\s\S]*?inputModalities: \[text\]/u);
assert.match(profilePatch, /- id: deepseek-v4-pro[\s\S]*?inputModalities: \[text\]/u);
assert.match(migration, /static let visionModelID = "deepseek-v4-flash-vision-exp"/u);
assert.match(migration, /inputModalities: \[text, image\]/u);
assert.match(artifactBridge, /"deepseek-v4-flash-vision-exp", "input": \["text", "image"\]/u);
assert.match(artifactBridge, /"deepseek-v4-pro", "input": \["text"\]/u);

console.log("MODEL_CAPABILITY_ALIGNMENT_QA_OK exact_vision_model=1 text_routes=2 settings_migration=1");
