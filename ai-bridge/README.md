# rocqtui-ai-bridge

A wrapper process between rocqtui and `llama-server`. Translates
between "what the model is good at producing" (FIM completions,
unified-diff-shaped edits) and "what an editor needs to apply an
edit cleanly" (concrete buffer ranges). All quality safeguards
(anchor matching, hallucination rejection) live here, not in the
editor.

See:

- [`docs/AI_SUGGESTIONS_PLAN.md`](../docs/AI_SUGGESTIONS_PLAN.md) — overall design
- [`docs/AI_BRIDGE_PLAN.md`](../docs/AI_BRIDGE_PLAN.md) — build plan
- [`docs/AI_BRIDGE_PROTOCOL.md`](../docs/AI_BRIDGE_PROTOCOL.md) — wire format

## Run

```
# install (editable, for dev)
pip install -e '.[dev]'

# start an llama-server elsewhere with the 7B + 1.5B-draft pair, then:
ai-bridge --socket /tmp/rocqtui-ai-bridge.sock \
          --llama-url http://127.0.0.1:8080

# exercise it with the fake client:
ai-bridge-cli scenario scenarios/edits/implicit-uniform.json
ai-bridge-cli file path.v --line 42 --col 18
```

## Test

```
pytest                          # unit tests
AI_BRIDGE_E2E=1 pytest          # end-to-end tests (needs running llama-server)
```
