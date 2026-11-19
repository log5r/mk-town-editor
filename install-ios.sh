#!/bin/bash
# Build the iOS app and install it on a paired iPhone or iPad, including over the network.
# See docs/ios-device-install.md.
set -euo pipefail

usage() {
  cat <<'HELP'
使い方: ./install-ios.sh [オプション] [-- Xcodeのビルド設定...]

iOSアプリをビルドし、Xcodeでペアリング済みのiPhone・iPadへインストールします。
Xcodeで「Connect via network」を有効にした端末なら、同じネットワーク上でケーブルなしで使えます。

  --device NAME|UDID    インストール先（省略時は接続できる端末が1台ならそれを使う）
  --team TEAMID         署名する開発チーム（省略時は環境変数APPLE_TEAM_ID、
                        次にSupport/Signing.local.xcconfigなどプロジェクトの設定）
  --launch              インストール後にアプリを起動（端末のロック解除が必要）
  --list-devices        ペアリング済みの端末を一覧表示して終了
  --project PATH        .xcodeprojを指定
  --scheme NAME         スキームを指定（既定: MKTownEditorMobile）
  --app-target NAME     インストールするアプリのターゲット（複数ある場合）
  --configuration NAME  ビルド構成（既定: Release）
  --app PATH            ビルド済みの.appをインストール（ビルドを省略）
  -h, --help            この説明を表示

ビルドの全ログは .build-logs/ に保存します。xcsiftがあれば整形して表示します。
HELP
}

fail() { printf 'エラー: %s\n' "$*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null; }
absolute_dir() { (cd -- "$1" && pwd -P); }
need_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 に値が必要です。"; }

# Scheme used when --scheme is omitted.
default_scheme="MKTownEditorMobile"

script_dir="$(absolute_dir "$(dirname -- "$0")")"
project=""; scheme=""; app_target=""; configuration=Release
device_query=""; team=""; launch=false; list_only=false; source_app=""
extra_settings=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) need_value "$@"; device_query="$2"; shift 2 ;;
    --team) need_value "$@"; team="$2"; shift 2 ;;
    --launch) launch=true; shift ;;
    --list-devices) list_only=true; shift ;;
    --project) need_value "$@"; project="$2"; shift 2 ;;
    --scheme) need_value "$@"; scheme="$2"; shift 2 ;;
    --app-target) need_value "$@"; app_target="$2"; shift 2 ;;
    --configuration) need_value "$@"; configuration="$2"; shift 2 ;;
    --app) need_value "$@"; source_app="$2"; shift 2 ;;
    --) shift; extra_settings=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) fail "不明な引数: $1（--helpで使い方を表示）" ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || fail 'macOS専用です。'
command -v xcrun >/dev/null 2>&1 || fail 'xcrunがありません。Xcodeをインストールしてください。'
command -v python3 >/dev/null 2>&1 || fail 'python3がありません。Xcodeのコマンドラインツールをインストールしてください。'

# Sets source_app to an absolute path and bundle_id from an iOS app bundle.
validate_app() {
  local executable
  [[ -d "$source_app" ]] || fail ".appがありません: $source_app"
  source_app="$(absolute_dir "$source_app")"
  [[ "$source_app" == *.app ]] || fail ".appではありません: $source_app"
  [[ "$(plist "$source_app/Info.plist" :CFBundlePackageType || true)" == APPL ]] ||
    fail "iOSアプリのバンドルではありません: $source_app"
  executable="$(plist "$source_app/Info.plist" :CFBundleExecutable)" || fail 'CFBundleExecutableがありません。'
  [[ -n "$executable" && "$executable" != */* && -f "$source_app/$executable" ]] || fail 'アプリの実行ファイルがありません。'
  bundle_id="$(plist "$source_app/Info.plist" :CFBundleIdentifier)" || fail 'CFBundleIdentifierがありません。'
  [[ -n "$bundle_id" ]] || fail 'Bundle IDが空です。'
}

if [[ -n "$source_app" ]]; then
  [[ -z "$project$scheme$app_target$team" && ${#extra_settings[@]} -eq 0 && "$configuration" == Release ]] ||
    fail '--appとビルド用オプションは併用できません。'
  # Check a prebuilt app before contacting the device.
  [[ "$list_only" == true ]] || validate_app
fi
if [[ -z "$source_app" && "$list_only" == false ]]; then
  [[ -n "$team" ]] || team="${APPLE_TEAM_ID:-}"
  [[ -z "$team" || "$team" =~ ^[A-Z0-9]{10}$ ]] || fail "TEAM IDは英大文字と数字の10文字で指定してください: $team"
  # Only build-setting assignments are accepted; keep the platform and output path fixed.
  # macOS ships Bash 3.2, where expanding an empty array under nounset fails.
  if [[ ${#extra_settings[@]} -gt 0 ]]; then
    for setting in "${extra_settings[@]}"; do
      [[ "$setting" == *=* && "$setting" != -* ]] || fail "ビルド設定はKEY=VALUE形式で指定してください: $setting"
    done
  fi
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/install-ios.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Prints the selected device as "identifier<US>name<US>detail", or the device list.
# The unit separator keeps empty fields, which tab-separated read would collapse.
# Reads both the current 'properties' dictionary and the deprecated top-level fields.
select_device() {
  python3 -I - "$scratch/devices.json" "$1" "$device_query" <<'PY'
import json, sys

path, mode, query = sys.argv[1:4]
with open(path, encoding="utf-8") as file:
    entries = json.load(file).get("result", {}).get("devices", [])

devices = []
for entry in entries:
    properties = entry.get("properties") or {}
    hardware = properties.get("hardware") or entry.get("hardwareProperties") or {}
    connection = properties.get("connection") or entry.get("connectionProperties") or {}
    state = properties.get("state") or {}
    legacy = entry.get("deviceProperties") or {}
    if hardware.get("reality") != "physical" or hardware.get("platform") not in ("iOS", "iPadOS"):
        continue
    devices.append({
        "identifier": entry.get("identifier") or "",
        "udid": hardware.get("udid") or "",
        "name": state.get("name") or legacy.get("name") or "",
        "model": hardware.get("marketingName") or hardware.get("productType") or "",
        "paired": connection.get("pairingState") == "paired",
        "connection": connection.get("state") or connection.get("tunnelState") or "",
        "transport": connection.get("transportType") or "",
        "developer_mode": state.get("developerModeStatus") or legacy.get("developerModeStatus") or "",
    })

def reachable(device):
    return device["paired"] and device["connection"] != "unavailable"

def describe(device):
    if not device["paired"]:
        status = "未ペアリング"
    elif not reachable(device):
        status = "接続できません"
    elif device["transport"] == "localNetwork":
        status = "ネットワーク"
    elif device["transport"] == "wired":
        status = "USB"
    else:
        status = "接続可能"
    return f'{device["name"]}（{device["model"]}・{status}）'

def listing(items):
    return "\n".join(f'  {describe(d)}  {d["udid"] or d["identifier"]}' for d in items) or "  （なし）"

def stop(message, items=devices):
    sys.exit(f"エラー: {message}\n端末:\n{listing(items)}")

if mode == "list":
    print(listing(devices))
    sys.exit(0)

if query:
    keys = ("identifier", "udid")
    matches = [d for d in devices if query in (d[k] for k in keys) or d["name"] == query]
    if not matches:
        matches = [d for d in devices if d["name"].casefold() == query.casefold()]
    if not matches:
        stop(f"端末が見つかりません: {query}")
    if len(matches) > 1:
        stop(f"同じ名前の端末が複数あります。UDIDで指定してください: {query}", matches)
    device = matches[0]
    if not device["paired"]:
        stop(f"Xcodeでペアリングしていない端末です: {device['name']}", matches)
    if not reachable(device):
        stop(f"端末に接続できません: {device['name']}\n"
             "同じネットワークにいるか、スリープから復帰しているかを確認してください。", matches)
else:
    candidates = [d for d in devices if reachable(d)]
    if not candidates:
        stop("接続できるiPhone・iPadがありません。\n"
             "端末が同じネットワークにいること、XcodeのDevices and Simulatorsで"
             "「Connect via network」が有効なことを確認してください。")
    if len(candidates) > 1:
        stop("接続できる端末が複数あります。--deviceで指定してください。", candidates)
    device = candidates[0]

if device["developer_mode"] == "disabled":
    stop(f"デベロッパモードが無効です。端末の「設定」>「プライバシーとセキュリティ」で有効にしてください: {device['name']}",
         [device])
print("\x1f".join((device["identifier"] or device["udid"], device["name"], describe(device))))
PY
}

if ! xcrun devicectl list devices --json-output "$scratch/devices.json" >/dev/null 2>"$scratch/devicectl.err"; then
  cat -- "$scratch/devicectl.err" >&2
  fail '端末の一覧を取得できませんでした。'
fi
if [[ "$list_only" == true ]]; then
  select_device list
  exit 0
fi
IFS=$'\x1f' read -r device_id device_name device_detail < <(select_device select) || exit 1
[[ -n "$device_id" ]] || fail '端末を特定できませんでした。'
printf 'インストール先: %s\n' "$device_detail"

if [[ -z "$source_app" ]]; then
  if [[ -z "$project" ]]; then
    shopt -s nullglob
    candidates=("$script_dir/"*.xcodeproj)
    shopt -u nullglob
    [[ ${#candidates[@]} -gt 0 ]] || fail 'Xcodeプロジェクトがありません。--projectまたは--appを指定してください。'
    if [[ ${#candidates[@]} -ne 1 ]]; then
      printf '候補: %s\n' "${candidates[@]}" >&2
      fail '--projectで選択してください。'
    fi
    project="${candidates[0]}"
  fi
  project="$(absolute_dir "$project")"
  [[ -n "$scheme" ]] || scheme="$default_scheme"
  log_dir="$script_dir/.build-logs"
  mkdir -p -- "$log_dir"
  log="$log_dir/install-ios-$(date +%Y%m%d-%H%M%S)-$$.log"
  xcode_args=(-project "$project" -scheme "$scheme" -configuration "$configuration"
    -destination 'generic/platform=iOS'
    -derivedDataPath "$(dirname -- "$project")/build/InstallDerivedData-iOS"
    -allowProvisioningUpdates)
  [[ -z "$team" ]] || xcode_args+=("DEVELOPMENT_TEAM=$team")
  [[ ${#extra_settings[@]} -eq 0 ]] || xcode_args+=("${extra_settings[@]}")

  if ! xcodebuild "${xcode_args[@]}" -showBuildSettings -json > "$scratch/settings.json" 2>>"$log"; then
    printf '全ログ: %s\n' "$log" >&2
    fail 'ビルド設定を読めませんでした。--projectと--schemeを確認してください。'
  fi
  if ! python3 -I - "$scratch/settings.json" "$app_target" > "$scratch/product.txt" <<'PY'
import json, sys

path, wanted = sys.argv[1:3]
with open(path, encoding="utf-8") as file:
    targets = json.load(file)
apps = [t for t in targets
        if t.get("buildSettings", {}).get("WRAPPER_EXTENSION") == "app"
        and t.get("buildSettings", {}).get("PLATFORM_NAME") == "iphoneos"
        and (not wanted or t.get("target") == wanted)]
if len(apps) != 1:
    names = ", ".join(t.get("target", "") for t in apps) or "（なし）"
    sys.exit(f"アプリターゲット候補: {names}\nエラー: iOSアプリを1つに特定できません。--schemeと--app-targetを確認してください。")
settings = apps[0]["buildSettings"]
print("\x1f".join((settings["TARGET_BUILD_DIR"] + "/" + settings["FULL_PRODUCT_NAME"],
                 settings.get("DEVELOPMENT_TEAM", ""))))
PY
  then
    exit 1
  fi
  IFS=$'\x1f' read -r source_app project_team < "$scratch/product.txt"
  [[ -n "$project_team" ]] ||
    fail '開発チームが未設定です。--team、環境変数APPLE_TEAM_ID、またはSupport/Signing.local.xcconfigのDEVELOPMENT_TEAMで指定してください。'

  filter=(cat)
  if command -v xcsift >/dev/null 2>&1; then
    filter=(xcsift -f toon -w)
  fi
  printf 'ビルド: %s / %s\n' "$scheme" "$configuration"
  if xcodebuild "${xcode_args[@]}" build 2>&1 | tee -a "$log" | "${filter[@]}"; then
    build_status=0
  else
    build_status=$?
  fi
  printf '全ログ: %s\n' "$log"
  [[ "$build_status" -eq 0 ]] || { printf 'エラー: ビルドに失敗しました（終了コード %s）。\n' "$build_status" >&2; exit "$build_status"; }
fi

validate_app

printf 'インストール中: %s → %s\n' "$(basename -- "$source_app")" "$device_name"
xcrun devicectl device install app --device "$device_id" "$source_app" ||
  fail "インストールに失敗しました。端末のロックを解除し、ネットワーク接続を確認してください: $device_name"
printf 'インストールしました: %s（%s）\n' "$bundle_id" "$device_name"

if [[ "$launch" == true ]]; then
  xcrun devicectl device process launch --device "$device_id" --terminate-existing "$bundle_id" ||
    fail "インストールは完了しましたが、起動できませんでした。端末のロックを解除してから再度起動してください。"
  printf '起動しました: %s\n' "$bundle_id"
fi
