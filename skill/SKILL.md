---
name: local-memoryfield
description: >-
  本机 memoryfield 记忆场（~/.memoryfields/work）的读写、检索与跨机器同步：查既往工作结论、
  本机工具链事实、配置/版本历史、踩过的坑、已验证的操作流程；把新结论写成合规的 Markdown 页并同步到
  db9 hub（多机器共用同一份记忆，工具 github.com/c4pt0r/memoryfield-sync）。当用户问"上次怎么做的"
  "之前那个版本/配置是什么""你还记得…""在记忆里"、问自己的固定行程/偏好，要求记住/沉淀某条经验，或提到 memoryfield、记忆场、
  ~/.memoryfields、换机器、同步记忆时使用。
metadata:
  fields: ["work"]
---

# 本机 memoryfield（v2：跨机器同步版）

记忆场 = **扁平目录**里的 Markdown 页（一页一主题，YAML frontmatter）。
页是权威数据，无向量索引，检索走 grep。默认场 `~/.memoryfields/work`。
场里的页通过 **db9 数据库当 hub** 在多机器间双向同步。

脚本在本 skill 的 `scripts/` 下（绝对路径调用）。`scripts/mf-sync{,-schema.sql}` 是指向
`~/memoryfield-sync/`（git 仓库）的软链——**别在 skill 目录里留副本，会版本漂移**。

## 四条铁律

1. **recall 前强制同步**：答既往工作/本机工具链/用户日程偏好等事实前，先 `msearch`——它会**先跑
   `mf-sync --sync` 再 grep**（别的机器上刚写的页也能查到）。不用 `msearch`、自己 grep/awk/cat
   场里的页时，必须先手动 `mf-sync --sync`。未命中再凭印象答或重查；同步告警要告诉用户结果可能不新。
2. 产生可复用事实/踩坑/已验证流程 → `mnew` 写页，**写完 `mf-sync --sync`**（见「同步」）。
3. 结论变了**不删页**：标 `status:` + `status_reason:`，并改 `memoryfield-hub.md`。
4. 冲突不覆盖：`mf-sync` 只会把对端版本放进 `.conflicts/`，合并由你（或 agent）手工做。

## 检索

```bash
~/.agents/skills/local-memoryfield/scripts/msearch 词1 词2
~/.agents/skills/local-memoryfield/scripts/msearch --full 词1     # 带正文
```

`msearch` 开头**强制同步**：同步跑 `mf-sync --sync`（stderr 打一行结果），失败只告警、照常检索本地副本；
同一轮里连续多次检索可用 `--no-sync`（或 `MSEARCH_NO_SYNC=1`）跳过，但**每轮任务的第一次 recall 不许跳**。

`msearch` 把多词拆成多个 `-e`（OR 语义）并按命中行数排序。**绝不要**写 `grep -e "词A 词B"`
（那是一个短语，通常零命中）。只枚举有哪些页（低成本，别把全部 title+summary 灌进 context）：

```bash
mf-sync --sync                                    # 手动枚举/grep 前同样先同步
ls ~/.memoryfields/work/*.md | wc -l
awk '/^---$/{f=!f;next} f && /^(title|summary|status):/' ~/.memoryfields/work/*.md
```

未命中换更短词根（"升级"→"update"），或扫文件名：`ls ~/.memoryfields/work | grep -iE 'update|version'`。
`msearch` 只扫 `$FIELD/*.md`，所以 `.conflicts/` 子目录里的副本不会污染检索（也不会被忘掉——它在等你对账）。

## 写入

```bash
~/.agents/skills/local-memoryfield/scripts/mnew "标题" --name page-slug --summary "一句话"
```

然后编辑生成的文件填正文。`mnew` 负责 uuid、**引号包裹的 ISO 日期**、slug 文件名——
这三项最容易写错（日期不加引号会被 YAML 1.1 coerce 成 datetime 对象）。
中文标题必须显式传 `--name`；slug 只能 `^[a-z0-9]+(-[a-z0-9]+)*$`。

写入判据：只记**可复用**的事实、踩坑、已验证流程。不记一次性中间状态、不记能从
`--help`/代码重新拿到的信息。

## 同步（多机器，db9 hub）

hub 是 db9 库 `memoryfield`（`db9 status` 看账号；`db9 list` 看它存不存在）。

```bash
mf-sync                       # 只推本地改动（安全默认）
mf-sync --sync                # 双向：先拉对端改动，再推本地  ← timer 跑这个
mf-sync --check               # 本地 vs hub 一致性（服务端还会重算 body 哈希）；漂移 exit 1
mf-sync --status              # 各主机推了多少页 / tombstones / 最近 5 次 run（看 conflicts）
mf-sync --sync --dry-run      # 只看会动哪些文件
mf-sync --full                # 全量重推（schema 重建后、或 --check 报 body/sha 不一致时）
```

触发点（三层，冗余）：`mnew`/`mdream status` 结尾的钩子（即时）→ systemd user timer
`memoryfield-db9-sync.timer`（Linux，5min）或 LaunchAgent `com.c4pt0r.memoryfield-sync`（macOS，5min）。
**agent 用 edit/write 直接改页时钩子不触发**，靠定时器兜底；同一轮任务里想立刻落地就手动
`mf-sync --sync`，收尾前 `mf-sync --check` 应输出 `in sync: N pages`。

合并判定（本地 vs 祖先缓存 `<field>/.db9-sync-state.json`，hub 存 `sha256`+`updated_by`）：

| 情况 | 结果 |
|---|---|
| 本地未改、hub 改了 | 拉（覆盖本地文件） |
| 本地改了、hub 未改 | 推 |
| **两边都改** | 保留本地；对端版本写 `<field>/.conflicts/<slug>@<对方主机>.md`；`--strict` exit 1 且每次 run 重复提醒 |
| 本地删了页 | 推删除 → hub `memoryfield.pages_deleted`（带 `deleted_by`） |
| 对端删了、本地没动过 | 遵从删除：本地文件挪到 `.conflicts/<slug>@deleted.md` |
| 对端删了、本地改过 | 冲突，本地版重新推上去（复活） |

解冲突动作：`diff <field>/<slug>.md <field>/.conflicts/<slug>@<host>.md` → 手工合并进正式页
→ `mf-sync --sync`（你这版上 hub，提醒自动消失）→ 删掉 `.conflicts` 里那份副本。

想直接查 hub：

```bash
DSN=$(db9 db connect memoryfield --quiet)   # 15min 令牌，别落盘
psql "$DSN" -c "select slug,updated_by,synced_at from memoryfield.pages where field='work' order by synced_at desc limit 15;"
psql "$DSN" -c "select host,mode,ok,conflicts,note from memoryfield.sync_runs order by id desc limit 10;"
```

**检索仍然走本机 grep**；hub 是搬运工 + 备份 + 可查询审计日志，不是检索入口（db9 上 `pg_trgm` 不可用）。

## 换机器 / 新机器加入

```bash
db9 login && db9 status                       # 必须是 hosting 该库的账号
git clone git@github.com:c4pt0r/memoryfield-sync.git ~/memoryfield-sync
cd ~/memoryfield-sync && ./install.sh --db memoryfield --field ~/.memoryfields/work --hooks
mf-sync --sync                                # 空场首跑会建目录并拉下全部页
mf-sync --check
```

- **目录 basename 就是键**：两边都得叫 `work`，叫成 `mem` 就是另一套行集，互相看不见。
- 依赖：`db9`、`psql`（macOS 上 Homebrew `libpq` 是 keg-only，`/opt/homebrew/bin` 要进 PATH）、`python3`。
- `install.sh` 会写 `~/.config/memoryfield-sync/env`（`mf-sync` 自己会读它，真 env / 显式 flag 优先），
  并装定时器（Linux systemd user timer / macOS LaunchAgent；`--cron` 是兜底）。
- 坑：`HOME` 不对时 `db9` 会**静默新建匿名账号**并报 `Database 'memoryfield' not found`；
  cron/launchd 里必须显式给 `HOME`（LaunchAgent 已给）。

## 页规则

- 一页一主题，正文 ≤ 8192 字节；超了拆页，拆出的页发新 uuid、保留原来源。
- 每条事实尽量带来源 URL 或本地路径。
- 结论变化时**不要删页**：frontmatter 加
  `status: [provisional|disputed|obsolete|superseded|refuted]`（可多值）+ `status_reason` 指明替代页。
  没有 `status` 不等于结论正确。
- `index.md` 是主题说明，**禁止**当页面目录用。目录页是 `memoryfield-hub.md`，新页/作废页要同步改它。

## 校验与离线整理（dreaming）

```bash
~/.agents/skills/local-memoryfield/scripts/mdream audit    # 格式校验（首选）
~/.agents/skills/local-memoryfield/scripts/mdream dupes    # 近重复簇 = 噪声页堆积信号
~/.agents/skills/local-memoryfield/scripts/mdream stale    # 最易过期的页优先复核
~/.agents/skills/local-memoryfield/scripts/mdream status --set obsolete --reason "superseded by [[新页]]" --pages a.md,b.md
~/.agents/skills/local-memoryfield/scripts/mdream evidence 词1 词2   # 回查 transcript 当 ground truth
~/.agents/skills/local-memoryfield/scripts/mdream hub-check          # hub 漏收/死链
```

`mdream` 改页后也会自动推一版（钩子）。详见页 `memoryfield-dreaming-mdream.md`。

手写等价物（无 mdream 时）：

```bash
python3 - <<'PY'
import re,glob,os
os.chdir(os.path.expanduser("~/.memoryfields/work")); bad=0
for p in sorted(glob.glob("*.md")):
    b=open(p,"rb").read(); t=b.decode()
    if not re.fullmatch(r'[a-z0-9]+(-[a-z0-9]+)*\.md',p): print("bad name",p); bad=1
    if len(b)>8192: print("too big",p,len(b)); bad=1
    fm=t.split("---\n",2)[1] if t.startswith("---\n") else ""
    if not fm: print("no frontmatter",p); bad=1; continue
    for k in ("title","uuid","created","updated","summary"):
        if not re.search(rf"^{k}:",fm,re.M): print("missing",k,p); bad=1
    for k in ("created","updated"):
        v=re.search(rf"^{k}:\s*(.+)$",fm,re.M)
        if v and not v.group(1).strip().startswith("'"): print("unquoted date",k,p); bad=1
print("OK" if not bad else "有问题")
PY
```

## 故障排查

| 症状 | 处理 |
|---|---|
| `no such field: …` | 新机器没建场目录：`mf-sync` 会在 `$HOME` 下自动 `mkdir -p`；若父目录也不在（多半是 `--field` 打错）它会拒绝，自己 `mkdir -p` |
| `--check` 报 `body/sha256 mismatch` 或 `stored as hex string` | 老数据写法问题：`mf-sync --full` 重推一遍，再 `--check` |
| `--check` 报 `drift: local-differs=N` | 有人（或别的机器）改过又没同步：`mf-sync --sync`，必要时先看 `--sync --dry-run` |
| 日志里 `conflicts>=1` | 去 `<field>/.conflicts/` 对账合并（上面「解冲突动作」） |
| `db9 db connect failed: Database 'memoryfield' not found` | 账号不对（`db9 status`）、`HOME` 没设对（触发匿名账号）、或这台机器还没建库 |
| `psql: command not found`（macOS） | `brew install libpq` 并把 `/opt/homebrew/bin` 进 PATH |
| 想看同步历史 | `mf-sync --status`，或 `journalctl --user -u memoryfield-db9-sync.service`（Linux）/ `~/.local/state/memoryfield-sync/launchd.err.log`（macOS） |

## 规模变大后（>300 页或 grep 明显漏召回）

才考虑向量索引。`memoryfield-tool` 的 embed 层硬编码 nomic-embed-text-v1.5（走 ollama SDK），
换 bge-m3 要改 `MODEL_CODE`/`OLLAMA_MODEL` 两个常量 → 重跑 `index` → 重标 `--max-distance`
（默认 0.45 按 nomic 分布定，bge-m3 偏紧）。chat 模型不能当 embedder。
细节见页 `memoryfield-format-and-no-vector-route.md`。

## 相关记忆页

`[[memoryfield-db9-mirror-sync]]`（同步实现/合并语义/db9 SQL 坑）、`[[db9-cli-local-usage]]`、
`[[memoryfield-scripts-inventory]]`、`[[memoryfield-dreaming-mdream]]`。
