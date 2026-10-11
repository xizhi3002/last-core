extends Node
# 可选的 GodotSteam 适配层，目前不代表已完成正式 Steam 接入。
# 需使用本游戏 AppID 和兼容扩展联调；客户端不在此处写入正式成绩。
## Optional GodotSteam adapter. No client score writes exist in this adapter.
## Integration must be tested with the game's assigned AppID and locked extension.
signal status_changed(message: String)
signal identity_changed(steam_id: String)
signal ticket_ready(ticket_hex: String)
signal entries_ready(entries: Array)
var api: Object
var available = false
var steam_id = "local"
var persona = "离线指挥官"
var status = "Steam 未配置"
var ticket_handle = 0
var request_mode = 0
var pending_board = ""
const BOARDS = ["endless_16x16","endless_25x21","endless_37x29","endless_55x39","endless_81x49"]

# 检查正式 AppID 和扩展是否存在；初始化成功后连接回调，否则保持离线。
func initialize(app_id: int) -> bool:
	if app_id <= 0 or app_id == 480:
		set_status("本游戏 AppID 尚未配置，保留离线玩法")
		return false
	if not Engine.has_singleton("Steam"):
		set_status("GodotSteam 扩展未安装，保留离线玩法")
		return false
	api = Engine.get_singleton("Steam")
	var result = api.call("steamInitEx",app_id,false)
	if not result is Dictionary or int(result.get("status",-1)) != 0:
		set_status("Steam 初始化失败，保留离线玩法")
		return false
	available = true
	steam_id = str(api.call("getSteamID"))
	persona = str(api.call("getPersonaName"))
	if api.has_signal("get_ticket_for_web_api"): api.connect("get_ticket_for_web_api",_ticket_callback)
	if api.has_signal("leaderboard_find_result"): api.connect("leaderboard_find_result",_board_found)
	if api.has_signal("leaderboard_scores_downloaded"): api.connect("leaderboard_scores_downloaded",_scores_downloaded)
	identity_changed.emit(steam_id)
	set_status("Steam 已连接："+persona)
	return true

# 驱动 Steam 回调；检测到切换账号时取消旧票据并要求重新初始化。
func _process(_delta):
	if not available: return
	api.call("run_callbacks")
	var current = str(api.call("getSteamID"))
	if current != steam_id:
		cancel_ticket()
		available = false
		steam_id = current
		identity_changed.emit(current)
		set_status("Steam 账号已变化，请返回主菜单重新初始化")

# 更新连接状态，同时发出信号供界面显示。
func set_status(message: String):
	status = message
	status_changed.emit(message)

# 取消旧票据并申请 Web API 身份验证票据。
func request_ticket():
	if not available: return
	cancel_ticket()
	ticket_handle = int(api.call("getAuthTicketForWebApi","lastcore"))

# 检查请求句柄和返回结果，再将票据编码为十六进制传出。
func _ticket_callback(handle: int,result: int,_size: int,buffer: PackedByteArray):
	if handle != ticket_handle or result != 1:
		set_status("Steam 票据无效")
		return
	ticket_ready.emit(buffer.hex_encode())

# 撤销当前票据并清空句柄。
func cancel_ticket():
	if ticket_handle != 0 and api != null: api.call("cancelAuthTicket",ticket_handle)
	ticket_handle = 0

# 按地图选择榜单；每次只处理一个未完成的查询。
func request_entries(map_id: int,mode: int):
	if not available or not pending_board.is_empty(): return
	if map_id < 0 or map_id >= BOARDS.size() or mode not in [0,1,2]: return
	request_mode = mode
	pending_board = BOARDS[map_id]
	api.call("findLeaderboard",pending_board)

# 找到榜单后按当前模式请求条目；找不到则清理等待状态。
func _board_found(handle: int,found: int):
	if found == 0:
		pending_board = ""
		set_status("该战区榜单尚未建立")
		return
	api.call("downloadLeaderboardEntries",-5 if request_mode == 1 else 1,5 if request_mode == 1 else 50,request_mode,handle)

# 转发原始条目；并列名次需要可信服务提供，不能直接采用原始序号。
func _scores_downloaded(_message: String,_handle: int,entries: Array):
	pending_board = ""
	# Steam raw ordinal positions are NOT presented as tied ranks. The service must
	# supply canonical ranks when a page begins in the middle of a tied score group.
	entries_ready.emit(entries)

# 退出节点时撤销未释放的身份票据。
func _exit_tree():
	cancel_ticket()
