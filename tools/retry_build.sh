#!/usr/bin/env bash
# 构建重试器。
#
# GitHub 的 macOS runner 排队超过 15 分钟会把 job 判成 cancelled，
# 而 run 的 conclusion 仍显示 failure——没有任何步骤执行过。
# 那种失败与代码无关，只能重投。这个脚本按「有没有步骤真的跑过」区分：
#   有步骤跑过 + failure  → 真编译/打包失败，停
#   一个步骤都没跑过      → 排队超时，重投
set -u

TOKEN=$(cat /f/OpenGate/.token)
REPO=4gnyfgz2p7-ui/opengate
API=https://api.github.com/repos/$REPO
MAX=10

latest_run() {
    curl -s -H "Authorization: token $TOKEN" "$API/actions/runs?per_page=1" \
        | python -c "import sys,json;d=json.load(sys.stdin);r=d['workflow_runs'][0];print(r['id'],r['status'],r['conclusion'])"
}

ran_steps() {
    curl -s -H "Authorization: token $TOKEN" "$API/actions/runs/$1/jobs" \
        | python -c "
import sys,json
d=json.load(sys.stdin)
n=0
for j in d.get('jobs',[]):
    for s in j.get('steps',[]):
        if s.get('conclusion') in ('success','failure'): n+=1
print(n)
"
}

dispatch() {
    curl -s -X POST -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
        "$API/actions/workflows/build.yml/dispatches" -d '{"ref":"main"}' -o /dev/null -w "%{http_code}"
}

attempt=1
while [ "$attempt" -le "$MAX" ]; do
    read -r rid status conclusion <<< "$(latest_run)"
    echo "[$(date +%H:%M:%S)] try#$attempt run=$rid status=$status conclusion=$conclusion"

    if [ "$status" = "completed" ]; then
        if [ "$conclusion" = "success" ]; then
            echo "SUCCESS run=$rid"; exit 0
        fi
        steps=$(ran_steps "$rid")
        echo "  实际执行过的步骤数=$steps"
        if [ "$steps" -gt 0 ]; then
            echo "FAILURE run=$rid （有步骤跑过，属真实失败）"; exit 2
        fi
        echo "  -> 排队超时，重投 dispatch=$(dispatch)"
        attempt=$((attempt + 1))
    fi
    sleep 25
done
echo "GAVEUP"
exit 3
