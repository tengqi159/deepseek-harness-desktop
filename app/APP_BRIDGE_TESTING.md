# DeepSeek App Bridge end-to-end QA

Run the repository-level test from the project root:

```sh
scripts/test_app_bridge_e2e.sh
```

The test builds `DeepSeekAppBridge` and the test-only
`DeepSeekBridgeFixture`, then creates ad-hoc-signed fixture app bundles in a
new temporary directory. It launches two instances of the primary bundle plus
a different-bundle decoy. The primary fixture contains an editable field, a
secure field, a button, keyboard and scroll probes, and two windows with a
known OCR marker. The extra instances prove that the production attachment is
pinned to the exact saved PID and process launch time, that a same-bundle
sibling cannot take over, and that an MCP target cannot bypass the selected
bundle.

The debug bridge receives a temporary selection path through
`DSH_APP_BRIDGE_SELECTION_FILE`; the release bridge is separately verified to
ignore that test-only override. The test therefore never opens or overwrites
the production selection file. It does not load DeepSeek settings or
credentials, inspect another user app, request a macOS permission, or accept a
system prompt. Fixture processes and temporary files are removed on success.

Coverage includes:

- MCP `initialize`, `tools/list`, protocol `ping`, and the `ping` tool.
- Read-only permission preflight and `list_apps`.
- Missing, PID-only, changed, sensitive-bundle, and explicitly overridden
  selections, plus missing/mismatched process launch times and the exact
  process-lifetime format written by the production UI.
- Focused-window AX scope, tree size bounds, the 256 KiB MCP payload limit,
  secondary-window exclusion, and secure/text/URL secret redaction.
- Required, stale, changed-target, and consumed snapshot IDs.
- `set_value`, secure-field refusal, `click_element`, `activate_app`,
  `type_text`, `press_key`, and `scroll` against the fixture only. Scroll QA
  verifies that the document's visible origin moved, not just that an event
  entered the app.
- In-memory OCR of the focused selected-app window, including confirmation
  that no image was persisted, plus `click_point` using an OCR-derived center.
- Final checks that the cross-bundle decoy and same-bundle sibling remained
  unchanged, and that terminating the selected PID did not transfer control
  to its sibling.
- A synthetic `wrapper -> dummy dsh -> bridge helper` chain proving that the
  parent-death watchdog terminates both children without starting real dsh or
  touching production state.

Accessibility, event-posting, or Screen Recording checks are reported as
`SKIP` when the permission is not already granted. The test never requests a
permission. Build failures and behavioral mismatches are reported as `FAIL`.
Permission results belong to the process chain that launches this script (for
example, Codex or Terminal); they do not prove that an independently launched
installed app has the same macOS TCC responsible-process identity. Run the
installed-app acceptance check separately for that identity.

Use `--keep-temp` only when diagnosing a failure:

```sh
scripts/test_app_bridge_e2e.sh --keep-temp
```
