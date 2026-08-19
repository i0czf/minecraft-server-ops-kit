# Windows 玩家更新器 · CMD 闪退与 9009

玩家双击 Windows 更新入口时，常见有两类「看起来像脚本坏了」的情况。更新服务是否在跑是另一件事。

## 1. 双击窗口一闪就没

`portable-windows-sync.bat` 必须是 **UTF-8 无 BOM + CRLF**。`chcp 65001` 之后，CMD 用 LF 读含多字节的行会错位，把内嵌 PowerShell 拆成 CMD 命令，窗口立刻关掉。

发布和打包会拒绝混用 LF 的 `.bat/.cmd`：

- `portable-publish.ps1` 拷贝工具批处理前检查换行
- `zip-with-unix-mode.py` 打玩家包时同样检查

已经闪退的老包，热更新走不到（自刷新写在会崩的那份 bat 里）。不要为此重打完整客户端。用 `tools/build-windows-repair-kit.ps1` 打一份几 KB 的修复小包：解压后放到整合包根目录，双击「修复更新脚本-Windows端.bat」，换掉 `_updater\Windows-sync.bat` 后再走正常更新。

新打的完整包 / 规范导入包根目录只保留「更新mod-Windows端.bat」，不再放「修复」入口。

## 2. 退出码 9009

9009 是 Windows CMD 的「找不到命令」，不是同步器内部错误。

8 月起 Windows 入口会优先走 Python。只看 `where python` / `where py` 不够：Windows 商店「应用执行别名」会让 `where` 成功，真正一跑却是空壳。

现逻辑：

1. 先试跑 `py -3 -c "import sys"`，不行再试 `python -c "import sys"`
2. 过不了就走 PowerShell
3. 即便误进了 Python 路径，退出码 9009 也会回落 PowerShell

没有 Python、或装的是正规解释器的机器不受影响。

## 3. 玩家怎么拿新入口

- 旧入口还能跑、更新源可达：再跑一次会热刷新 `Windows-sync.bat`
- 旧入口已经闪退：用上面的独立修复小包
- 新完整包：直接跑根目录「更新mod-Windows端.bat」
