# Steam 与可信成绩接入状态

这是开发版本，不是已完成 Steam 验收的发行构建。

## 已编写的代码

- `scripts/steam_bridge.gd`：可选 GodotSteam 适配器，初始化、回调、SteamID/昵称、Web API 票据、按地图读取全球/附近/好友榜，账号变化事件。默认 AppID=0；禁止把 480 当正式身份。
- `server/service.py`：本机开发服务。Steam 票据验证、所有权检查、短期会话、服务端生成种子与培养快照、数据库归属约束、重复提交幂等、完整回放验证入口、全榜计算并列名次后分页、KeepBest 待上传队列。
- `scripts/replay_verify.gd`：服务端调用与客户端同一模拟器。不能上传客户端存档代替回放；客户端自报分数不参与计算。
- `server/test_service.py`：身份隔离、幂等金币、同分跨页、拒绝后封存、离线记录不能凭空建榜。

## 未完成的线上闭环

没有本游戏 AppID、Steamworks 发行权限、发布者 API 密钥或部署地址。未安装和锁定 GodotSteam 二进制，未对真实 Steam 账号运行适配器。客户端当前入口为离线玩法；适配器与后端仍需完成联调后启用在线出征和断网队列。

最终回放能够验证玩法合法性，但单靠结束时回放**不能证明客户端没有尝试多条合法分支/读档**。上线前必须增加按波提交的不可回退操作链、服务端恢复计数、失效/失败封存、服务器确认的逐波 checkpoint；这些未完成之前不要打开正式排名。培养购买也须经过服务端账本，不能同步本地可修改余额。

## 本机启动

Python 3.11+，只使用标准库：`python server/service.py`，默认监听 `127.0.0.1:8765`。`/health` 显示开发状态。

环境变量：`LC_GODOT` 指向 Godot 4.5.2 可执行文件；`LC_DB` 指向服务端数据库；`STEAM_APP_ID` 为正式应用；`STEAM_PUBLISHER_KEY` **仅存服务端**；`STEAM_BOARD_IDS` 为五个榜名到后台 ID 的 JSON 字典。部署需 HTTPS、速率限制、独立校验工作队列、超时/重启恢复和备份。

接口：POST `/v1/auth`（ticket）；POST `/v1/runs`（map）；POST `/v1/submit`（run_id, commands）；GET `/v1/leaderboard?map=0&offset=0`。后两类写请求使用 Bearer 会话。票据和密钥不打印日志。

榜单：`endless_16x16`、`endless_25x21`、`endless_37x29`、`endless_55x39`、`endless_81x49`，Descending / Numeric / Trusted。绝不从客户端调用上传分数。服务端 `upload_pending()` 是显式运维动作，默认不执行。超过 int32 时拒绝当前成绩编码并报告错误，不把它截断为错误分数。

## 发行验收仍需执行

真实 Steam 账号/好友/附近读取、头像、掉线补交与换账号存档隔离；反复恢复防作弊；Trusted 禁止客户端写入；SteamPipe 安装/升级；商店胶囊图、预告视频与实际截图；授权清单和预生成 AI 内容申报；发行费用、身份/税务/收款资料由发行方在后台办理。

官方依据：
- https://partner.steamgames.com/doc/features/auth
- https://partner.steamgames.com/doc/features/leaderboards
- https://partner.steamgames.com/doc/webapi/ISteamLeaderboards
- https://godotsteam.com/
