# ---------- 生成 values.yaml ----------
_write_values_yaml(){
  local profiles_json; profiles_json="$(_render_profiles_json)"; mkdir -p ${JHUB_HOME}
  local ancestors_array csp
  # shellcheck disable=SC2206
  ancestors_array=(${JHUB_FRAME_ANCESTORS})
  csp="frame-ancestors ${ancestors_array[*]};"
  local custom_images_json; custom_images_json="$(_csv_to_json_array "${ALLOWED_CUSTOM_IMAGES}")"
  local custom_static_flag="${CUSTOM_STATIC_ENABLED}"
  if [[ "${custom_static_flag}" == "auto" ]]; then
    if [[ -d "${CUSTOM_STATIC_SOURCE_DIR}" ]] && compgen -G "${CUSTOM_STATIC_SOURCE_DIR}/*" >/dev/null; then
      custom_static_flag="true"
    else
      custom_static_flag="false"
    fi
  fi
  local custom_static_enabled_json; custom_static_enabled_json="$(_bool_to_json "${custom_static_flag}")"
  if [[ "${custom_images_json}" != "[]" ]]; then
    profiles_json=$(jq -nc --argjson base "${profiles_json}" --argjson imgs "${custom_images_json}" '
      $base + ($imgs | map({
        display_name: .,
        slug: ("custom-" + (gsub("[^A-Za-z0-9]+";"-"))),
        description: "自訂映像 " + .,
        kubespawner_override: {
          image: .,
          image_pull_policy: "IfNotPresent"
        }
      }))
    ')
  fi
  local auth_mode auth_class admin_source admin_users_json allowed_users_json allowed_users_source allow_all_json allow_all_effective
  local github_allowed_orgs_json github_scopes_json azure_allowed_tenants_json azure_scopes_json
  local azure_allowed_users_json azure_login_service hub_extra_config
  local monitor_upstream_host port_mapper_port resource_monitor_port logs_monitor_port hub_services_json
  auth_mode="${AUTH_MODE_NORMALIZED:-${AUTH_MODE,,}}"
  auth_mode="${auth_mode//[[:space:]]/}"
  hub_extra_config=""
  monitor_upstream_host="${USER_MONITOR_UPSTREAM_HOST:-${DEFAULT_HOST_IP}}"
  port_mapper_port="${PORT_MAPPER_PORT:-32001}"
  resource_monitor_port="${USER_RESOURCE_MONITOR_PORT:-32002}"
  logs_monitor_port="${USER_LOGS_MONITOR_PORT:-32003}"
  hub_services_json="$(jq -nc \
    --arg host "${monitor_upstream_host}" \
    --arg pm_port "${port_mapper_port}" \
    --arg rm_port "${resource_monitor_port}" \
    --arg lm_port "${logs_monitor_port}" \
    '{
      "port-mapper": { "url": ("http://" + $host + ":" + $pm_port) },
      "user-resource-monitor": { "url": ("http://" + $host + ":" + $rm_port) },
      "user-logs-monitor": { "url": ("http://" + $host + ":" + $lm_port) }
    }')"
  case "${auth_mode}" in
    "github")
      auth_mode="github"
      auth_class="oauthenticator.github.GitHubOAuthenticator"
      allowed_users_source="${GITHUB_ALLOWED_USERS}"
      github_allowed_orgs_json="$(_csv_to_json_array "${GITHUB_ALLOWED_ORGS}")"
      github_scopes_json="$(_csv_to_json_array "${GITHUB_SCOPES}")"
      azure_allowed_tenants_json="[]"
      azure_scopes_json="[]"
      azure_allowed_users_json="[]"
      azure_login_service="${AZUREAD_LOGIN_SERVICE}"
      ;;
    "azuread")
      auth_mode="azuread"
      auth_class="oauthenticator.azuread.AzureAdOAuthenticator"
      allowed_users_source="${AZUREAD_ALLOWED_USERS}"
      github_allowed_orgs_json="[]"
      github_scopes_json="[]"
      azure_allowed_tenants_json="$(_csv_to_json_array "${AZUREAD_ALLOWED_TENANTS}")"
      azure_scopes_json="$(_csv_to_json_array "${AZUREAD_SCOPES}")"
      azure_allowed_users_json="$(_csv_to_json_array "${AZUREAD_ALLOWED_USERS}")"
      azure_login_service="${AZUREAD_LOGIN_SERVICE}"
      ;;
    "ubilink")
      auth_mode="ubilink"
      auth_class="jupyterhub.auth.DummyAuthenticator"
      allowed_users_source="${ALLOWED_USERS_CSV}"
      github_allowed_orgs_json="[]"
      github_scopes_json="[]"
      azure_allowed_tenants_json="[]"
      azure_scopes_json="[]"
      azure_allowed_users_json="[]"
      azure_login_service="${UBILINK_LOGIN_SERVICE}"
      local ubilink_verify_json ubilink_login_url_json ubilink_login_service_json ubilink_timeout_value
      ubilink_verify_json="$(jq -Rn --arg v "${UBILINK_AUTH_ME_URL}" '$v')"
      ubilink_login_url_json="$(jq -Rn --arg v "${UBILINK_LOGIN_URL}" '$v')"
      ubilink_login_service_json="$(jq -Rn --arg v "${UBILINK_LOGIN_SERVICE}" '$v')"
      ubilink_timeout_value="${UBILINK_HTTP_TIMEOUT_SECONDS:-5}"
      hub_extra_config="$(cat <<PY
import json
from jupyterhub.auth import Authenticator
from jupyterhub.handlers.base import BaseHandler
from tornado import httpclient, web
from tornado.httputil import url_concat
from traitlets import Float, Unicode


def _hub_path_join(base_url, *parts):
    base = base_url.rstrip("/")
    extra = "/".join(p.strip("/") for p in parts if p)
    if extra:
        return f"{base}/{extra}"
    return base


class UbilinkCookieAuthenticator(Authenticator):
    login_service = Unicode(${ubilink_login_service_json}).tag(config=True)
    verify_endpoint = Unicode(${ubilink_verify_json}).tag(config=True)
    upstream_login_url = Unicode(${ubilink_login_url_json}).tag(config=True)
    http_timeout = Float(${ubilink_timeout_value}).tag(config=True)

    def login_url(self, base_url):
        return _hub_path_join(base_url, "ubilink-cookie", "login")

    def get_handlers(self, app):
        return [
            (r"/ubilink-cookie/login", UbilinkCookieLoginHandler),
        ]

    async def authenticate(self, handler, data=None):
        cookie_header = handler.request.headers.get("Cookie")
        if not cookie_header:
            self.log.info(
                "Ubilink auth missing cookie from %s",
                handler.request.remote_ip,
            )
            return None

        client = httpclient.AsyncHTTPClient()
        request = httpclient.HTTPRequest(
            url=self.verify_endpoint,
            method="GET",
            headers={
                "Cookie": cookie_header,
                "Accept": "application/json",
            },
            request_timeout=self.http_timeout,
            connect_timeout=self.http_timeout,
            follow_redirects=False,
        )

        try:
            response = await client.fetch(request)
        except httpclient.HTTPClientError as exc:
            if exc.code == 401:
                self.log.info(
                    "Ubilink auth rejected cookies from %s (401)",
                    handler.request.remote_ip,
                )
                return None
            self.log.error("Ubilink auth upstream error (%s): %s", exc.code, exc)
            raise web.HTTPError(502, "登入服務暫時無法使用，請稍後再試")
        except Exception as exc:
            self.log.exception("Ubilink auth unexpected failure")
            raise web.HTTPError(502, "登入服務暫時無法使用，請稍後再試") from exc

        try:
            payload = json.loads(response.body.decode("utf-8"))
        except Exception as exc:
            sample = response.body[:256]
            self.log.error("Ubilink auth invalid JSON: %s", sample)
            raise web.HTTPError(502, "登入服務回傳格式錯誤，請聯繫管理員") from exc

        if not payload.get("ok"):
            self.log.warning("Ubilink auth returned ok=%s", payload.get("ok"))
            return None

        username = payload.get("username")
        if not username:
            self.log.error("Ubilink auth missing username: %s", payload)
            raise web.HTTPError(502, "登入服務缺少使用者帳號，請聯繫管理員")

        auth_state = {
            "ubilink": payload,
            "email": payload.get("email"),
            "role": payload.get("role"),
        }
        return {
            "name": username,
            "auth_state": auth_state,
        }


class UbilinkCookieLoginHandler(BaseHandler):
    async def get(self):
        user = await self.login_user()
        if user:
            self.redirect(self.get_next_url(user))
            return

        upstream = self.authenticator.upstream_login_url
        if upstream:
            hub_login = _hub_path_join(self.hub.base_url, "login")
            next_arg = self.get_argument("next", "")
            if next_arg:
                hub_login = url_concat(hub_login, {"next": next_arg})
            target = url_concat(upstream, {"next": hub_login})
            self.redirect(target)
            return

        raise web.HTTPError(401, "未授權，請先登入")


c.JupyterHub.authenticator_class = UbilinkCookieAuthenticator
PY
)"
      ;;
    *)
      auth_mode="native"
      auth_class="nativeauthenticator.NativeAuthenticator"
      allowed_users_source="${ALLOWED_USERS_CSV}"
      github_allowed_orgs_json="[]"
      github_scopes_json="[]"
      azure_allowed_tenants_json="[]"
      azure_scopes_json="[]"
      azure_allowed_users_json="[]"
      azure_login_service="${AZUREAD_LOGIN_SERVICE}"
      hub_extra_config="$(cat <<'PY'
from nativeauthenticator import NativeAuthenticator
from nativeauthenticator.orm import UserInfo
import bcrypt
import secrets

def _ensure_authorized(authenticator, username):
    info = authenticator.get_user(username)
    if info is None:
        placeholder = bcrypt.hashpw(
            secrets.token_urlsafe(16).encode(), bcrypt.gensalt()
        )
        info = UserInfo(username=username, password=placeholder, is_authorized=True)
        authenticator.db.add(info)
    elif not info.is_authorized:
        info.is_authorized = True
    authenticator.db.commit()

_original_add_user = NativeAuthenticator.add_user
def _auto_add_user(self, user):
    result = _original_add_user(self, user)
    username = self.normalize_username(user.name)
    _ensure_authorized(self, username)
    return result
NativeAuthenticator.add_user = _auto_add_user

_original_change_password = NativeAuthenticator.change_password
def _auto_change_password(self, username, new_password):
    result = _original_change_password(self, username, new_password)
    if result:
        normalized = self.normalize_username(username)
        _ensure_authorized(self, normalized)
    return result
NativeAuthenticator.change_password = _auto_change_password
PY
)"
      ;;
  esac
  local usage_portal_timeout; usage_portal_timeout="$(_ensure_numeric_or_default "${USAGE_PORTAL_TIMEOUT_SECONDS}" 5 "USAGE_PORTAL_TIMEOUT_SECONDS")"
  if [[ "${ENABLE_USAGE_LIMIT_ENFORCER}" == "true" && -n "${USAGE_PORTAL_URL}" ]]; then
    local portal_url_json portal_token_json
    portal_url_json="$(jq -Rn --arg v "${USAGE_PORTAL_URL}" '$v')"
    portal_token_json="$(jq -Rn --arg v "${USAGE_PORTAL_TOKEN}" '$v')"
    local usage_limit_snippet
    usage_limit_snippet="$(cat <<PY
import json
import os
import logging
import re
from urllib.parse import urljoin
from tornado import httpclient, web

_PORTAL_URL = os.environ.get("USAGE_PORTAL_URL") or ${portal_url_json}
_PORTAL_TOKEN = os.environ.get("USAGE_PORTAL_TOKEN") or ${portal_token_json}
_LOG = logging.getLogger("jhub-usage-limits")

def _portal_timeout_value():
    raw = os.environ.get("USAGE_PORTAL_TIMEOUT")
    if raw:
        try:
            return float(raw)
        except ValueError:
            _LOG.warning("Invalid USAGE_PORTAL_TIMEOUT=%s, fallback to default", raw)
    return float(${usage_portal_timeout})


_PORTAL_TIMEOUT = _portal_timeout_value()
if _PORTAL_URL:
    _PORTAL_BASE = _PORTAL_URL.rstrip("/") + "/"
else:
    _PORTAL_BASE = ""

_MEM_SUFFIX = {
    "ki": 1.0 / 1024,
    "mi": 1.0,
    "gi": 1024.0,
    "ti": 1024.0 * 1024,
    "pi": 1024.0 * 1024 * 1024,
    "ei": 1024.0 * 1024 * 1024 * 1024,
    "k": 1.0 / 1024,
    "m": 1.0,
    "g": 1024.0,
    "t": 1024.0 * 1024,
}


def _canonical_username(value):
    return (value or "").replace(".", "-")


def _parse_cpu_cores(value):
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    if not text:
        return 0.0
    if text.endswith("m"):
        try:
            return float(text[:-1]) / 1000.0
        except ValueError:
            return 0.0
    try:
        return float(text)
    except ValueError:
        return 0.0


def _parse_mem_gib(value):
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value) / (1024 ** 3)
    text = str(value).strip()
    if not text:
        return 0.0
    lowered = text.lower()
    for suffix, ratio in _MEM_SUFFIX.items():
        if lowered.endswith(suffix):
            try:
                number = float(text[: -len(suffix)])
            except ValueError:
                return 0.0
            return (number * ratio) / 1024.0
    try:
        return float(text) / (1024 ** 3)
    except ValueError:
        return 0.0


def _safe_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _slugify(value):
    slug = re.sub(r"[^a-z0-9]+", "-", (value or "").lower()).strip("-")
    return slug or (value or "")


def _profile_override(spawner):
    user_options = getattr(spawner, "user_options", {}) or {}
    profile_slug = user_options.get("profile")
    if not profile_slug:
        return None
    profiles = getattr(spawner, "profile_list", []) or []
    for profile in profiles:
        slug = profile.get("slug") or _slugify(profile.get("display_name"))
        if slug == profile_slug or profile.get("display_name") == profile_slug:
            return profile.get("kubespawner_override") or {}
    return None


def _requested_cpu(spawner):
    cpu = _parse_cpu_cores(getattr(spawner, "cpu_limit", None) or getattr(spawner, "cpu_guarantee", None))
    if cpu <= 0:
        override = _profile_override(spawner)
        if override:
            cpu = _parse_cpu_cores(override.get("cpu_limit") or override.get("cpu_guarantee"))
    return cpu


def _requested_memory(spawner):
    memory = _parse_mem_gib(getattr(spawner, "mem_limit", None) or getattr(spawner, "mem_guarantee", None))
    if memory <= 0:
        override = _profile_override(spawner)
        if override:
            memory = _parse_mem_gib(override.get("mem_limit") or override.get("mem_guarantee"))
    return memory


def _requested_gpu(spawner):
    for attr in ("extra_resource_limits", "extra_resource_guarantees"):
        resources = getattr(spawner, attr, None) or {}
        if hasattr(resources, "items"):
            iterator = resources.items()
        else:
            iterator = []
        for key, raw in iterator:
            if key in ("nvidia.com/gpu", "gpu"):
                try:
                    value = float(raw)
                    if value > 0:
                        return value
                except (TypeError, ValueError):
                    continue
    override = _profile_override(spawner)
    if override:
        for attr in ("extra_resource_limits", "extra_resource_guarantees"):
            resources = override.get(attr) or {}
            for key, raw in (resources.items() if hasattr(resources, "items") else []):
                if key in ("nvidia.com/gpu", "gpu"):
                    try:
                        value = float(raw)
                        if value > 0:
                            return value
                    except (TypeError, ValueError):
                        continue
    return 0.0


async def _fetch_usage_limits(username):
    if not (_PORTAL_BASE and username):
        return None
    endpoint = urljoin(_PORTAL_BASE, f"users/{username}/limits")
    headers = {"Accept": "application/json"}
    if _PORTAL_TOKEN:
        headers["Authorization"] = f"Bearer {_PORTAL_TOKEN}"
    client = httpclient.AsyncHTTPClient()
    request = httpclient.HTTPRequest(
        url=endpoint,
        method="GET",
        headers=headers,
        connect_timeout=_PORTAL_TIMEOUT,
        request_timeout=_PORTAL_TIMEOUT,
        follow_redirects=False,
    )
    try:
        response = await client.fetch(request)
    except httpclient.HTTPClientError as exc:
        if exc.code != 404:
            _LOG.warning("Usage portal request failed (%s): %s", exc.code, exc)
        return None
    except Exception as exc:
        _LOG.warning("Usage portal request failed: %s", exc)
        return None
    try:
        return json.loads(response.body.decode("utf-8"))
    except Exception as exc:
        _LOG.warning("Usage portal returned invalid JSON: %s", exc)
        return None


def _limit_violation(limit_value, requested, current, label):
    if limit_value is None:
        return None
    try:
        limit_f = float(limit_value)
    except (TypeError, ValueError):
        return None
    if limit_f < 0:
        return None
    eps = 1e-9
    if requested > limit_f + eps:
        return f"{label} 超過單次限制：申請 {requested:.2f} / 上限 {limit_f:.2f}"
    if current is not None and (current + requested) > limit_f + eps:
        return f"{label} 總量超過限制：目前 {current:.2f}，本次 {requested:.2f}，上限 {limit_f:.2f}"
    return None


async def _enforce_portal_limits(spawner):
    if not _PORTAL_BASE:
        return
    username_raw = getattr(spawner.user, "name", None)
    canonical = _canonical_username(username_raw)
    if not canonical:
        return
    record = await _fetch_usage_limits(canonical)
    if not record:
        return
    usage = record.get("usage") or {}
    usage_available = bool(usage.get("available", True))
    current_cpu = _safe_float(usage.get("cpu_cores")) if usage_available else None
    current_memory = _safe_float(usage.get("memory_gib")) if usage_available else None
    current_gpu = _safe_float(usage.get("gpu")) if usage_available else None
    requested_cpu = _requested_cpu(spawner)
    requested_memory = _requested_memory(spawner)
    requested_gpu = _requested_gpu(spawner)

    _LOG.warning(
        "usage-limit check user=%s canonical=%s req_cpu=%.3f req_mem=%.3fGi req_gpu=%.3f cur_cpu=%s cur_mem=%s cur_gpu=%s lim_cpu=%s lim_mem=%s lim_gpu=%s",
        username_raw,
        canonical,
        requested_cpu,
        requested_memory,
        requested_gpu,
        current_cpu,
        current_memory,
        current_gpu,
        record.get("cpu_limit_cores"),
        record.get("memory_limit_gib"),
        record.get("gpu_limit"),
    )

    violation = _limit_violation(record.get("gpu_limit"), requested_gpu, current_gpu, "GPU")
    if violation:
        raise web.HTTPError(403, violation)
    violation = _limit_violation(record.get("cpu_limit_cores"), requested_cpu, current_cpu, "CPU 核心數")
    if violation:
        raise web.HTTPError(403, violation)
    violation = _limit_violation(record.get("memory_limit_gib"), requested_memory, current_memory, "記憶體 (GiB)")
    if violation:
        raise web.HTTPError(403, violation)


c.Spawner.pre_spawn_hook = _enforce_portal_limits

PY
)"
  if [[ -n "${hub_extra_config}" ]]; then
    hub_extra_config="${hub_extra_config}
${usage_limit_snippet}"
  else
    hub_extra_config="${usage_limit_snippet}"
  fi
  fi
  if [[ "${ENABLE_MPI_OPERATOR}" == "true" ]]; then
    local mpi_ns_prefix sa_prefix mpi_hook
    mpi_ns_prefix="${MPI_USER_NAMESPACE_PREFIX:-mpi}"
    sa_prefix="${MPI_USER_SERVICE_ACCOUNT_PREFIX:-jhub-mpi-sa}"
    mpi_hook="$(cat <<PY
sa_prefix = "${sa_prefix}"
mpi_ns_prefix = "${mpi_ns_prefix}"

def _mpi_canonical_username(raw):
    if not raw:
        return None
    import re
    name = re.sub(r'[^a-z0-9-]+', '-', str(raw).lower()).strip('-')
    name = re.sub(r'-+', '-', name)
    return name or None

_prev_pre_spawn = c.Spawner.pre_spawn_hook

async def _mpi_pre_spawn(spawner):
    if callable(_prev_pre_spawn):
        await _prev_pre_spawn(spawner)
    username = getattr(spawner.user, "name", None)
    canonical = _mpi_canonical_username(username)
    if not canonical:
        return
    sa_name = f"{sa_prefix}-{canonical}"
    spawner.service_account = sa_name
    mpi_ns = f"{mpi_ns_prefix}-{canonical}"
    spawner.environment = spawner.environment or {}
    spawner.environment.setdefault("MPI_NAMESPACE", mpi_ns)
    spawner.environment.setdefault("MPI_SERVICE_ACCOUNT", sa_name)

c.Spawner.pre_spawn_hook = _mpi_pre_spawn
PY
)"
    if [[ -n "${hub_extra_config}" ]]; then
      hub_extra_config="${hub_extra_config}
${mpi_hook}"
    else
      hub_extra_config="${mpi_hook}"
    fi
  fi
  admin_source="${ADMIN_USER}"
  if [[ -n "${ADMIN_USERS_CSV}" ]]; then
    admin_source="${ADMIN_USERS_CSV}"
  fi
  admin_users_json="$(_csv_to_json_array "${admin_source}")"
  if [[ -n "${allowed_users_source}" ]]; then
    allowed_users_json="$(_csv_to_json_array "${allowed_users_source}")"
  else
    allowed_users_json="[]"
  fi
  allow_all_effective="${ALLOW_ALL_USERS}"
  if [[ "${allowed_users_json}" != "[]" ]]; then
    allow_all_effective="false"
  fi
  allow_all_json="$(_bool_to_json "${allow_all_effective}")"
  local logo_file_path=""
  local logo_static_rel=""
  if [[ "${custom_static_flag}" == "true" && -f "${CUSTOM_STATIC_SOURCE_DIR}/${CUSTOM_STATIC_LOGO_NAME}" ]]; then
    logo_file_path="${CUSTOM_STATIC_MOUNT_PATH}/${CUSTOM_STATIC_LOGO_NAME}"
    logo_static_rel="custom/${CUSTOM_STATIC_LOGO_NAME}"
  fi
  local singleuser_node_selector_json singleuser_tolerations_json hub_node_selector_json hub_tolerations_json ingress_annotations_json
  singleuser_node_selector_json="$(_parse_json_or_default "${SINGLEUSER_NODE_SELECTOR_JSON}" "{}" "SINGLEUSER_NODE_SELECTOR_JSON")"
  singleuser_tolerations_json="$(_parse_json_or_default "${SINGLEUSER_TOLERATIONS_JSON}" "[]" "SINGLEUSER_TOLERATIONS_JSON")"
  hub_node_selector_json="$(_parse_json_or_default "${HUB_NODE_SELECTOR_JSON}" "{}" "HUB_NODE_SELECTOR_JSON")"
  hub_tolerations_json="$(_parse_json_or_default "${HUB_TOLERATIONS_JSON}" "[]" "HUB_TOLERATIONS_JSON")"
  ingress_annotations_json="$(_parse_json_or_default "${INGRESS_ANNOTATIONS_JSON}" "{}" "INGRESS_ANNOTATIONS_JSON")"
  local shared_enabled_json ingress_enabled_json prepull_enabled_json idle_enabled_json cull_users_json named_servers_json
  shared_enabled_json="$(_bool_to_json "${SHARED_STORAGE_ENABLED}")"
  local singleuser_readonly_rootfs_json; singleuser_readonly_rootfs_json="$(_bool_to_json "${SINGLEUSER_READONLY_ROOTFS}")"
  local singleuser_mount_logs_json; singleuser_mount_logs_json="$(_bool_to_json "${SINGLEUSER_MOUNT_JHUB_LOGS}")"
  ingress_enabled_json="$(_bool_to_json "${ENABLE_INGRESS}")"
  prepull_enabled_json="$(_bool_to_json "${PREPULL_IMAGES}")"
  idle_enabled_json="$(_bool_to_json "${ENABLE_IDLE_CULLER}")"
  cull_users_json="$(_bool_to_json "${CULL_USERS}")"
  named_servers_json="$(_bool_to_json "${ALLOW_NAMED_SERVERS}")"
  local usage_limits_enabled_json; usage_limits_enabled_json="$(_bool_to_json "${ENABLE_USAGE_LIMIT_ENFORCER}")"
  local prepull_extra_json; prepull_extra_json="$(_csv_to_json_array "${PREPULL_EXTRA_IMAGES}")"
  local cull_timeout; cull_timeout="$(_ensure_numeric_or_default "${CULL_TIMEOUT_SECONDS}" 3600 "CULL_TIMEOUT_SECONDS")"
  local cull_every; cull_every="$(_ensure_numeric_or_default "${CULL_EVERY_SECONDS}" 300 "CULL_EVERY_SECONDS")"
  local cull_concurrency; cull_concurrency="$(_ensure_numeric_or_default "${CULL_CONCURRENCY}" 10 "CULL_CONCURRENCY")"
  local named_limit; named_limit="$(_ensure_numeric_or_default "${NAMED_SERVER_LIMIT}" 5 "NAMED_SERVER_LIMIT")"
  local singleuser_image_components singleuser_image_registry singleuser_image_repo singleuser_image_tag singleuser_image_digest singleuser_image_name
  singleuser_image_components="$(_split_image_components "${SINGLEUSER_IMAGE}")"
  IFS='|' read -r singleuser_image_registry singleuser_image_repo singleuser_image_tag singleuser_image_digest <<< "${singleuser_image_components}"
  if [[ -n "${singleuser_image_registry}" ]]; then
    singleuser_image_name="${singleuser_image_registry}/${singleuser_image_repo}"
  else
    singleuser_image_name="${singleuser_image_repo}"
  fi
  local hub_image_components hub_image_registry hub_image_repo hub_image_tag hub_image_digest hub_image_name
  hub_image_components="$(_split_image_components "${HUB_IMAGE}")"
  IFS='|' read -r hub_image_registry hub_image_repo hub_image_tag hub_image_digest <<< "${hub_image_components}"
  if [[ -n "${hub_image_registry}" ]]; then
    hub_image_name="${hub_image_registry}/${hub_image_repo}"
  else
    hub_image_name="${hub_image_repo}"
  fi
  local proxy_image_components proxy_image_registry proxy_image_repo proxy_image_tag proxy_image_digest proxy_image_name
  proxy_image_components="$(_split_image_components "${PROXY_IMAGE}")"
  IFS='|' read -r proxy_image_registry proxy_image_repo proxy_image_tag proxy_image_digest <<< "${proxy_image_components}"
  if [[ -n "${proxy_image_registry}" ]]; then
    proxy_image_name="${proxy_image_registry}/${proxy_image_repo}"
  else
    proxy_image_name="${proxy_image_repo}"
  fi
  local treat_as_single_node="true"
  if _cluster_enabled; then
    treat_as_single_node="false"
  else
    local node_count
    node_count=$(_k8s_node_count)
    if (( node_count > 1 )); then
      treat_as_single_node="false"
    fi
  fi
  local resolved_pull_policy="${SINGLEUSER_IMAGE_PULL_POLICY}"
  if [[ "${resolved_pull_policy}" == "IfNotPresent" && "${treat_as_single_node}" == "true" ]]; then
    local docker_prefixed_image="docker.io/${SINGLEUSER_IMAGE}"
    if _image_exists_locally "${SINGLEUSER_IMAGE}" || _image_exists_locally "${docker_prefixed_image}"; then
      resolved_pull_policy="Never"
      log "[images] 偵測到 ${SINGLEUSER_IMAGE} 已在本地，將 singleuser image pullPolicy 改為 Never"
    fi
  fi
  SINGLEUSER_IMAGE_PULL_POLICY="${resolved_pull_policy}"
  local resolved_hub_pull_policy="${HUB_IMAGE_PULL_POLICY}"
  if [[ "${resolved_hub_pull_policy}" == "IfNotPresent" && "${treat_as_single_node}" == "true" ]]; then
    local docker_prefixed_hub="docker.io/${HUB_IMAGE}"
    if _image_exists_locally "${HUB_IMAGE}" || _image_exists_locally "${docker_prefixed_hub}"; then
      resolved_hub_pull_policy="Never"
      log "[images] 偵測到 ${HUB_IMAGE} 已在本地，將 hub image pullPolicy 改為 Never"
    fi
  fi
  HUB_IMAGE_PULL_POLICY="${resolved_hub_pull_policy}"
  local resolved_proxy_pull_policy="${PROXY_IMAGE_PULL_POLICY}"
  if [[ "${resolved_proxy_pull_policy}" == "IfNotPresent" && "${treat_as_single_node}" == "true" ]]; then
    local docker_prefixed_proxy="docker.io/${PROXY_IMAGE}"
    if _image_exists_locally "${PROXY_IMAGE}" || _image_exists_locally "${docker_prefixed_proxy}"; then
      resolved_proxy_pull_policy="Never"
      log "[images] 偵測到 ${PROXY_IMAGE} 已在本地，將 proxy image pullPolicy 改為 Never"
    fi
  fi
  PROXY_IMAGE_PULL_POLICY="${resolved_proxy_pull_policy}"
  jq -n \
    --arg singleuser_image_name "${singleuser_image_name}" \
    --arg singleuser_image_tag "${singleuser_image_tag}" \
    --arg singleuser_image_digest "${singleuser_image_digest}" \
    --arg singleuser_image_pull_policy "${SINGLEUSER_IMAGE_PULL_POLICY}" \
    --arg hub_image_name "${hub_image_name}" \
    --arg hub_image_tag "${hub_image_tag}" \
    --arg hub_image_digest "${hub_image_digest}" \
    --arg hub_image_pull_policy "${HUB_IMAGE_PULL_POLICY}" \
    --arg proxy_image_name "${proxy_image_name}" \
    --arg proxy_image_tag "${proxy_image_tag}" \
    --arg proxy_image_digest "${proxy_image_digest}" \
    --arg proxy_image_pull_policy "${PROXY_IMAGE_PULL_POLICY}" \
    --arg pvc "${PVC_SIZE}" \
    --arg singleuser_storage_type "${SINGLEUSER_STORAGE_TYPE}" \
    --arg singleuser_home_mount_path "${SINGLEUSER_HOME_MOUNT_PATH}" \
    --arg singleuser_ephemeral_request "${SINGLEUSER_EPHEMERAL_STORAGE_REQUEST}" \
    --arg singleuser_ephemeral_limit "${SINGLEUSER_EPHEMERAL_STORAGE_LIMIT}" \
    --arg storage_class "${SINGLEUSER_STORAGE_CLASS}" \
    --arg shared_storage_mount "/workspace/storage" \
    --arg logs_mount "/var/log/jupyter" \
    --arg csp "$csp" \
    --arg auth_class "${auth_class}" \
    --arg auth_mode "${auth_mode}" \
    --arg github_client_id "${GITHUB_CLIENT_ID}" \
    --arg github_client_secret "${GITHUB_CLIENT_SECRET}" \
    --arg github_callback "${GITHUB_CALLBACK_URL}" \
    --arg azuread_client_id "${AZUREAD_CLIENT_ID}" \
    --arg azuread_client_secret "${AZUREAD_CLIENT_SECRET}" \
    --arg azuread_callback "${AZUREAD_CALLBACK_URL}" \
    --arg azuread_tenant_id "${AZUREAD_TENANT_ID}" \
    --arg azuread_login_service "${azure_login_service}" \
    --arg host "${INGRESS_HOST}" \
    --arg tls_secret "${INGRESS_TLS_SECRET}" \
    --arg hub_extra_config "${hub_extra_config}" \
    --arg custom_static_name "${CUSTOM_STATIC_CONFIGMAP}" \
    --arg custom_static_mount "${CUSTOM_STATIC_MOUNT_PATH}" \
    --arg custom_logo_file "${logo_file_path}" \
    --arg custom_logo_rel "${logo_static_rel}" \
    --argjson admin_users ${admin_users_json} \
    --argjson allowed_users ${allowed_users_json} \
    --argjson custom_static_enabled ${custom_static_enabled_json} \
    --argjson allow_all ${allow_all_json} \
    --argjson github_allowed_orgs ${github_allowed_orgs_json} \
    --argjson github_scopes ${github_scopes_json} \
    --argjson azuread_allowed_tenants ${azure_allowed_tenants_json} \
    --argjson azuread_scopes ${azure_scopes_json} \
    --argjson azuread_allowed_users ${azure_allowed_users_json} \
    --argjson port ${NODEPORT_FALLBACK_PORT} \
    --argjson profiles "${profiles_json}" \
    --argjson http_to ${SPAWNER_HTTP_TIMEOUT} \
    --argjson start_to ${KUBESPAWNER_START_TIMEOUT} \
    --argjson singleuser_node_selector ${singleuser_node_selector_json} \
    --argjson singleuser_tolerations ${singleuser_tolerations_json} \
    --argjson hub_node_selector ${hub_node_selector_json} \
    --argjson hub_tolerations ${hub_tolerations_json} \
    --argjson ingress_annotations ${ingress_annotations_json} \
    --argjson shared_enabled ${shared_enabled_json} \
    --argjson singleuser_readonly_rootfs ${singleuser_readonly_rootfs_json} \
    --argjson singleuser_mount_logs ${singleuser_mount_logs_json} \
    --argjson ingress_enabled ${ingress_enabled_json} \
    --argjson prepull_enabled ${prepull_enabled_json} \
    --argjson prepull_extra ${prepull_extra_json} \
    --argjson idle_enabled ${idle_enabled_json} \
    --argjson cull_timeout ${cull_timeout} \
    --argjson cull_every ${cull_every} \
    --argjson cull_concurrency ${cull_concurrency} \
    --argjson cull_users ${cull_users_json} \
    --argjson named_servers ${named_servers_json} \
    --argjson named_limit ${named_limit} \
	    --arg usage_portal_url "${USAGE_PORTAL_URL}" \
	    --arg usage_portal_token "${USAGE_PORTAL_TOKEN}" \
	    --argjson usage_portal_timeout "${usage_portal_timeout}" \
	    --argjson usage_limits_enabled ${usage_limits_enabled_json} \
	    --argjson hub_services "${hub_services_json}" '
{
  "proxy": {
    "service": { 
      "type": "NodePort", 
      "nodePorts": { "http": $port } 
    },
    "chp": {
      "image": (
        {
          "name": $proxy_image_name,
          "pullPolicy": $proxy_image_pull_policy
        }
        | (if ($proxy_image_tag | length) > 0 then . + { "tag": $proxy_image_tag } else . end)
        | (if ($proxy_image_digest | length) > 0 then . + { "digest": $proxy_image_digest } else . end)
      )
    }
  },
  "ingress": (
    if $ingress_enabled then 
      {
        "enabled": true,
        "hosts": [{ "host": $host, "paths": [{ "path": "/", "pathType": "Prefix" }] }],
        "annotations": $ingress_annotations,
        "tls": (
          if ($tls_secret | length) > 0 then 
            [{ "hosts": [$host], "secretName": $tls_secret }] 
          else 
            [] 
          end
        )
      } 
    else 
      { "enabled": false } 
    end
  ),
  "prePuller": (
    if $prepull_enabled then 
      {
        "hook": { "enabled": true },
        "continuous": { "enabled": true }
      } 
    else 
      { 
        "hook": { "enabled": false }, 
        "continuous": { "enabled": false } 
      } 
    end
  ),
  "singleuser": {
    "image": (
      {
        "name": $singleuser_image_name,
        "pullPolicy": $singleuser_image_pull_policy
      }
      | (if ($singleuser_image_tag | length) > 0 then . + { "tag": $singleuser_image_tag } else . end)
      | (if ($singleuser_image_digest | length) > 0 then . + { "digest": $singleuser_image_digest } else . end)
    ),
    "storage": {
      "type": $singleuser_storage_type,
      "homeMountPath": $singleuser_home_mount_path,
      "dynamic": (
        if $singleuser_storage_type == "dynamic" then
          { "storageClass": $storage_class }
        else
          {}
        end
      ),
      "capacity": (if $singleuser_storage_type == "dynamic" then $pvc else null end),
      "extraVolumes": (
        (if $singleuser_readonly_rootfs then
          [
            { "name": "tmp", "emptyDir": {} },
            { "name": "run", "emptyDir": {} }
          ]
        else [] end)
        + (
          if $shared_enabled then
            [
              { "name": "shared-storage", "persistentVolumeClaim": { "claimName": "storage-local-pvc" } }
            ]
          else []
          end
        )
        + (
          if $singleuser_mount_logs then
            [
              { "name": "jhub-logs", "persistentVolumeClaim": { "claimName": "jhub-logs-pvc" } }
            ]
          else []
          end
        )
      ),
      "extraVolumeMounts": (
        (if $singleuser_readonly_rootfs then
          [
            { "name": "tmp", "mountPath": "/tmp" },
            { "name": "run", "mountPath": "/run" }
          ]
        else [] end)
        + (
          if $shared_enabled then
            [
              { "name": "shared-storage", "mountPath": $shared_storage_mount, "subPathExpr": "$(JUPYTERHUB_USER)" }
            ]
          else []
          end
        )
        + (
          if $singleuser_mount_logs then
            [
              { "name": "jhub-logs", "mountPath": $logs_mount }
            ]
          else []
          end
        )
      )
    },
    "extraPodConfig": (
      if $shared_enabled then
        {
          "initContainers": [
            {
              "name": "prepare-shared-workspace",
              "image": "quay.io/jupyterhub/k8s-network-tools:4.2.0",
              "command": [
                "/bin/sh",
                "-c",
                "set -euo pipefail; ROOT=/shared-root; mkdir -p \"$ROOT/$JUPYTERHUB_USER\"; chmod 0770 \"$ROOT/$JUPYTERHUB_USER\" || true"
              ],
              "env": [
                {
                  "name": "JUPYTERHUB_USER",
                  "value": "{escaped_username}"
                }
              ],
              "securityContext": {
                "runAsUser": 0
              },
              "volumeMounts": [
                { "name": "shared-storage", "mountPath": "/shared-root" }
              ]
            }
          ]
        }
      else
        {}
      end
    ),
    "nodeSelector": $singleuser_node_selector,
    "extraTolerations": $singleuser_tolerations,
    "profileList": $profiles,
    "extraEnv": (
      {
        "GRANT_SUDO": "yes"
      }
      + (if ($singleuser_home_mount_path | length) > 0 then { "HOME": $singleuser_home_mount_path } else {} end)
    ),
    "allowPrivilegeEscalation": true
  },
	  "hub": {
    "image": (
      {
        "name": $hub_image_name,
        "pullPolicy": $hub_image_pull_policy
      }
      | (if ($hub_image_tag | length) > 0 then . + { "tag": $hub_image_tag } else . end)
      | (if ($hub_image_digest | length) > 0 then . + { "digest": $hub_image_digest } else . end)
    ),
    "db": {
      "type": "sqlite-pvc",
      "pvc": {
        "accessModes": ["ReadWriteOnce"],
        "storage": "1Gi"
      }
    },
	    "templatePaths": ["/usr/local/share/jupyterhub/custom_templates"],
	    "services": $hub_services,
	    "nodeSelector": $hub_node_selector,
	    "tolerations": $hub_tolerations,
	    "config": (
      {
        "JupyterHub": (
          {
            "admin_access": true,
            "authenticator_class": $auth_class,
            "allow_named_servers": $named_servers,
            "named_server_limit_per_user": $named_limit,
            "tornado_settings": {
              "headers": {
                "Content-Security-Policy": $csp,
                "X-Frame-Options": "ALLOWALL"
              }
            }
          }
          | (if $custom_static_enabled then . + { "extra_static_paths": [$custom_static_mount] } else . end)
          | (if ($custom_logo_file | length) > 0 then . + { "logo_file": $custom_logo_file } else . end)
          | (if ($custom_logo_rel | length) > 0 then . + { "template_vars": { "custom_logo_rel": $custom_logo_rel } } else . end)
        ),
        "Authenticator": (
          {
            "admin_users": $admin_users
          }
          | (if ($allowed_users | length) > 0 then . + { "allowed_users": $allowed_users } else . end)
          | (if $allow_all then . + { "allow_all": true } else . end)
        ),
        "Spawner": {
          "http_timeout": $http_to,
          "start_timeout": $start_to,
          "args": [
            "--ServerApp.tornado_settings={\"headers\":{\"Content-Security-Policy\":\"" + $csp + "\"}}"
          ]
        }
      }
      + (if ($singleuser_ephemeral_request | length) > 0 or ($singleuser_ephemeral_limit | length) > 0 or $singleuser_readonly_rootfs then
          {
            "KubeSpawner": (
              {}
              | (if $singleuser_readonly_rootfs then . + { "container_security_context": { "readOnlyRootFilesystem": true } } else . end)
              | (if ($singleuser_ephemeral_request | length) > 0 then . + { "extra_resource_guarantees": { "ephemeral-storage": $singleuser_ephemeral_request } } else . end)
              | (if ($singleuser_ephemeral_limit | length) > 0 then . + { "extra_resource_limits": { "ephemeral-storage": $singleuser_ephemeral_limit } } else . end)
            )
          }
        else {} end)
      + (if $auth_mode == "native" then
          {
            "NativeAuthenticator": {
              "open_signup": true,
              "minimum_password_length": 6
            }
          }
        else {} end)
      + (if $auth_mode == "github" then
          {
            "GitHubOAuthenticator": (
              {
                "client_id": $github_client_id,
                "client_secret": $github_client_secret
              }
              | (if ($github_callback | length) > 0 then . + { "oauth_callback_url": $github_callback } else . end)
              | (if ($github_allowed_orgs | length) > 0 then . + { "allowed_organizations": $github_allowed_orgs } else . end)
              | (if ($github_scopes | length) > 0 then . + { "scope": $github_scopes } else . end)
            )
          }
        else {} end)
      + (if $auth_mode == "azuread" then
          {
            "AzureAdOAuthenticator": (
              {
                "client_id": $azuread_client_id,
                "client_secret": $azuread_client_secret,
                "tenant_id": $azuread_tenant_id
              }
              | (if ($azuread_callback | length) > 0 then . + { "oauth_callback_url": $azuread_callback } else . end)
              | (if ($azuread_allowed_tenants | length) > 0 then . + { "allowed_tenants": $azuread_allowed_tenants } else . end)
              | (if ($azuread_allowed_users | length) > 0 then . + { "allowed_users": $azuread_allowed_users } else . end)
              | (if ($azuread_scopes | length) > 0 then . + { "scope": $azuread_scopes } else . end)
              | (if ($azuread_login_service | length) > 0 then . + { "login_service": $azuread_login_service } else . end)
            )
          }
        else {} end)
    ),
    "extraEnv": (
      if $usage_limits_enabled and ($usage_portal_url | length) > 0 then
        {
          "USAGE_PORTAL_URL": $usage_portal_url,
          "USAGE_PORTAL_TOKEN": $usage_portal_token,
          "USAGE_PORTAL_TIMEOUT": ($usage_portal_timeout | tostring)
        }
      else
        {}
      end
    ),
    "extraVolumes": (
      [
        { "name": "hub-templates", "configMap": { "name": "hub-templates" } }
      ]
      + (
        if $custom_static_enabled then
          [
            { "name": $custom_static_name, "configMap": { "name": $custom_static_name } }
          ]
        else
          []
        end
      )
    ),
    "extraVolumeMounts": (
      [
        { "name": "hub-templates", "mountPath": "/usr/local/share/jupyterhub/custom_templates", "readOnly": true }
      ]
      + (
        if $custom_static_enabled then
          [
            { "name": $custom_static_name, "mountPath": $custom_static_mount, "readOnly": true }
          ]
        else
          []
        end
      )
    ),
    "extraConfig": (
      if ($hub_extra_config | length) > 0 then
        { "01-auto-approve.py": $hub_extra_config }
      else
        {}
      end
    )
  },
  "cull": {
    "enabled": $idle_enabled,
    "timeout": $cull_timeout,
    "every": $cull_every,
    "concurrency": $cull_concurrency,
    "users": $cull_users
  }
}' > ${JHUB_HOME}/values.yaml
  nl -ba ${JHUB_HOME}/values.yaml | sed -n '1,200p' || true
}

_deploy_portal_page(){
  local preferred_url="$1" nodeport_url="$2" pf_url="$3" admin_url="$4" pf_active="$5"
  local root_dir="${JHUB_HOME}" template_path output_path portal_config portal_label pf_status
  mkdir -p "$root_dir"

  [[ -z "$preferred_url" ]] && preferred_url="$nodeport_url"
  [[ -z "$admin_url" ]] && admin_url=""
  [[ -z "$pf_url" ]] && pf_url=""

  if [[ "$pf_active" == "true" ]]; then
    portal_label="Port-Forward 入口（建議）"
    pf_status="已啟動"
  else
    portal_label="NodePort 入口"
    pf_status="未啟動"
  fi

  template_path="${SCRIPT_DIR:-$(pwd)}/index.html"
  output_path="${root_dir}/index.html"
  if [[ -f "$template_path" ]]; then
    cp "$template_path" "$output_path"
  else
    cat >"$output_path" <<'HTML'
<!DOCTYPE html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8" />
  <title>JupyterHub 快速入口</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Noto+Sans+TC:wght@400;600&display=swap">
  <style>
    body { font-family: "Noto Sans TC", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; background: #f5f7fb; color: #1f2933; }
    header { background: #1f6feb; color: #fff; padding: 24px 32px; }
    main { padding: 24px 32px 40px; max-width: 1080px; margin: 0 auto; }
    .card { background: #fff; border-radius: 12px; box-shadow: 0 12px 32px rgba(15,23,42,0.1); padding: 28px; margin-bottom: 24px; }
    .btn { display: inline-flex; align-items: center; padding: 12px 20px; margin: 6px 14px 6px 0; border-radius: 10px; text-decoration: none; font-weight: 600; transition: all .2s ease; }
    .btn-primary { background: #1f6feb; color: #fff; }
    .btn-secondary { background: #e2e8f0; color: #1f2933; }
    .btn[aria-disabled="true"] { opacity: .6; pointer-events: none; }
    iframe { width: 100%; min-height: 640px; border: 1px solid #d0d7de; border-radius: 12px; }
    code { background: #f1f5f9; padding: 2px 6px; border-radius: 6px; }
    .tag { display: inline-flex; align-items: center; padding: 4px 10px; border-radius: 999px; font-size: 12px; background: #dbeafe; color: #1d4ed8; margin-left: 8px; }
    .grid { display: grid; gap: 18px; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); }
    footer { text-align: center; padding: 16px; font-size: 13px; color: #6b7280; }
  </style>
</head>
<body>
  <header>
    <h1>JupyterHub 快速入口</h1>
    <p>此模板可置於任意 HTTP 伺服器，部署腳本會自動更新 portal-config.js 供下方連結使用。</p>
  </header>
  <main>
    <section class="card">
      <h2>主要入口 <span class="tag" data-text="preferredLabel">載入中</span></h2>
      <p>依照目前的部署狀態，自動指向最適合的 Hub 入口；若無法載入，請改用 NodePort 連結。</p>
      <p>網址：<code data-text="preferredUrl">讀取中…</code></p>
      <a class="btn btn-primary" data-href="preferredUrl" target="_blank" rel="noopener" aria-disabled="true">前往 Hub</a>
    </section>
    <section class="card">
      <h3>其他連線方式</h3>
      <div class="grid">
        <div>
          <h4>NodePort 入口</h4>
          <p>直接連到 Proxy 的 NodePort。</p>
          <p><code data-text="nodePortUrl">讀取中…</code></p>
          <a class="btn btn-secondary" data-href="nodePortUrl" target="_blank" rel="noopener" aria-disabled="true">開啟 NodePort</a>
        </div>
        <div>
          <h4>Port-Forward</h4>
          <p>若執行 port-forward，這裡會顯示本機入口。</p>
          <p>狀態：<span class="tag" data-text="portForwardStatus">偵測中</span></p>
          <p><code data-text="portForwardUrl">尚未設定</code></p>
          <a class="btn btn-secondary" data-href="portForwardUrl" target="_blank" rel="noopener" aria-disabled="true">開啟 Port-Forward</a>
        </div>
        <div>
          <h4>adminuser 服務</h4>
          <p>由 adminuser Notebook 暴露的服務（NodePort）。</p>
          <p><code data-text="adminServiceUrl">讀取中…</code></p>
          <a class="btn btn-secondary" data-href="adminServiceUrl" target="_blank" rel="noopener" aria-disabled="true">開啟 adminuser</a>
        </div>
      </div>
    </section>
    <section class="card">
      <h3>即時預覽</h3>
      <p>此 iframe 會嵌入主要入口（需搭配 CSP frame-ancestors 設定）。</p>
      <iframe data-iframe="preferredUrl" title="JupyterHub"></iframe>
    </section>
  </main>
  <footer>由 install_jhub.sh 產生；詳細設定請查看 portal-config.js</footer>
  <script src="portal-config.js"></script>
  <script>
    (function(){
      const data = window.JUPYTER_PORTAL || {};
      const textElements = document.querySelectorAll('[data-text]');
      textElements.forEach(el => {
        const key = el.getAttribute('data-text');
        const value = data[key];
        if (value) {
          el.textContent = value;
        } else if (key === 'portForwardUrl') {
          el.textContent = '尚未啟動';
        } else {
          el.textContent = '未設定';
        }
      });
      document.querySelectorAll('[data-href]').forEach(el => {
        const key = el.getAttribute('data-href');
        const value = data[key];
        if (value) {
          el.href = value;
          el.setAttribute('aria-disabled', 'false');
          el.style.pointerEvents = '';
          el.style.opacity = '';
        } else {
          el.href = '#';
          el.setAttribute('aria-disabled', 'true');
          el.style.pointerEvents = 'none';
          el.style.opacity = '0.6';
        }
      });
      const iframe = document.querySelector('[data-iframe="preferredUrl"]');
      if (iframe && data.preferredUrl) {
        iframe.src = data.preferredUrl;
      }
    })();
  </script>
</body>
</html>
HTML
  fi

  portal_config="${root_dir}/portal-config.js"
  cat >"$portal_config" <<JS
window.JUPYTER_PORTAL = {
  preferredUrl: "${preferred_url}",
  preferredLabel: "${portal_label}",
  nodePortUrl: "${nodeport_url}",
  portForwardUrl: "${pf_url}",
  portForwardActive: ${pf_active:-false},
  portForwardStatus: "${pf_status}",
  adminServiceUrl: "${admin_url}",
  generatedAt: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
};
JS

  # 讓工作目錄下的 HTTP server 也能讀到最新設定
  cp "$portal_config" "$(pwd)/portal-config.js" || true
}

_install_custom_templates(){
  local repo_template_dir="${SCRIPT_DIR:-$(pwd)}/templates"
  local repo_login_template="${repo_template_dir}/login.html"
  local repo_page_template="${repo_template_dir}/page.html"
  local target_dir="${JHUB_HOME}/templates"
  local target_file="${target_dir}/login.html"
  local logo_static_path="images/jupyterhub-80.png"

  if [[ "${CUSTOM_STATIC_ENABLED}" == "true" && -f "${LOGIN_LOGO_PATH}" ]]; then
    logo_static_path="custom/${CUSTOM_STATIC_LOGO_NAME}"
  fi

  mkdir -p "$target_dir"

  if [[ -f "${repo_page_template}" ]]; then
    cp "${repo_page_template}" "${target_dir}/page.html"
  fi

  if [[ -f "$repo_login_template" ]]; then
    cp "$repo_login_template" "$target_file"
  else
    cat <<'HTML' >"$target_file"
{% extends "page.html" %}

{% block stylesheet %}
<style>
:root {
  color-scheme: light;
  font-family: "Noto Sans TC", "Segoe UI", system-ui, sans-serif;
}
body {
  margin: 0;
  min-height: 100vh;
  background: linear-gradient(160deg, #0f172a 0%, #1e293b 38%, #e2e8f0 100%);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 32px 16px;
  color: #0f172a;
}
.login-wrapper {
  display: grid;
  grid-template-columns: minmax(0, 480px) minmax(0, 320px);
  gap: 28px;
  width: min(1040px, 100%);
}
.login-card {
  background: rgba(255, 255, 255, 0.96);
  border-radius: 24px;
  box-shadow: 0 30px 70px rgba(15, 23, 42, 0.35);
  padding: 42px 48px;
  display: flex;
  flex-direction: column;
  gap: 24px;
  backdrop-filter: blur(10px);
}
.brand {
  display: flex;
  align-items: center;
  gap: 18px;
}
.brand img {
  width: 52px;
  height: 52px;
  object-fit: contain;
}
.brand h1 {
  margin: 0;
  font-size: 30px;
  font-weight: 700;
  color: #0f172a;
}
.brand p {
  margin: 6px 0 0;
  color: #475569;
  font-size: 15px;
}
.intro {
  margin: 0;
  line-height: 1.7;
  color: #334155;
  font-size: 15px;
}
.alert {
  margin: 0;
  padding: 12px 16px;
  border-radius: 12px;
  font-size: 14px;
  line-height: 1.5;
}
.alert.error { background: #fee2e2; color: #b91c1c; }
.alert.info { background: #dbeafe; color: #1d4ed8; }
.oauth-button,
.submit-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 14px 20px;
  border-radius: 999px;
  border: none;
  background: #1d4ed8;
  color: #fff;
  font-weight: 600;
  font-size: 15px;
  text-decoration: none;
  cursor: pointer;
  transition: background 0.2s ease;
}
.oauth-button:hover,
.submit-btn:hover {
  background: #1e40af;
}
.login-form {
  display: grid;
  gap: 18px;
}
.field {
  display: grid;
  gap: 8px;
}
.field label {
  font-weight: 600;
  color: #1f2937;
}
.field input {
  border-radius: 12px;
  border: 1px solid #cbd5f5;
  padding: 12px 14px;
  font-size: 15px;
  transition: border-color 0.2s ease, box-shadow 0.2s ease;
}
.field input:focus {
  border-color: #2563eb;
  box-shadow: 0 0 0 3px rgba(37, 99, 235, 0.18);
  outline: none;
}
.footnotes {
  font-size: 12px;
  color: #64748b;
  border-top: 1px dashed #e2e8f0;
  padding-top: 16px;
}
.highlights {
  background: rgba(15, 23, 42, 0.85);
  color: #e2e8f0;
  border-radius: 24px;
  padding: 36px;
  display: flex;
  flex-direction: column;
  gap: 18px;
  box-shadow: 0 24px 60px rgba(15, 23, 42, 0.45);
}
.highlights h2 {
  margin: 0;
  font-size: 24px;
}
.highlights p {
  margin: 0;
  line-height: 1.7;
  color: #cbd5f5;
  font-size: 14px;
}
.highlights ul {
  margin: 0;
  padding-left: 22px;
  display: grid;
  gap: 10px;
  font-size: 14px;
  color: #e2e8f0;
}
.highlights li::marker {
  color: #60a5fa;
}
@media (max-width: 980px) {
  body { padding: 20px; }
  .login-wrapper { grid-template-columns: 1fr; }
  .highlights { display: none; }
}
</style>
{% endblock %}

{% block main %}
{% set fallback_logo = static_url('images/jupyterhub-80.png') %}
{% set primary_logo = custom_logo_rel if custom_logo_rel else 'images/jupyterhub-80.png' %}
<div class="login-wrapper">
  <section class="login-card">
    <header class="brand">
      <img src="{{ static_url(primary_logo) }}" alt="JupyterHub"
           onerror="this.onerror=null;this.src={{ fallback_logo | tojson }};" />
      <div>
        <h1>JupyterHub 工作臺</h1>
        <p>個人化的研究與開發環境，集中管理 GPU / CPU 資源。</p>
      </div>
    </header>

    <p class="intro">請先登入以啟動 Notebook、布署應用程式，或管理團隊資源。首次使用請向管理員申請權限。</p>
    {% if message or login_error %}
    <div class="alert error" role="alert" aria-live="polite">{{ message or login_error }}</div>
    {% endif %}

    <a class="oauth-button" role="button" href="{{ authenticator_login_url or login_url }}">使用 {{ login_service if login_service else 'OAuth' }} 登入</a>
  </section>

  <aside class="highlights">
    <div>
      <h2>平台特色</h2>
      <p>JupyterHub 為團隊提供安全、可擴充的機器學習與資料分析工作流。</p>
    </div>
    <ul>
      <li>彈性 GPU / CPU profiles，依需求啟動環境</li>
      <li>共享儲存與自動備援，保護重要成果</li>
      <li>支援 OAuth / Azure AD / 內建帳號多種認證</li>
      <li>Notebook 與 API 快速部署，整合外部服務</li>
    </ul>
  </aside>
</div>
{% endblock %}
HTML
  fi

  local -a template_args=() template_names=()
  if compgen -G "${target_dir}/*.html" >/dev/null; then
    while IFS= read -r -d '' template_file; do
      local base
      base="$(basename "${template_file}")"
      template_args+=(--from-file="${base}=${template_file}")
      template_names+=("${base}")
    done < <(find "${target_dir}" -maxdepth 1 -type f -name '*.html' -print0)
    if ((${#template_args[@]})); then
      log "[templates] 套用自訂模板：${template_names[*]}"
      kapply_from_dryrun "${JHUB_NS}" configmap hub-templates "${template_args[@]}"
    else
      warn "[templates] 目錄 ${target_dir} 未找到可用模板檔案"
    fi
  else
    warn "[templates] 目錄 ${target_dir} 無任何模板檔案"
  fi

  if [[ "${CUSTOM_STATIC_ENABLED}" == "true" ]]; then
    if [[ -d "${CUSTOM_STATIC_SOURCE_DIR}" ]] && compgen -G "${CUSTOM_STATIC_SOURCE_DIR}/*" >/dev/null; then
      local custom_static_dir="${JHUB_HOME}/custom-static"
      rm -rf "${custom_static_dir}"
      mkdir -p "${custom_static_dir}"
      cp -a "${CUSTOM_STATIC_SOURCE_DIR}/." "${custom_static_dir}/"
      local -a file_args=() file_names=()
      while IFS= read -r -d '' file; do
        local base
        base="$(basename "$file")"
        file_args+=(--from-file="${base}=${custom_static_dir}/${base}")
        file_names+=("$base")
      done < <(find "${custom_static_dir}" -maxdepth 1 -type f -print0)
      if ((${#file_args[@]})); then
        log "[custom] 套用自訂靜態資源：${file_names[*]}"
        kapply_from_dryrun "${JHUB_NS}" configmap "${CUSTOM_STATIC_CONFIGMAP}" "${file_args[@]}"
      else
        warn "[custom] 自訂靜態資源目錄 ${CUSTOM_STATIC_SOURCE_DIR} 無檔案，略過"
      fi
    else
      warn "[custom] CUSTOM_STATIC_ENABLED=true 但找不到任何檔案於 ${CUSTOM_STATIC_SOURCE_DIR}"
    fi
  fi
}
