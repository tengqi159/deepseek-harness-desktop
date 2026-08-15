# SSH Remote Compute

DeepSeek Harness Desktop 1.6.0 adds a narrow, explicit SSH workflow for research servers. It is designed for jobs such as checking GPU availability, launching training, following logs, and moving selected artifacts between the Mac and one remote workspace.

It is a clean-room companion feature built on the system OpenSSH client. It is not the upstream Harness shell moved to another machine, and it is not equivalent to Codex remote projects or a general remote desktop.

## The user flow

1. Define a concrete, top-level host alias in `~/.ssh/config`.
2. Choose **Remote Server** in the native toolbar.
3. Select that alias and enter one absolute Linux workspace, such as `/srv/research/project`.
4. DeepSeek Harness Desktop resolves the alias with `ssh -G` and stores a private selection record for at most 24 hours. **Test Connection** is a separate user action; remote tools also revalidate the selection and connection when they run.
5. Ask naturally: “Check the GPUs,” “start this training,” or “follow the latest log.” The model can choose the registered remote tools when the task matches.

DeepSeek Harness Desktop does not automatically choose a server, accept a host key, enter a password, or open an interactive prompt.

## Available tools

| Kind | Operations |
| --- | --- |
| Connection | Ping the local bridge, inspect the current selection, and test the selected endpoint |
| Read-only | Inspect server facts, list tracked jobs, read status, and read bounded log tails |
| Command | Run one bounded remote command |
| Jobs | Start a background job, inspect its exact identity, and cancel that exact process group |
| Transfer | Stream one file into or out of the selected workspace with local and remote size/path checks |

Remote output is bounded before it enters model context, and common credential-shaped text is redacted locally. A bounded result is still server data: once returned by a tool, it can be sent to the configured model and stored in the local Harness session.

## Automatic use and confirmation

- After the user has selected a server, the model may automatically choose read-only inspection, status, or log tools when the request clearly calls for them.
- Running any arbitrary remote command, starting or cancelling a job, uploading, or downloading requires `confirmed: true` plus the exact confirmation summary requested for that action.
- The bundled Skill instructs the agent to ask immediately before consequential work. This is a model-enforced workflow control, not a cryptographically unforgeable native approval token.
- The upstream **Full access** preset also exposes a general shell. A user or model with that access can run `ssh` outside this bridge, so the bridge is not an account-level sandbox or policy boundary.

## What is pinned on every action

The native selection record contains a UUID, selection and expiry times, host alias, resolved hostname, user, port, and remote workspace. It must be a current-user-owned regular file with owner-only permissions.

Every bridge action reloads that record, reruns `ssh -G`, compares the resolved tuple, and then pins hostname, user, and port on the OpenSSH command line. A changed or expired selection fails closed. The bridge does not silently fall back to another host with the same alias.

Background jobs also record their command launcher, PID, process-group ID, Linux `/proc` start time, state, and stdout/stderr under `<workspace>/.harnessmate/jobs/<id>/`. Status and cancellation recheck the process identity before acting, which avoids treating a reused PID as the original training job. These remote records survive app disconnects, are not automatically deleted in 1.6.0, and are not redacted at rest; only bounded results returned to Harness receive local best-effort redaction.

## File boundary

Transfers stay under the selected workspace:

- paths must be relative, normalized, and free of traversal;
- remote directories and files are opened and validated through one pinned SSH stream;
- symbolic-link swaps and changing local inputs fail closed;
- uploads publish only after the complete local file has been revalidated;
- downloads enforce a hard byte limit while streaming, before the destination is published;
- partial local files are not exposed as successful downloads.

These checks reduce accidental path escape. They do not protect against a malicious remote account that controls its own kernel, OpenSSH server, or standard utilities.

## Supported in 1.6.0

- macOS system OpenSSH
- explicit top-level aliases from `~/.ssh/config`
- public-key authentication or an existing `ssh-agent`
- strict host-key checking
- one selected server and one absolute workspace
- non-interactive commands and Linux background jobs
- Linux servers with `/proc`, `setsid`, and common GNU utilities

Not supported:

- passwords, keyboard-interactive authentication, MFA prompts, or passphrase UI
- interactive TTY sessions
- wildcard aliases or `Include` discovery
- `ProxyJump`, `ProxyCommand`, tunnels, forwarding, or agent forwarding
- Windows remote hosts, general remote desktops, or a persistent remote Harness runtime
- automatic trust of a new host key

## Privacy and secrets

DeepSeek Harness Desktop reads host configuration needed to resolve the selected alias, but it does not read, copy, log, or commit SSH private-key contents. Authentication remains inside OpenSSH and the user's existing agent. The repository contains no real/private server address, account, workspace, private key, API key, or networked SSH fixture; examples are synthetic.

Do not place credentials directly in remote commands. Command strings, selected paths, output, and logs can become part of the local session and configured model context. Use server-side secret stores or environment setup outside the conversation.

## Verification

The deterministic SSH test suite uses a temporary fake `ssh` executable and explicitly reports `real_connections=0`. It covers all 11 tools, schema validation, endpoint pinning, configuration drift, timeouts, process identity, bounded transfers, traversal rejection, expiry, permissions, and JSON-RPC behavior. Symlink defenses are implemented in the bridge but are not yet exercised by this fake-server suite.

```bash
./scripts/test_remote_host_store.sh
./scripts/test_ssh_bridge.sh
```

Those tests do not prove that a particular real cluster accepts the selected account or provides the expected Linux tools. Make the first real connection to a non-sensitive test workspace, inspect the resolved endpoint, and start with a read-only request.

For comparison, Codex documents a broader remote-project design in [Remote connections](https://learn.chatgpt.com/docs/remote-connections). DeepSeek Harness Desktop 1.6.0 intentionally implements the smaller workflow described above.
