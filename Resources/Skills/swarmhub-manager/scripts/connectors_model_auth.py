"""The selected manager model/provider authentication a new Hermes bot receives (default-connectors.py create)."""
import copy
import json
import re

from connectors_core import ModelAuthError, location, read_config
from connectors_files import atomic_write, connector_copy, environment_values


# Deliberately explicit: never infer credential names from every *_KEY in a manager's env.
# Unknown providers fail before creation; adding one requires only a Swarm Hub update.
MODEL_ENV = {
    "openrouter": ("OPENROUTER_API_KEY", "OPENAI_API_KEY", "OPENROUTER_BASE_URL", "CUSTOM_BASE_URL"),
    "openai-api": ("OPENAI_API_KEY", "OPENAI_BASE_URL"),
    "anthropic": ("ANTHROPIC_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL"),
    "gemini": ("GOOGLE_API_KEY", "GEMINI_API_KEY", "GEMINI_BASE_URL"),
    "zai": ("GLM_API_KEY", "ZAI_API_KEY", "Z_AI_API_KEY", "GLM_BASE_URL"),
    "kimi-coding": ("KIMI_API_KEY", "KIMI_CODING_API_KEY", "KIMI_BASE_URL"),
    "minimax": ("MINIMAX_API_KEY", "MINIMAX_BASE_URL"),
    "minimax-cn": ("MINIMAX_CN_API_KEY", "MINIMAX_CN_BASE_URL"),
    "deepseek": ("DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL"),
    "xai": ("XAI_API_KEY", "XAI_BASE_URL"),
    "nvidia": ("NVIDIA_API_KEY", "NVIDIA_BASE_URL"),
    "groq": ("GROQ_API_KEY",), "mistral": ("MISTRAL_API_KEY",),
    "copilot": ("COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "COPILOT_API_BASE_URL"),
    "lmstudio": ("LM_API_KEY", "LM_BASE_URL"),
    "custom": ("OPENAI_API_KEY", "OPENAI_BASE_URL", "CUSTOM_BASE_URL"),
    "openai-codex": ("HERMES_CODEX_BASE_URL",), "nous": (), "qwen-oauth": ("HERMES_QWEN_BASE_URL",),
    "xai-oauth": ("HERMES_XAI_BASE_URL",), "minimax-oauth": (), "opencode-free": (),
}
MODEL_ALIASES = {"openai": "openrouter", "claude": "anthropic", "claude-code": "anthropic",
                 "google": "gemini", "glm": "zai", "z.ai": "zai", "grok": "xai",
                 "kimi": "kimi-coding", "moonshot": "kimi-coding", "lm-studio": "lmstudio",
                 "ollama": "custom", "vllm": "custom", "llamacpp": "custom"}


def hermes_model_auth(home, manager):
    """Build a provider-only plan, read-only, before invoking the backend.

    The documented config/auth file formats are the boundary: no Hermes imports,
    runtime credential resolution (which may refresh tokens), or backend patches.
    """
    if not manager:
        raise ModelAuthError("Hermes creation requires --manager <profile> for model authentication.")
    source = location(home, "hermes", manager)
    if not source.is_dir():
        raise ModelAuthError("The selected manager profile is missing.")
    config = read_config(source / "config.yaml")
    raw_model = config.get("model", {})
    if isinstance(raw_model, dict):
        raw_model = dict(raw_model)
        raw_model["default"] = raw_model.get("default") or raw_model.get("model")
        if isinstance(raw_model["default"], dict):
            nested = raw_model["default"]
            raw_model["default"] = nested.get("model") or nested.get("default")
            raw_model["provider"] = raw_model.get("provider") or nested.get("provider")
    model = {"default": raw_model} if isinstance(raw_model, str) else {
        key: value for key, value in raw_model.items()
        if key in ("default", "provider", "base_url", "api_key", "api", "api_mode", "extra_headers", "key_env", "api_key_env")}
    if not model.get("default"):
        raise ModelAuthError("Select a model and provider on the manager before creating a bot.")
    values = environment_values([home / ".hermes/.env", source / ".env"])
    stores = [read_config(path) for path in (home / ".hermes/auth.json", source / "auth.json") if path.is_file()]
    provider = str(model.get("provider") or "auto").strip().lower()
    provider = MODEL_ALIASES.get(provider, provider)
    if provider == "auto":
        # Avoid guessing between several provider logins. Explicit selection is stable across updates.
        candidates = {p for store in stores for p in [store.get("active_provider")] if p}
        candidates.update(p for p, names in MODEL_ENV.items() if p != "custom"
                          and any(values.get(n) for n in names if not n.endswith(("_URL", "_BASE_URL"))))
        if len(candidates) != 1:
            raise ModelAuthError("Select an explicit model provider on the manager before creating a bot.")
        provider = candidates.pop()
    if provider not in MODEL_ENV:
        raise ModelAuthError("This model provider needs a Swarm Hub credential rule before bot creation.")
    model["provider"] = provider
    model = connector_copy(model, values)
    names = MODEL_ENV[provider]
    from urllib.parse import urlparse
    hostname = urlparse(str(model.get("base_url") or "")).hostname or ""
    if provider == "custom":
        endpoint = values.get("CUSTOM_BASE_URL") or model.get("base_url") or values.get("OPENAI_BASE_URL") or ""
        hostname = urlparse(str(endpoint)).hostname or ""
        # Match the custom endpoint's credential, never an ambient OpenAI key for
        # an unrelated host. Explicit inline credentials take precedence.
        custom_key = ("OPENAI_API_KEY" if hostname == "openai.com" or hostname.endswith((".openai.com", ".openai.azure.com")) else
                      "OPENROUTER_API_KEY" if hostname == "openrouter.ai" or hostname.endswith(".openrouter.ai") else
                      "OLLAMA_API_KEY" if hostname == "ollama.com" or hostname.endswith(".ollama.com") else
                      re.sub(r"[^A-Z0-9_]", "_", hostname.split(".")[-2].upper()) + "_API_KEY"
                      if "." in hostname and not hostname.replace(".", "").isdigit() else None)
        names = ((custom_key,) if custom_key and not (model.get("api_key") or model.get("api")) else ()) + (
            "OPENAI_BASE_URL", "CUSTOM_BASE_URL")
    if provider == "anthropic" and (hostname == "azure.com" or hostname.endswith(".azure.com")):
        names = ("AZURE_ANTHROPIC_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL")
    for hint in ("api_key_env", "key_env"):
        if hint in model:
            name = model[hint]
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) or not values.get(name):
                raise ModelAuthError("The selected model credential variable is unavailable on the manager.")
            names = (name,) + names
    # Providers accept aliases in priority order; one selected key is sufficient.
    selected_key = next((name for name in names if not name.endswith(("_URL", "_BASE_URL")) and values.get(name)), None)
    selected_env = {name: values[name] for name in names if values.get(name)
                    and (name == selected_key or name.endswith(("_URL", "_BASE_URL")))}
    if provider == "custom":
        endpoint = selected_env.pop("CUSTOM_BASE_URL", None) or model.get("base_url") or selected_env.get("OPENAI_BASE_URL")
        selected_env.pop("OPENAI_BASE_URL", None)
        if endpoint:
            model["base_url"] = endpoint
        if selected_key and not (model.get("api_key") or model.get("api")):
            # Generic custom runtimes consume inline keys alongside config endpoints.
            model["api_key"] = values[selected_key]
    # Preserve per-provider shadowing from root to named profile, independently for each auth map.
    auth = {"version": 1, "active_provider": provider, "providers": {}, "credential_pool": {}}
    for store in stores:
        auth["version"] = store.get("version", auth["version"])
        for key in ("providers", "credential_pool"):
            if store.get(key, {}).get(provider):
                auth[key][provider] = copy.deepcopy(store[key][provider])
    has_auth = bool(auth["providers"] or auth["credential_pool"])
    def credential_material(value):
        if isinstance(value, dict):
            return any(isinstance(value.get(k), str) and value[k].strip()
                       for k in ("api_key", "access_token", "token", "agent_key")) or any(
                           credential_material(v) for v in value.values())
        return isinstance(value, list) and any(credential_material(v) for v in value)
    if has_auth and not credential_material(auth):
        raise ModelAuthError("The selected provider auth store has no usable model credential.")
    if provider == "openai-codex" and has_auth:
        tokens = auth["providers"].get(provider, {}).get("tokens", {})
        if not (tokens.get("access_token") and tokens.get("refresh_token")):
            raise ModelAuthError("The shared Codex model login is incomplete; sign in at Hermes' shared root first.")
    has_key = bool((provider in ("custom", "openrouter", "anthropic") and (model.get("api_key") or model.get("api"))) or any(value for key, value in selected_env.items()
                                               if not key.endswith(("_URL", "_BASE_URL"))))
    # Local compatible servers need no login. Remote custom endpoints require an explicit key.
    local = urlparse(str(selected_env.get("CUSTOM_BASE_URL") or model.get("base_url") or selected_env.get("OPENAI_BASE_URL") or
                        selected_env.get("LM_BASE_URL") or "")).hostname in ("localhost", "127.0.0.1", "::1")
    if not (has_auth or has_key or (provider in ("custom", "lmstudio") and local) or provider == "opencode-free"):
        raise ModelAuthError("The manager's selected model credentials are unavailable; sign in on the manager first.")
    def renewable(value):
        if isinstance(value, dict):
            return bool(value.get("refresh_token")) or any(renewable(v) for v in value.values())
        return isinstance(value, list) and any(renewable(v) for v in value)

    if provider in ("openai-codex", "nous", "qwen-oauth", "xai-oauth", "minimax-oauth") or renewable(auth):
        # OAuth refresh grants rotate. Keep the stock shared-root reader/writer as the
        # single owner; a local snapshot would shadow it and invalidate the manager.
        shared_path = home / ".hermes/auth.json"
        shared = read_config(shared_path) if shared_path.is_file() else {}
        if not has_auth or any(auth[key] != ({provider: shared[key][provider]}
                if shared.get(key, {}).get(provider) else {}) for key in ("providers", "credential_pool")):
            raise ModelAuthError("This OAuth login is private to the manager. Configure the selected provider at Hermes' shared root before creating a bot; refresh tokens cannot be copied safely.")
        auth = None
    return model, selected_env, auth if has_auth else None


def apply_hermes_model_auth(root, plan):
    import yaml
    model, values, auth = plan
    path = root / "config.yaml"
    config = read_config(path) if path.exists() else {}
    config["model"] = model
    atomic_write(path, yaml.safe_dump(config, sort_keys=False, allow_unicode=True))
    # Replace even a stock-seeded env: upgrades must not turn this into an entire-root-env copy.
    atomic_write(root / ".env", "".join(name + "=" + json.dumps(value, ensure_ascii=False) + "\n" for name, value in values.items()))
    if auth:
        atomic_write(root / "auth.json", json.dumps(auth) + "\n")
    elif (root / "auth.json").exists():
        (root / "auth.json").unlink()
