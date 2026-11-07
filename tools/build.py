"""推送 → 等构建 → 拉产物到 _local，全程自动重试。

GitHub 在这边的连接经常 502 / 超时，所以每一步都带退避重试：
- push  最多 5 次
- 轮询  网络错误不算失败，继续等
- 下载  先走 API 资产的 302 直链，失败换 releases/download 直链，都带断点续传
用法：python tools/build.py [--skip-push]
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

OWNER, REPO = "4gnyfgz2p7-ui", "opengate"
ROOT = r"F:/OpenGate"
TOKEN = open(os.path.join(ROOT, ".token"), encoding="ascii").read().strip()
LOCAL = os.path.join(ROOT, "_local")
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.github+json",
    "User-Agent": "acamera-build",
}


def api(path):
    req = urllib.request.Request(f"https://api.github.com{path}", headers=HEADERS)
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.loads(response.read().decode() or "{}")


def retry(fn, attempts=5, delay=6, label=""):
    last = None
    for index in range(attempts):
        try:
            return fn()
        except Exception as error:  # noqa: BLE001
            last = error
            print(f"  [{label}] 第 {index + 1} 次失败：{error}")
            time.sleep(delay * (index + 1))
    raise last


def push():
    script = os.path.join(os.environ.get("TEMP", "."), "ac_push.py")
    for index in range(5):
        result = subprocess.run([sys.executable, script], capture_output=True, text=True)
        if result.returncode == 0 and "推送成功" in result.stdout:
            print("  推送成功")
            return
        print(f"  推送失败（第 {index + 1} 次）：{result.stderr.strip().splitlines()[-1:] or result.stdout.strip()[-120:]}")
        time.sleep(8 * (index + 1))
    raise SystemExit("推送重试 5 次仍失败，检查网络或令牌")


def wait_for_build(timeout=1500, since=None):
    """等最新一次运行。since 是推送时间，用来排除推送前就已完成的旧运行。"""
    deadline = time.time() + timeout
    seen = None
    since_epoch = None
    if since is not None:
        since_epoch = since - 30
    while time.time() < deadline:
        try:
            runs = api("/repos/%s/%s/actions/runs?per_page=1" % (OWNER, REPO))["workflow_runs"]
            run = runs[0]
        except Exception as error:  # noqa: BLE001
            print(f"  查询失败（{error}），10 秒后重试")
            time.sleep(10)
            continue

        if since_epoch is not None:
            created = run["created_at"].replace("Z", "+00:00")
            from datetime import datetime
            if datetime.fromisoformat(created).timestamp() < since_epoch:
                time.sleep(8)
                continue

        if run["head_sha"][:7] != seen:
            seen = run["head_sha"][:7]
            print(f"  运行 {seen} 状态 {run['status']}")
        if run["status"] == "completed":
            print(f"  结论：{run['conclusion']}")
            return run
        time.sleep(12)
    raise SystemExit("等待构建超时")


def latest_asset():
    release = retry(lambda: api(f"/repos/{OWNER}/{REPO}/releases/tags/latest"), label="release")
    asset = release["assets"][0]
    return asset


def download(asset, target):
    size = asset["size"]
    if os.path.exists(target) and os.path.getsize(target) == size:
        print("  已有同尺寸文件，跳过下载")
        return target

    api_url = f"https://api.github.com/repos/{OWNER}/{REPO}/releases/assets/{asset['id']}"
    direct = f"https://github.com/{OWNER}/{REPO}/releases/download/latest/{asset['name']}"

    # 第一条通道：API 302 直链
    try:
        request = urllib.request.Request(api_url, headers={**HEADERS, "Accept": "application/octet-stream"})
        opener = urllib.request.build_opener(type("NoRedirect", (urllib.request.HTTPRedirectHandler,), {
            "redirect_request": lambda *a, **k: None
        }))
        try:
            opener.open(request, timeout=30)
            location = api_url
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location", api_url)
        if location and location != api_url:
            _curl(location, target, size)
            return target
    except Exception as error:  # noqa: BLE001
        print(f"  API 通道失败：{error}")

    # 第二条通道：直接下 releases/download
    print("  改用 releases/download 直链")
    _curl(direct, target, size)
    return target


def _curl(url, target, size):
    for index in range(4):
        result = subprocess.run(
            ["curl", "-sS", "-L", "--retry", "5", "--retry-all-errors", "--retry-delay", "4",
             "-C", "-", "--max-time", "600", "-o", target, url],
            capture_output=True, text=True,
        )
        if result.returncode == 0 and os.path.exists(target) and os.path.getsize(target) == size:
            print(f"  下载完成：{size} 字节")
            return
        print(f"  下载失败（第 {index + 1} 次）：{result.stderr.strip()[-120:]}")
        time.sleep(5 * (index + 1))
    raise SystemExit("下载重试 4 次仍失败")


def main():
    if "--skip-push" not in sys.argv:
        print("1) 推送")
        push()
        started = time.time()
        time.sleep(15)
    else:
        started = None

    print("2) 等待构建")
    run = wait_for_build(since=started)
    if run["conclusion"] != "success":
        raise SystemExit("构建失败，先跑 ac_logs.py 看错误")

    print("3) 取产物")
    asset = latest_asset()
    with open(os.path.join(ROOT, "project.yml"), encoding="utf-8") as handle:
        version = handle.read()
    tag = "dev"
    for line in version.splitlines():
        if "MARKETING_VERSION" in line:
            tag = line.split('"')[1]
            break
    os.makedirs(LOCAL, exist_ok=True)
    target = os.path.join(LOCAL, f"OpenGate-{tag}.ipa")
    download(asset, target)
    print(f"4) 就绪：{target}（{os.path.getsize(target)} 字节）")


if __name__ == "__main__":
    main()
