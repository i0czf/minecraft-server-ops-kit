# QQ 群模组发布事务管理器

这是一个“先验证、再变更、可回退”的模组发布链路。QQ 桥接程序只接收受信群的 `group_upload` 事件并写入入站信封；真正的下载、JAR 校验、双端替换、玩家更新发布和回滚由独立的 Python 管理器完成。当前生产配置由管理员手动接管服务端生命周期：管理器不自动停服、不自动起服。

## 默认状态

`tools/ops-config.json` 中的 `modRelease` 默认是：

```json
{
  "enabled": false,
  "mode": "observe",
  "manageServerLifecycle": false,
  "sourceGroupIds": [],
  "publisherIds": []
}
```

这是刻意的安全闸门：JAR 是可执行代码，不能因为任何人往群里上传文件就直接执行。没有明确的来源群和发布者白名单时，管理器会保持停用。

## 启用顺序

1. 先填写实际的发布群号和发布者 QQ 号：

   ```json
   "enabled": true,
   "mode": "observe",
   "sourceGroupIds": ["发布群号"],
   "publisherIds": ["发布者QQ号"],
   "notifyGroupIds": ["接收日志的群号"]
   ```

   `notifyGroupIds` 可留空；留空时沿用 `qq.groupId` 的主群列表。

2. 重启运维监控，使 QQ 桥和管理器读取新配置。先保持 `observe`，它只会下载、校验并生成发布记录，不会停服或改 `mods`。

3. 在 QQ 群上传一个测试 JAR，确认 `backups/mod-releases/releases/<releaseId>/release.json` 中的 mod ID、版本和 SHA-256 都正确。

4. 确认无误后，才把 `mode` 改成 `auto`。当前生产仍保持 `manageServerLifecycle=false`：事务会替换服务端/主客户端模组并执行「仅发布更新」，但不会执行 `save-all`、RCON `stop`、wrapper 起服或发布后健康等待。新服务端 JAR 要到群主或管理员手动停服并重启后才会被 NeoForge 加载。

## 自动事务

自动模式每次只处理一组候选文件：

1. 校验来源群、上传者、文件名、JAR ZIP/CRC 和 NeoForge/Fabric 元数据。
2. 扫描当前 `mods/*.jar`，按 mod ID 匹配，再用版本号和 SHA-256 判断是更新、重复、降级还是歧义。
3. 保存当前服务端/客户端模组快照和发布源快照。
4. 当 `manageServerLifecycle=true` 时，才通过 RCON `save-all flush`、`stop` 安全停服，原子写入新 JAR，并按配置起服健康检查。
5. 当前生产的 `manageServerLifecycle=false` 分支只原子写入新 JAR、执行「仅发布更新」并提交记录；不创建停服 hold，不自动起服。运行中的 JVM 不会热加载新模组，必须由群主或管理员手动重启。

所有发布对象和旧文件都保存在 `backups/mod-releases/`，不是只依赖当前 `mods` 目录。

没有 NeoForge/Fabric 描述文件的辅助 JAR 会被记录为“不可识别”并原样保留；它们不会被自动替换，上传的新文件也必须有可读元数据。

## 崩溃与回滚

提交后管理器继续监视 `crash-reports`。发现当前发布提交时间之后的新崩溃报告时，会：

- 在 QQ 发送失败原因；
- 生成脱敏诊断包并上传；
- 设置 hold、停止服务端；
- 恢复该发布前的模组快照；
- 重新启动并再次通过 `Done + RCON` 检查；
- 将失败 SHA-256 加入熔断表，避免同一个坏包反复部署。

如果文件被运行中的 JVM/其他程序占用，替换或回滚会失败并保留事务审计；手动生命周期模式不会替管理员停服，需要先人工停服后依据 `release.json` 和 `tmp/mod-release/state.json` 处理。自动生命周期模式下，停服或回滚失败会保留 hold，服务端不会被强杀或继续重启。

## 当前生产操作顺序

1. 可信发布者把 ZIP/JAR 发到白名单群。
2. 群主/管理员引用文件并发送升级指令；校验通过后管理器替换双端文件并执行「仅发布更新」。
3. 玩家下次运行更新脚本时拿到新客户端模组。
4. 需要让线上服务端加载新模组时，由群主/管理员手动停服，再手动启动服务端。

这条链路的“发布成功”只代表文件和更新源已提交，不代表运行中的服务端 JVM 已经加载新模组。

## 常用只读检查

```powershell
python tools\mod-release-manager.py --inventory
python tools\mod-release-manager.py --config tools\ops-config.json --once --dry-run
```

发布记录：`backups/mod-releases/releases/`；对象仓库：`backups/mod-releases/objects/`；管理器日志：`logs/mod-release.log`。

## 边界

当前版本以“白名单 + 元数据 + SHA-256 + 健康门禁”为上线依据，还没有引入发布者签名或隔离影子服。若要把自动模式用于不完全信任的发布者，下一步应增加签名 manifest/公钥轮换，并在独立测试实例先启动验证。
