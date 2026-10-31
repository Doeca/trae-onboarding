"""Isolated native CLI login; no helper, browser, or upstream HTTP here.

The caller owns the global run lock and bounds every request in ``issue``.
The fetch guard deliberately prevents the plugin's device-bound exchange; it
is a safety condition, not proof of production enterprise compatibility.
Native Magpie persists plaintext auth inside the private isolation directory;
the orchestrator owns encrypted checkpoints and any later credential export.
"""
from __future__ import annotations

import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import time
from typing import Callable
from urllib.parse import parse_qs, urlencode, urlsplit
import uuid


PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_LIMIT = 2_000_000
AUTH_LIMIT = 8_000_000
ENTERPRISE_ORIGIN = "https://console.enterprise.trae.cn"
# Explicitly pinned machine-local executable assets, never arbitrary cache or
# session content. Upgrades require a reviewed manifest change; mismatch fails
# closed before launching any process. No automatic download/install is used.
RUNTIME_CACHE = Path("/root/.cache/magpie")
RUNTIME_ASSETS = (
    ("bun/1.4.4/magpie-bun", "10702245766b225e70bbf6235fd6b47214fd94b4760d00ffaed8ab0df57ac235", 0o700),
    ("plugin-host/host-25ef7cf0d281.js", "25ef7cf0d2813cc25a2e3675c28b5fa9ce9ec87f1b5a621803a193ab3929dbac", 0o600),
)
URL_PATTERN = re.compile(rb"https://www\.trae\.cn/authorization\?[^\s\x1b]+(?=[\s\x1b])")


class NativeMagpieError(RuntimeError):
    """A fixed, secret-free failure code; uncertain outcomes need reconcile."""


class NativeMagpie:
    def __init__(self, config_root: Path, plugin_path: Path, timeout: float = 120):
        self.root = Path(config_root).absolute()
        allowed = (PROJECT_ROOT / "tmp").resolve()
        resolved = self.root.resolve()
        if resolved == allowed or allowed not in resolved.parents:
            raise NativeMagpieError("native_config_not_isolated")
        if not math.isfinite(timeout) or timeout <= 0:
            raise NativeMagpieError("native_timeout_invalid")
        self.root = resolved
        self.plugin = Path(plugin_path).resolve()
        if self.plugin.is_dir():
            self.plugin = self.plugin / "index.mjs"
        self.timeout = timeout
        self.config = self.root / "config" / "magpie"
        self.auth_file = self.config / "plugin-auth.json"
        self._proc = None
        self._selector = None
        self._buffer = bytearray()
        self._seen = 0
        self._deadline = 0.0

    def _safe_path(self, path: Path) -> Path:
        # Never follow an artifact symlink out to the user's real config.
        if path.resolve() != path.absolute() or self.root not in path.absolute().parents:
            raise NativeMagpieError("native_artifact_not_isolated")
        return path

    def _write(self, path: Path, content: str, mode: int = 0o600) -> None:
        self._safe_path(path)
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
        fd = os.open(path, flags, mode)
        try:
            os.fchmod(fd, mode)
            with os.fdopen(fd, "w", encoding="utf-8", closefd=False) as stream:
                stream.write(content)
        finally:
            os.close(fd)

    def _prepare_runtime(self) -> Path:
        """Copy only verified code assets, not the user's cache/config state."""
        try:
            for relative, expected, mode in RUNTIME_ASSETS:
                source = RUNTIME_CACHE / relative
                destination = self._safe_path(self.root / "cache" / "magpie" / relative)
                for parent in reversed(destination.parents):
                    if self.root in parent.parents:
                        self._safe_path(parent).mkdir(mode=0o700, exist_ok=True)
                if destination.exists():
                    with destination.open("rb") as stream:
                        actual = hashlib.file_digest(stream, "sha256").hexdigest()
                    if actual != expected:
                        raise NativeMagpieError("native_runtime_integrity_failed")
                    destination.chmod(mode)
                    continue
                if source.is_symlink() or not source.is_file():
                    raise NativeMagpieError("native_runtime_missing")
                temporary = self._safe_path(destination.with_name(destination.name + ".copy"))
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
                digest = hashlib.sha256()
                try:
                    with os.fdopen(fd, "wb") as target, source.open("rb") as origin:
                        while block := origin.read(1024 * 1024):
                            self._remaining(1) if self._deadline else None
                            digest.update(block)
                            target.write(block)
                        target.flush()
                        os.fsync(target.fileno())
                    if digest.hexdigest() != expected:
                        raise NativeMagpieError("native_runtime_integrity_failed")
                    os.replace(temporary, destination)
                finally:
                    temporary.unlink(missing_ok=True)
            return self.root / "cache" / "magpie" / RUNTIME_ASSETS[0][0]
        except NativeMagpieError:
            raise
        except Exception:
            raise NativeMagpieError("native_runtime_unavailable") from None

    def _prepare(self) -> dict[str, str]:
        if not self.plugin.is_file():
            raise NativeMagpieError("native_plugin_missing")
        self.root.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.root.chmod(0o700)
        marker = self._safe_path(self.root / "native-isolation.json")
        if not marker.exists() and (self.root / "config").exists():
            raise NativeMagpieError("native_config_unmanaged")
        if marker.exists() and marker.read_text() != '{"native_isolation":1}\n':
            raise NativeMagpieError("native_config_unmanaged")
        self._write(marker, '{"native_isolation":1}\n')
        for relative in ("config", "config/magpie", "guarded-plugin", "bin", "home", "cache", "data"):
            directory = self._safe_path(self.root / relative)
            directory.mkdir(mode=0o700, exist_ok=True)
            directory.chmod(0o700)
        wrapper = self.root / "guarded-plugin"
        guard = Path(__file__).with_name("network_guard.mjs").resolve()
        # Dynamic import makes guard-before-plugin execution explicit.
        self._write(wrapper / "index.mjs", "import " + json.dumps(guard.as_uri()) + ";\n"
                    + "const original = await import(" + json.dumps(self.plugin.as_uri()) + ");\n"
                    + "export const TraeCNAuthPlugin = original.TraeCNAuthPlugin;\n"
                    + "export const TraeGlobalAuthPlugin = original.TraeGlobalAuthPlugin;\n")
        self._write(wrapper / "package.json", json.dumps({
            "name": "native-magpie-guarded-login", "type": "module", "main": "index.mjs"}))
        self._write(self.config / "plugins.json", json.dumps({"plugins": [{"spec": str(wrapper)}]}))
        for name in ("xdg-open", "gio", "sensible-browser", "x-www-browser", "open",
                     "firefox", "chromium", "chromium-browser", "google-chrome"):
            self._write(self.root / "bin" / name, "#!/bin/sh\nexit 0\n", 0o700)
        self._nonce = uuid.uuid4().hex
        self._guard_marker = self._safe_path(self.root / "guard-loaded")
        self._guard_marker.unlink(missing_ok=True)
        # Do not inherit auth, preload hooks, alternate configuration variables,
        # browser overrides, or proxy credentials from the real user environment.
        runtime = self._prepare_runtime()
        env = {k: value for k, value in os.environ.items()
               if k in ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "LARKSUITE_CLI_CONFIG_DIR")
               or k.startswith("LARK_CHANNEL")}
        env.update(MAGPIE_BUN=str(runtime), HOME=str(self.root / "home"), XDG_CONFIG_HOME=str(self.root / "config"),
                   XDG_CACHE_HOME=str(self.root / "cache"), XDG_DATA_HOME=str(self.root / "data"),
                   PATH=str(self.root / "bin") + os.pathsep + env.get("PATH", os.defpath),
                   BROWSER=str(self.root / "bin" / "xdg-open"), DISPLAY="", WAYLAND_DISPLAY="",
                   BUN_OPTIONS="", NODE_OPTIONS="", MAGPIE_NO_ACCOUNTS="1", NO_COLOR="1", TERM="dumb",
                   NATIVE_MAGPIE_GUARD_MARKER=str(self._guard_marker),
                   NATIVE_MAGPIE_GUARD_NONCE=self._nonce)
        return env

    def publish_models(self):
        from .models import publish_models
        return publish_models(self)

    def _remaining(self, cap: float = 1.0) -> float:
        remaining = self._deadline - time.monotonic()
        if remaining <= 0:
            raise NativeMagpieError("native_login_timeout")
        return min(cap, remaining)

    def _pump(self) -> None:
        for key, _ in self._selector.select(self._remaining(0.1)):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                self._selector.unregister(key.fileobj)
                continue
            self._seen += len(chunk)
            if self._seen > OUTPUT_LIMIT:
                raise NativeMagpieError("native_output_limit")
            self._buffer.extend(chunk)

    @staticmethod
    def _query(url: str) -> dict[str, list[str]]:
        try:
            outer = urlsplit(url)
            if (outer.scheme, outer.netloc, outer.path) != ("https", "www.trae.cn", "/authorization"):
                raise ValueError
            query = parse_qs(outer.query, keep_blank_values=True, max_num_fields=100)
            for key in ("device_id", "x_device_id", "login_trace_id", "auth_callback_url"):
                if len(query.get(key, [])) != 1 or not query[key][0]:
                    raise ValueError
            if query["device_id"] != query["x_device_id"]:
                raise ValueError
            callback = urlsplit(query["auth_callback_url"][0])
            if (callback.scheme != "http" or callback.hostname != "127.0.0.1"
                    or callback.path != "/authorize" or not callback.port
                    or callback.username is not None or callback.password is not None
                    or callback.query or callback.fragment):
                raise ValueError
            return query
        except Exception:
            raise NativeMagpieError("native_session_invalid") from None

    def _await_url(self) -> dict[str, list[str]]:
        while True:
            self._pump()
            match = URL_PATTERN.search(self._buffer)
            if match:
                query = self._query(match.group().decode("ascii"))
                if (not self._guard_marker.is_file()
                        or self._guard_marker.read_text() != self._nonce):
                    raise NativeMagpieError("native_guard_not_loaded")
                return query
            if self._proc.poll() is not None and not self._selector.get_map():
                raise NativeMagpieError("native_login_url_missing")

    @staticmethod
    def _pair(credentials: dict) -> tuple[str, str]:
        if not isinstance(credentials, dict):
            raise NativeMagpieError("native_credentials_invalid")
        access, refresh = credentials.get("Token"), credentials.get("RefreshToken")
        if not isinstance(access, str) or not access or not isinstance(refresh, str) or not refresh:
            raise NativeMagpieError("native_credentials_invalid")
        return access, refresh

    @staticmethod
    def _payload(query: dict[str, list[str]], issued: dict) -> dict[str, str]:
        try:
            initial, credentials, identity = (issued[k] for k in ("initial_refresh", "credentials", "identity"))
            NativeMagpie._pair(credentials)
            if not isinstance(initial["RefreshToken"], str) or not initial["RefreshToken"]:
                raise ValueError
            host, data = identity["HostInfo"], identity["Data"]
            if any(host.get(key) != ENTERPRISE_ORIGIN for key in ("Api", "Console", "Core")):
                raise ValueError
            # Reproduce captured page behavior, even though native signedIn does
            # not currently extract the nested UserInfo's uid/tenant fields.
            return {
                "scope": data["UserInfo"]["Scope"], "host": host["Api"],
                "consoleHost": host["Console"], "coreHost": host["Core"], "isRedirect": "true",
                "loginTraceID": query["login_trace_id"][0],
                "userJwt": json.dumps(credentials, separators=(",", ":")),
                "userInfo": json.dumps(data, separators=(",", ":")),
                "refreshToken": initial["RefreshToken"],
                "refreshExpireAt": str(initial["RefreshExpireAt"]), "data": initial["RefreshToken"],
                "datafinderConfig": json.dumps(host.get("DataFinderConfig", {})),
                "apmPlusConfig": json.dumps(host.get("ApmPlusConfig", {})),
            }
        except Exception:
            raise NativeMagpieError("native_callback_payload_invalid") from None

    def _callback(self, query: dict[str, list[str]], payload: dict) -> None:
        callback = urlsplit(query["auth_callback_url"][0])
        conn = http.client.HTTPConnection("127.0.0.1", callback.port, timeout=self._remaining(15))
        try:
            conn.request("GET", "/authorize?" + urlencode(payload), headers={"Connection": "close"})
            response = conn.getresponse()
            if response.status != 200:
                raise NativeMagpieError("native_callback_http_failed")
            # Do not read/log HTML. HTTP 200 is not authentication success;
            # exit status and the exact persisted pair are checked separately.
        except NativeMagpieError:
            raise
        except TimeoutError:
            code = "native_login_timeout" if time.monotonic() >= self._deadline else "native_callback_http_failed"
            raise NativeMagpieError(code) from None
        except Exception:
            raise NativeMagpieError("native_callback_http_failed") from None
        finally:
            conn.close()

    def _read_auth(self) -> dict:
        self._safe_path(self.auth_file)
        if not self.auth_file.exists():
            return {}
        try:
            with self.auth_file.open("rb") as stream:
                raw = stream.read(AUTH_LIMIT + 1)
            if len(raw) > AUTH_LIMIT:
                raise ValueError
            data = json.loads(raw)
            if not isinstance(data, dict):
                raise ValueError
            return data
        except Exception:
            raise NativeMagpieError("native_auth_unreadable") from None

    @staticmethod
    def _matches(auth: dict, pair: tuple[str, str]) -> list[tuple[str, dict]]:
        return [(key, value) for key, value in auth.items()
                if (key == "trae-cn" or key.startswith("trae-cn#"))
                and isinstance(value, dict) and value.get("type") == "oauth"
                and (value.get("access"), value.get("refresh")) == pair]

    @staticmethod
    def _result(key: str, auth: dict, identity: dict | None = None) -> dict:
        uid = auth.get("uid")
        account = auth.get("account") or {}
        tenant = account.get("TenantID") if isinstance(account, dict) else None
        result = {"account_key": key, "uid_present": bool(uid), "tenant_present": bool(tenant),
                  "guarded": True}
        if identity is not None:
            expected = identity.get("Data", {}).get("UserInfo", {})
            result.update(uid_matches=bool(uid) and str(uid) == str(expected.get("UserID", "")),
                          tenant_matches=bool(tenant) and str(tenant) == str(expected.get("TenantID", "")))
        return result

    def reconcile(self, credentials: dict) -> dict | None:
        """Find an exact issued pair after uncertain persistence, without login.

        This confirms persistence only, not a historical successful CLI exit.
        Missing identity mapping is reported, not repaired or rejected.
        """
        try:
            matches = self._matches(self._read_auth(), self._pair(credentials))
            if len(matches) > 1:
                raise NativeMagpieError("native_auth_ambiguous")
            return self._result(*matches[0]) if matches else None
        except NativeMagpieError:
            raise
        except Exception:
            raise NativeMagpieError("native_reconcile_failed") from None

    def _stop(self) -> None:
        proc = self._proc
        if proc is not None:
            # Always kill the session's process group, even if its leader has
            # exited: the plugin subprocess may still own the callback socket.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            if proc.stdin:
                proc.stdin.close()
            if proc.stdout:
                proc.stdout.close()
        if self._selector is not None:
            self._selector.close()
        self._proc = self._selector = None
        self._buffer.clear()

    def login(self, issue: Callable[[dict[str, list[str]]], dict]) -> dict:
        """Issue against this live session, deliver callback, verify fresh save.

        ``issue`` receives the actual parsed native URL query. It must return
        initial_refresh=GetRefreshToken.Data, credentials=ExchangeToken.Data,
        identity=the full GetUserInfo response, and durably checkpoint issued
        credentials before returning. It must bound its own upstream requests.
        """
        if self._proc is not None:
            raise NativeMagpieError("native_login_busy")
        self._deadline = time.monotonic() + self.timeout
        self._seen = 0
        self._buffer.clear()
        try:
            env = self._prepare()
            before = self._read_auth()
            executable = shutil.which("magpie")
            if executable is None:
                raise NativeMagpieError("native_command_missing")
            self._proc = subprocess.Popen([executable, "plugin", "login", "trae-cn"],
                env=env, cwd=self.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, start_new_session=True)
            self._selector = selectors.DefaultSelector()
            self._selector.register(self._proc.stdout, selectors.EVENT_READ)
            query = self._await_url()
            # Give the caller a copy: never allow it to redirect the callback.
            try:
                issued = issue({key: list(value) for key, value in query.items()})
            except Exception:
                raise NativeMagpieError("native_issuance_failed") from None
            self._remaining()
            payload = self._payload(query, issued)
            pair = self._pair(issued["credentials"])
            if self._matches(before, pair):
                raise NativeMagpieError("native_credentials_preexisting")
            self._callback(query, payload)
            while self._proc.poll() is None:
                self._pump()
            if self._proc.returncode != 0:
                raise NativeMagpieError("native_cli_failed")
            matches = self._matches(self._read_auth(), pair)
            if len(matches) != 1:
                raise NativeMagpieError("native_auth_not_saved" if not matches else "native_auth_ambiguous")
            key, auth = matches[0]
            if before.get(key) == auth:
                raise NativeMagpieError("native_auth_not_new")
            return self._result(key, auth, issued["identity"])
        except NativeMagpieError:
            raise
        except Exception:
            raise NativeMagpieError("native_login_failed") from None
        finally:
            self._stop()
