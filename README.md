# catcode-chatgpt-provider

A [Catalyst Code](https://github.com/catalystctl/catalyst-code) plugin that adds
**ChatGPT Plus/Pro (Codex)** as a subscription-OAuth provider. Built-in vendor
OAuth was removed from catcode core; this plugin owns the OpenAI device-code
login while catcode still owns tools, approvals, and the agent loop.

---

## What it does

| Surface | Behavior |
|---|---|
| `/login chatgpt` | Starts Codex device-code OAuth; emits verify URL + user code |
| `/oauth-code …` | Polls until approved, exchanges tokens, writes creds |
| Turn / `/models` | Plugin `token` action refreshes Bearer + `chatgpt-account-id` |
| `/logout chatgpt` | Clears `~/.config/catalyst-code/oauth/chatgpt.json` |

Harness tools (`read_file`, `bash`, approvals, …) stay on the catcode side.
The Codex wire protocol is selected by `base_url`
(`https://chatgpt.com/backend-api/codex`).

---

## Requirements

- **curl**, **jq**, **python3** (stdlib only — JWT decode)
- A ChatGPT account with Codex / Plus / Pro access
- catcode with plugin OAuth support (`oauth` manifest block)

---

## Install

### From a local checkout

```bash
# global (every workspace)
/plugin-install /path/to/catcode-chatgpt-provider

# or repo-local only
/plugin-install /path/to/catcode-chatgpt-provider workspace
```

Then:

```text
/plugin-reload
/login chatgpt
# open the printed URL, enter the user code, approve
/oauth-code done
```

### From GitHub

The repo is published at **<https://github.com/karutoil/catcode-chatgpt-provider>**.
A new release is **auto-generated on every push to `main`** (CI bumps the
patch: `v0.1.0`, `v0.1.1`, …), so the latest source zip is always available:

```bash
/plugin-install https://github.com/karutoil/catcode-chatgpt-provider
# pinned to a specific release tag:
/plugin-install karutoil/catcode-chatgpt-provider@v0.1.0
```

See the [releases page](https://github.com/karutoil/catcode-chatgpt-provider/releases)
for available versions.

### Verify

```text
/models          → Codex models tagged under [chatgpt]
/logout chatgpt  → clears stored OAuth token
```

---

## Layout

```
catcode-chatgpt-provider/
├── plugin.json              # manifest: oauth provider (chatgpt / Codex)
├── oauth/
│   └── oauth.sh             # login / complete / token / clear
├── scripts/
│   └── dry-run.sh           # offline smoke test of the OAuth contract
├── .github/workflows/
│   └── release.yml          # validate + auto-release on push to main
├── README.md
└── LICENSE
```

---

## Smoke test

```bash
bash scripts/dry-run.sh
```

Exercises `clear` / `token` / `complete` (missing pending) / unknown action
**offline** — no OpenAI network calls. CI runs the same script.

---

## Risk / ToS note

This uses OpenAI’s **public Codex CLI OAuth client**
(`app_EMoamEEZ73f0CkXaXp7hrann`) and first-party-looking headers
(`originator: codex_cli_rs`). OpenAI may change or enforce access at any time.
Prefer an API key on catcode’s built-in `openai` / `openai-api` presets when
you need a supported path.

## License

MIT
