# Fork 维护手册（release_fork）

`release_fork = 上游 master + 2 个提交`：CJK 软换行补丁 + nix 可复现构建。
日常只有一种操作：**跟进上游**（rebase，保持线性）。grammar 什么时候要动、
什么时候不用，看第 2 节。

## 0. 一键同步（推荐）

```bash
./sync-upstream.sh [-j N]
```

脚本会：检查分支干净 → 加 `upstream`（没有的话）→ fetch →
rebase 到 `upstream/master` → 看 `languages.toml` 是否波及 grammar →
`--check` lock → 过期则自动增量刷新并 `git add`。
**它从不 push**：看完结果自己 commit + 手动推。

推完等 CI 绿，nixos 侧 `nix flake update helix` + 重建验证（第 4 节）。

## 1. 手动步骤（脚本做的事，拆开看）

```bash
git remote add upstream https://github.com/helix-editor/helix.git  # 一次性
git fetch upstream
git checkout release_fork
git rebase upstream/master     # 冲突则 git rebase --abort，分支不动
git diff <old-base> HEAD -- languages.toml   # 无输出 = grammar 无关
nix run nixpkgs#python3 -- ./update-grammars.py --check
```

## 2. 什么时候必须更新 grammars

**只有**上游改了 `languages.toml` 里 `[[grammar]]` 的以下任一项时：

| 变化 | 说明 |
|---|---|
| `source.rev` 变了 | 最常见：上游升级某个 grammar |
| `source.git` 变了 | 换仓库，少见 |
| `source.subpath` 变了 | 同 repo 换子目录，少见 |
| 增删 `[[grammar]]` 段 | 新增/移除语言 |

**其他任何更新**（编辑器代码、queries、主题、版本号）都不用动 grammars，
`grammars.nix` 会对过期 lock 直接报错，不会静默用错版。

更新步骤（lock 过期时）：

```bash
nix run nixpkgs#python3 -- ./update-grammars.py -j 8   # 只拉新增/过期那几个
nix run nixpkgs#python3 -- ./update-grammars.py --check # 应显示 up to date
git add grammars.lock.json
git commit -m "nix: update grammars lock for <上游版本/说明>"
```

跟 merge 在同一个 push 里推出去就行，不必单独 push（省一次 CI 全量）。

## 3. 改动-成本速查

| 你改了什么 | CI 代价 |
|---|---|
| 只改 `.github/` | 一次 rust 编译（grammars 命中；`gitRev` 随提交变，躲不掉）|
| `languages.toml` + 同步了 lock | 全量（grammars 增量 + rust）|
| `languages.toml` 没同步 lock | CI 红（grammar-lock 秒红；全量构建也会挂）|
| `grammars.nix` / Rust 代码 | 全量 |

## 4. nixos 侧验证（冷机等价）

```bash
nix flake update helix   # dotfiles/nixos 下
HX=$(readlink -f $(which hx))
nix path-info --store https://wanten.cachix.org "$HX"   # 打印路径 = 在缓存里
for p in $(nix-store -qR $HX); do
  nix path-info --store https://wanten.cachix.org "$p" >/dev/null 2>&1 && continue
  nix path-info --store https://cache.nixos.org "$p" >/dev/null 2>&1 && continue
  echo "MISS $p"
done
```

无 MISS = 任意冷机纯下载可用。`hx --version` 的 commit 应与
`release_fork` HEAD 短 hash 一致。

## 5. 排错

* CI `tree-sitter-<x>` 报 `cannot run ssh` / submodule clone 失败 →
  该 grammar 新增了子模块，`grammars.nix` 的 `fetchSubmodules = false`
  仍适用一般不用动；若构建真需要子模块内容再个案处理。
* `hash mismatch` / 某 grammar 构建失败 → 先跑 `--check`，多半是 lock 过期。
* `cachix push` 报 `Nothing to push` 且构建失败 → 看完整日志找第一个
  `error: Cannot build`（`pipefail` 已开，这种情况 CI 会直接红）。
* `grammars.lock.json` 冲突（极少）→ 删了重跑 `update-grammars.py` 即可，
  它是纯生成文件。
