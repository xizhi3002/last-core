extends Control
# 游戏入口和界面控制器：负责页面、输入、音效及调用模拟器。
# 战斗规则在 simulation.gd 中；界面刷新不应自行改变伤害或寻路结果。
const Simulation = preload("res://scripts/simulation.gd")
const Storage = preload("res://scripts/storage.gd")
const Board = preload("res://scripts/board.gd")
var sim = Simulation.new()
var store = Storage.new()
var board
var page: Control
var overlay: Control
var hud: Dictionary = {}
var mobile = OS.has_feature("android") or "--mobile" in OS.get_cmdline_user_args()
var touch_mode = "build"
var screen = "menu"
var chosen_map = 0
var chosen_loadout: Array = ["rail","ember","mortar","arc","lance","frost"]
var selected = "rail"
var speed = 0.5
var paused = false
var elapsed = 0.0
var countdown = 5.0
var refresh = 0.0
var toast_label: Label
var toast_time = 0.0
var moving: Array = []
var checkpoint: Dictionary = {}
# 待确认命令只保存在界面层；确认前不扣费、不移动原建筑。
var draft: Dictionary = {}
var focused_cell = Vector2i(-1,-1)
var draft_error = ""
var panel_body: VBoxContainer
var tactical_panel: PanelContainer
var tactical_toggle: Button
var inspect_panel_open = false
var palette_drag = false
var palette_start = Vector2.ZERO
var palette_id = ""
var palette_suppress = false
var settled_amount = 0
var anim = 0.0
var audio_player: AudioStreamPlayer
var audio_buffer
var audio_phase = 0.0
var beep_left = 0
var beep_frequency = 440.0
var font: Font
const MINT = Color("6ce5c5")
const MUTED = Color("8597a9")
const GOLD = Color("ebc683")

# 初始化字体、主题、音频和主菜单；命令行参数可进入截图或导出验证流程。
func _ready():
	get_tree().auto_accept_quit = false
	get_tree().quit_on_go_back = false
	if mobile:
		get_window().content_scale_size = Vector2i(960,540)
		Engine.max_fps = 60
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI","Microsoft YaHei","Noto Sans CJK SC","Arial"])
	if mobile and ResourceLoader.exists("res://assets/fonts/NotoSansSC.ttf"):
		var mobile_font = FontVariation.new()
		mobile_font.base_font = load("res://assets/fonts/NotoSansSC.ttf")
		mobile_font.variation_opentype = {"weight":400.0}
		font = mobile_font
	var t = Theme.new()
	t.default_font = font
	t.default_font_size = 18 if mobile else 15
	t.set_color("font_color","Label",Color("dce9ef"))
	t.set_color("font_color","Button",Color("c9dae5"))
	t.set_color("font_hover_color","Button",Color("ffffff"))
	t.set_color("font_disabled_color","Button",Color("506171"))
	t.set_stylebox("normal","Button",style(Color("142632"),Color("2c4353"),7))
	t.set_stylebox("hover","Button",style(Color("203e49"),Color("6ce5c5"),7))
	t.set_stylebox("pressed","Button",style(Color("315a5c"),Color("9fffe0"),7))
	t.set_stylebox("disabled","Button",style(Color("111e28"),Color("20333f"),7))
	t.set_stylebox("normal","OptionButton",style(Color("192b3b"),Color("334e60"),6))
	t.set_stylebox("hover","OptionButton",style(Color("26404d"),MINT,6))
	t.set_stylebox("normal","LineEdit",style(Color("10212c"),Color("3a5264"),6))
	t.set_stylebox("panel","PanelContainer",style(Color("101f2b"),Color("243c4a"),10))
	t.set_stylebox("background","ProgressBar",style(Color("273340"),Color.TRANSPARENT,4))
	t.set_stylebox("fill","ProgressBar",style(MINT,Color.TRANSPARENT,4))
	t.set_constant("separation","VBoxContainer",10)
	t.set_constant("separation","HBoxContainer",10)
	theme = t
	setup_audio()
	show_menu()
	if "--capture" in OS.get_cmdline_user_args(): capture_demo.call_deferred()
	if "--release-smoke" in OS.get_cmdline_user_args(): release_smoke.call_deferred()
	if store.error != "": toast(store.error)

# 生成共用的控件背景样式，统一边框、圆角和内边距。
func style(bg: Color,border: Color,radius: int) -> StyleBoxFlat:
	var box = StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 14
	box.content_margin_right = 14
	box.content_margin_top = 9
	box.content_margin_bottom = 9
	return box

# 创建实时音频流，用程序生成提示音；无窗口测试时跳过音频。
func setup_audio():
	if DisplayServer.get_name() == "headless": return
	audio_player = AudioStreamPlayer.new()
	var stream = AudioStreamGenerator.new()
	stream.mix_rate = 22050
	stream.buffer_length = 0.1
	audio_player.stream = stream
	add_child(audio_player)
	audio_player.play()
	audio_buffer = audio_player.get_stream_playback()

# 退出场景时释放音频缓冲并停止播放。
func _exit_tree():
	audio_buffer = null
	if is_instance_valid(audio_player): audio_player.stop()

# 设置下一次提示音的频率和剩余采样数。
func sound(freq = 660.0):
	beep_left = 1600
	beep_frequency = freq

# 向音频缓冲写入正弦波采样，末尾降低振幅以减轻爆音。
func fill_audio():
	if audio_buffer == null: return
	var frames = audio_buffer.get_frames_available()
	for i in frames:
		var v = 0.0
		if beep_left > 0:
			v = sin(audio_phase)*0.12*float(store.data.settings.volume)*minf(1.0,beep_left/400.0)
			beep_left -= 1
			audio_phase += TAU*beep_frequency/22050.0
		audio_buffer.push_frame(Vector2(v,v))

# 累积帧时间并按固定步长推进战斗；界面刷新和波间倒计时分别处理。
func _process(delta):
	anim += delta
	fill_audio()
	if screen != "game": queue_redraw()
	if toast_label != null and is_instance_valid(toast_label):
		toast_time -= delta
		toast_label.visible = toast_time > 0
	if screen != "game" or sim.s.is_empty(): return
	if sim.s.state == "battle" and not paused:
		# 限制单帧补时和最多模拟步数，防止窗口卡顿后长时间补算导致继续卡顿。
		elapsed += minf(delta,0.25)*speed
		var steps = 0
		while elapsed >= Simulation.STEP and steps < 24:
			elapsed -= Simulation.STEP
			sim.step()
			steps += 1
			if sim.s.state != "battle":
				on_wave_end()
				break
	elif sim.s.state == "intermission" and overlay == null and not paused:
		countdown -= delta
		if countdown <= 0: start_wave()
	refresh += delta
	if refresh > 0.12:
		refresh = 0
		update_hud()

# 拦截关闭窗口事件，先保存出征再退出。
func _notification(what):
	if what == NOTIFICATION_APPLICATION_PAUSED:
		save_run()
		if screen == "game":
			paused = true
			if board != null: board.reset_touches()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if screen == "game":
			if not draft.is_empty():
				cancel_draft()
				return
			if sim.s.state not in ["reward","shop","ended"]:
				if overlay != null: close_modal()
				else: show_pause()
		elif overlay != null: close_modal()
		elif screen != "menu": show_menu()
		else: show_mobile_exit()
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_run()
		quit_game()

# 停止音频后稍作等待，再结束程序。
func quit_game():
	audio_buffer = null
	if is_instance_valid(audio_player): audio_player.stop()
	await get_tree().create_timer(0.15).timeout
	get_tree().quit()

# 处理未被控件消费的快捷键；弹窗打开时阻止战场快捷操作。
func _unhandled_key_input(event):
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_ESCAPE:
		if screen == "game" and sim.s.state in ["reward","shop","ended"]: return
		if overlay != null: close_modal()
		elif screen == "game": show_pause()
		else: show_menu()
		return
	if screen != "game" or overlay != null: return
	if mobile:
		if event.keycode == KEY_SPACE: paused = not paused; update_hud()
		return
	match event.keycode:
		KEY_SPACE:
			if sim.s.state == "battle": paused = not paused
			elif sim.editable(): start_wave()
		KEY_R: board.show_routes = not board.show_routes
		KEY_C: board.home()
		KEY_G: board.grid = not board.grid
		KEY_E: toggle_edit()
		KEY_M:
			moving = board.selection.duplicate()
			toast("点击目标格移动选中建筑" if not moving.is_empty() else "先按住 Shift 框选建筑")
		KEY_DELETE:
			for p in board.selection: sim.remove(p)
			board.selection.clear()
			save_run()
		KEY_1,KEY_2,KEY_3,KEY_4,KEY_5,KEY_6:
			select_build(chosen_loadout[event.keycode-KEY_1])
		KEY_F11:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if DisplayServer.window_get_mode()!=DisplayServer.WINDOW_MODE_FULLSCREEN else DisplayServer.WINDOW_MODE_WINDOWED)

# 绘制菜单背景、核心图案和装饰动画，不处理战斗规则。
func _draw():
	if screen == "game": return
	draw_rect(Rect2(Vector2.ZERO,size),Color("09131e"))
	var center = Vector2(size.x*0.73,size.y*0.49)
	for i in range(1,10):
		draw_arc(center,60.0+i*37,0,TAU,100,Color(0.24,0.42,0.48,0.12),1,true)
	for x in range(0,int(size.x),45): draw_line(Vector2(x,0),Vector2(x,size.y),Color(0.12,0.23,0.3,0.16),1)
	for y in range(0,int(size.y),45): draw_line(Vector2(0,y),Vector2(size.x,y),Color(0.12,0.23,0.3,0.16),1)
	for i in 6:
		var a = i*TAU/6+anim*0.025
		var p = center+Vector2.from_angle(a)*210
		draw_line(center,p,Color(0.32,0.85,0.72,0.22),1.5,true)
		draw_circle(p,17,Color("183540"))
		draw_arc(p,17,0,TAU,24,MINT,1.5,true)
		draw_line(p,p+(center-p).normalized()*25,MINT,4,true)
	var points = PackedVector2Array()
	for i in 6: points.append(center+Vector2.from_angle(i*TAU/6-PI/6)*85)
	draw_colored_polygon(points,Color("173740"))
	points.append(points[0])
	draw_polyline(points,MINT,3,true)
	draw_arc(center,110,anim*0.2,anim*0.2+4.5,80,Color("458d88"),2,true)
	draw_circle(center,35,Color("72dfc0"))
	draw_circle(center,20,Color("143942"))
	for i in 30:
		var a = i*2.399
		var r = 270+sin(i*17.2)*100-fmod(anim*9+i*13,55)
		var p = center+Vector2.from_angle(a)*r
		draw_circle(p,3 if i%5 else 5,Color("b6667e"))

# 移除旧页面及弹窗，重新建立页面容器和底部提示标签。
func clear_page():
	draft.clear()
	focused_cell = Vector2i(-1,-1)
	close_modal()
	if toast_label != null and is_instance_valid(toast_label):
		remove_child(toast_label)
		toast_label.queue_free()
	if page != null:
		remove_child(page)
		page.queue_free()
	page = Control.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(page)
	hud.clear()
	board = null
	toast_label = Label.new()
	toast_label.add_theme_font_size_override("font_size",16)
	toast_label.add_theme_color_override("font_color",GOLD)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	toast_label.offset_top = -37
	toast_label.offset_bottom = -10
	add_child(toast_label)
	toast_label.visible = false

# 创建单行标签并设置字号、颜色。
func text(parent: Node,value: String,sz = 16,color = Color("dbe8ef")) -> Label:
	var label = Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size",maxi(18,sz) if mobile else sz)
	label.add_theme_color_override("font_color",color)
	parent.add_child(label)
	return label

# 创建可自动换行的说明文字。
func paragraph(parent: Node,value: String,sz = 15,color = MUTED) -> Label:
	var label = text(parent,value,sz,color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

# 创建按钮，将传入的 Callable 回调连接到点击信号。
func button(parent: Node,value: String,fn: Callable,primary = false) -> Button:
	var b = Button.new()
	b.text = value
	b.custom_minimum_size.y = 48 if mobile else 38
	if mobile: b.add_theme_font_size_override("font_size",18)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if primary:
		b.add_theme_stylebox_override("normal",style(Color("6ce5c5"),Color("6ce5c5"),7))
		b.add_theme_color_override("font_color",Color("0c2b30"))
	b.pressed.connect(func(): sound(); fn.call())
	parent.add_child(b)
	return b

# 创建纵向布局容器。
func vbox(parent: Node) -> VBoxContainer:
	var v = VBoxContainer.new()
	parent.add_child(v)
	return v

# 创建横向布局容器。
func hbox(parent: Node) -> HBoxContainer:
	var h = HBoxContainer.new()
	parent.add_child(h)
	return h

# 创建带面板背景的卡片，并返回内部纵向容器。
func card(parent: Node) -> VBoxContainer:
	var panel = PanelContainer.new()
	parent.add_child(panel)
	return vbox(panel)

# 添加固定高度的空白控件。
func spacer(parent: Node,height = 12):
	var c = Control.new()
	c.custom_minimum_size.y = height
	parent.add_child(c)

# 创建铺满页面的边距容器，数值是像素。
func margin_root(left = 36,top = 28,right = 36,bottom = 28) -> MarginContainer:
	var m = MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left",left)
	m.add_theme_constant_override("margin_top",top)
	m.add_theme_constant_override("margin_right",right)
	m.add_theme_constant_override("margin_bottom",bottom)
	page.add_child(m)
	if mobile:
		for side in ["left","right","top","bottom"]:
			m.add_theme_constant_override("margin_"+side,12 if side != "bottom" else 36)
		if screen != "game":
			var scroll = ScrollContainer.new()
			m.add_child(scroll)
			var inner = MarginContainer.new()
			inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			scroll.add_child(inner)
			return inner
	return m

# 显示指挥中心入口，包括新出征、继续存档、研究和纪录。
func show_menu():
	if mobile:
		show_menu_mobile()
		return
	screen = "menu"
	clear_page()
	var m = margin_root(76,48,76,50)
	var root = vbox(m)
	var header = hbox(root)
	text(header,"◈  LAST CORE",20,MINT)
	var grow = Control.new()
	grow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(grow)
	text(header,"离线指挥官   /   本地记录",14,MUTED)
	var fill = Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(fill)
	text(root,"THE LAST LIGHT IN THE VOID",14,MINT)
	text(root,"最后核心",68)
	text(root,"没有终点。只有下一道防线。",22,MUTED)
	spacer(root,20)
	var menu = vbox(root)
	menu.custom_minimum_size.x = 320
	menu.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if not store.data.run.is_empty(): button(menu,"继续出征     →",resume_run,true)
	button(menu,"部署新防线     →",show_map_select,store.data.run.is_empty())
	button(menu,"永久研究  /  蓝图库",show_meta_shop)
	button(menu,"本地远征纪录",show_records)
	var row = hbox(menu)
	button(row,"设置",show_settings).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button(row,"退出",quit_game).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer(root,22)
	text(root,"指挥官资产   %s  金币" % num(store.data.coins),17,GOLD)
	var fill2 = Control.new()
	fill2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(fill2)
	text(root,"01  建造防线     /     02  抵御虫群     /     03  无限进化",14,MUTED)
	text(root,"离线版 0.3.0    •    GODOT 4.5.2",12,Color("546e80"))

# 创建页面标题、说明及返回入口。
func page_heading(root: Node,title: String,subtitle: String):
	var row = hbox(root)
	button(row,"← 返回",show_menu)
	text(row,title,28)
	paragraph(root,subtitle)
	spacer(root,10)

# 显示五档地图的尺寸和规则，选择后进入蓝图配置。
func show_map_select():
	if mobile:
		show_maps_mobile()
		return
	screen = "maps"
	clear_page()
	var root = vbox(margin_root(64,40,64,50))
	page_heading(root,"选择战区","五种战区，五份独立纪录。所有地图共用无尽规则，出征期间地形固定。")
	var row = hbox(root)
	for i in 5:
		var d = sim.rules.maps[i]
		var box = card(row)
		box.get_parent().size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text(box,"0%d / SECTOR" % (i+1),13,MINT)
		spacer(box,20)
		text(box,d.name,22)
		text(box,"%d × %d" % [d.width,d.height],30)
		paragraph(box,["紧凑防线\n每一格都至关重要","多路交汇\n搭建交叉火力","纵深布局\n控制每一条通道","外围与内圈\n构筑分层防守","广阔边境\n一座核心，无尽可能"][i])
		spacer(box,20)
		text(box,"初始预算  %d" % d.budget,14,GOLD)
		text(box,"障碍上限  %d" % d.walls,14,MUTED)
		button(box,"选择战区  →",func(): chosen_map=i; show_loadout(),true)
	spacer(root,24)
	paragraph(root,"每波最多三个进攻方向；每 15 波领取一次奖励。可随时保存退出，战斗中退出会恢复到波前状态。")
	if not store.data.run.is_empty(): paragraph(root,"已有未结束出征。开始新出征前会结算旧出征的已保存进度。",15,GOLD)

# 显示可携带蓝图和种子输入，准备开始新出征。
func show_loadout():
	if mobile:
		show_loadout_mobile()
		return
	screen = "loadout"
	clear_page()
	var root = vbox(margin_root(80,40,80,48))
	page_heading(root,"出征蓝图","携带六种炮台。障碍和陷阱不占蓝图槽，建造消耗独立预算。")
	text(root,sim.rules.maps[chosen_map].name+"  /  六槽配置",24,MINT)
	var grid_node = GridContainer.new()
	grid_node.columns = 2 if mobile else 4
	grid_node.add_theme_constant_override("h_separation",14)
	grid_node.add_theme_constant_override("v_separation",14)
	root.add_child(grid_node)
	for i in 8:
		var d = sim.rules.towers[i]
		var box = card(grid_node)
		box.get_parent().custom_minimum_size.x = 275
		text(box,d.name,21,Color(d.color))
		text(box,d.role,15)
		text(box,"预算 %d  /  伤害 %d  /  射程 %.1f" % [d.cost,d.damage,d.range],13,MUTED)
		var unlocked = d.id in store.data.unlocked
		var active = d.id in chosen_loadout
		var b = button(box,"已携带  ✓" if active else ("加入蓝图" if unlocked else "需在研究室解锁"),func():
			if d.id in chosen_loadout: chosen_loadout.erase(d.id)
			elif chosen_loadout.size()<6: chosen_loadout.append(d.id)
			show_loadout())
		b.disabled = not unlocked
	spacer(root,10)
	var row = hbox(root)
	text(row,"地图种子",16,MUTED)
	var seed_input = LineEdit.new()
	seed_input.placeholder_text = "留空随机生成"
	seed_input.custom_minimum_size.x = 240
	row.add_child(seed_input)
	text(row,"已携带 %d / 6" % chosen_loadout.size(),18,GOLD)
	var start = button(row,"开始出征  →",func():
		var seed_value = seed_input.text.to_int() if seed_input.text.is_valid_int() else int(Time.get_unix_time_from_system())%2000000000
		begin_run(seed_value),true)
	start.disabled = chosen_loadout.size() != 6
	paragraph(root,"磁轨穿透 · 熔火范围 · 星陨越障 · 雷链跳跃 · 棱镜破甲 · 极寒控制\n解锁额外蓝图后，可在六个携带槽中自由替换。")

# 创建新模拟器并快照永久培养；已有保存出征会先结算。
func begin_run(seed_value: int):
	if not store.data.run.is_empty(): store.settle(store.data.run)
	sim = Simulation.new()
	sim.new_run(chosen_map,seed_value,store.data.meta,chosen_loadout)
	paused = false
	speed = 0.5 if mobile else 1.0
	selected = chosen_loadout[0]
	checkpoint = sim.snapshot()
	save_run()
	show_game()

# 恢复保存的出征，按状态重新打开战场、奖励或商店界面。
func resume_run():
	if not sim.restore(store.data.run):
		toast("存档规则版本不兼容，原记录已保留")
		return
	chosen_map = int(sim.s.map)
	chosen_loadout = sim.s.loadout.duplicate()
	selected = chosen_loadout[0]
	if sim.s.state == "intermission": sim.s.state = "edit"
	paused = false
	checkpoint = sim.snapshot()
	show_game()
	if sim.s.state == "reward": show_reward()
	elif sim.s.state == "shop": show_run_shop()

# 搭建战场、状态栏、蓝图按钮和挂机选项，并连接棋盘信号。
func show_game():
	if mobile:
		show_game_mobile()
		return
	screen = "game"
	clear_page()
	var root = vbox(margin_root(24,18,24,42))
	var top = hbox(root)
	text(top,"◈ 最后核心",22,MINT)
	var expand = Control.new()
	expand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(expand)
	hud["wave"] = text(top,"WAVE 00",24)
	hud["health"] = text(top,"核心 100 / 100",17,MINT)
	hud["budget"] = text(top,"预算",17,GOLD)
	hud["coins"] = text(top,"金币",17,GOLD)
	button(top,"☰",show_pause)
	var body = hbox(root)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left = vbox(body)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var strip = hbox(left)
	hud["status"] = text(strip,"准备阶段",15,MINT)
	var grow = Control.new()
	grow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	strip.add_child(grow)
	button(strip,"敌人路线",show_route_menu)
	button(strip,"⌖ 核心",func(): board.home())
	button(strip,"网格",func(): board.grid = not board.grid)
	board = Board.new()
	board.sim = sim
	board.selected = selected
	board.effects = store.data.settings.effects
	board.damage_numbers = store.data.settings.numbers
	board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board.custom_minimum_size.y = 300
	left.add_child(board)
	board.cell_clicked.connect(on_cell_clicked)
	board.selection_changed.connect(func(cells): toast("已选中 %d 个建筑，按 M 后点击目标格移动" % cells.size()))
	var under = hbox(left)
	text(under,"左键建造  ·  右键拆除  ·  滚轮缩放  ·  中键拖动  ·  Shift 框选",12,MUTED)
	var side_panel = PanelContainer.new()
	side_panel.custom_minimum_size.x = 292
	body.add_child(side_panel)
	var side = vbox(side_panel)
	side.add_theme_constant_override("separation",6)
	text(side,"作战终端",20)
	text(side,"TACTICAL OVERVIEW",11,MINT)
	hud["next"] = paragraph(side,"",16)
	button(side,"波次情报  /  挑战",show_wave_details)
	var hp = ProgressBar.new()
	hp.custom_minimum_size.y = 8
	hp.show_percentage = false
	side.add_child(hp)
	hud["hpbar"] = hp
	hud["reward"] = text(side,"",14,GOLD)
	spacer(side,2)
	hud["selected"] = paragraph(side,"",16)
	hud["details"] = paragraph(side,"",13)
	var speeds = hbox(side)
	for n in [1,2,3]:
		button(speeds,"%d×" % n,func(): speed=n).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud["pause"] = button(side,"暂停 / 继续  [空格]",func(): paused=not paused)
	hud["start"] = button(side,"启动防线  →",start_wave,true)
	hud["edit"] = button(side,"编辑布局  [E]",toggle_edit)
	button(side,"一键基础布阵",starter_layout)
	var auto_row = hbox(side)
	text(auto_row,"周期奖励",13,MUTED)
	var auto_mode = OptionButton.new()
	for label in ["手动选择","优先金币","优先强化"]: auto_mode.add_item(label)
	auto_mode.select(["manual","gold","growth"].find(store.data.settings.auto))
	auto_mode.item_selected.connect(func(i): store.data.settings.auto=["manual","gold","growth"][i]; store.save())
	auto_row.add_child(auto_mode)
	var space = Control.new()
	space.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(space)
	text(side,"最近战报",13,MINT)
	hud["log"] = paragraph(side,"",12)
	var build_panel = PanelContainer.new()
	root.add_child(build_panel)
	var build = vbox(build_panel)
	var caption = hbox(build)
	text(caption,"建造蓝图",16)
	text(caption,"炮台阻路 · 陷阱可通行 · 拆除全额返还",12,MUTED)
	var cards = hbox(build)
	var ids = chosen_loadout.duplicate()
	ids.append_array(["wall","fence","spike","slow"])
	for id in ids:
		var d = sim.defs[id]
		var b = button(cards,"%s\n%d 预算" % [d.name,d.cost],func(): select_build(id))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size.y = 66
		b.add_theme_font_size_override("font_size",14)
		b.add_theme_color_override("font_color",Color(d.color))
		b.tooltip_text = d.role
	update_hud()

# 读取模拟器状态刷新数值和按钮；这里不计算战斗伤害。
func update_hud():
	if mobile:
		update_mobile_hud()
		return
	if screen != "game" or hud.is_empty(): return
	var s: Dictionary = sim.s
	hud.wave.text = "WAVE %02d" % s.wave
	hud.health.text = "核心 %d / %d" % [s.hp,s.max_hp]
	hud.budget.text = "◈ 预算 %s" % num(s.budget)
	hud.coins.text = "◉ 金币 %s" % num(s.income-s.spent)
	hud.hpbar.value = s.hp
	var names = {"prepare":"初始布阵","edit":"编辑中 · 自动推进已停止","battle":"交战中 · 防线已锁定","intermission":"休整 · %.1f 秒后自动开战" % maxf(0,countdown),"reward":"周期奖励 · 等待选择","shop":"补给站","ended":"出征结束"}
	hud.status.text = names[s.state]+("  /  已暂停" if paused else "  /  %d×" % speed)
	var info = sim.wave_info(int(s.wave)+1 if s.state == "battle" else int(s.completed)+1)
	var directions: Array = []
	for d in info.dirs: directions.append(["北","东","南","西"][d])
	hud.next.text = "下一波  %02d  /  %s\n%s  ·  %d 个目标" % [info.wave,info.title," + ".join(directions),info.count]
	hud.reward.text = "距周期奖励  %d 波" % (15-int(s.completed)%15)
	var d: Dictionary = sim.defs[selected]
	hud.selected.text = "%s  /  %s" % [d.name,d.role]
	hud.details.text = "预算 %d" % d.cost
	if d.has("damage"):
			hud.details.text += "  ·  伤害 %s\n射程 %.1f  ·  间隔 %.2f 秒" % [num(sim.effective_damage(selected)),sim.effective_range(selected),maxf(0.1,d.cooldown/sim.effective_haste(selected))]
	else: hud.details.text += "  ·  耐久 %d\n波间自动免费修复存活障碍" % d.hp
	hud.start.disabled = not sim.editable()
	hud.start.text = "立即开始下一波  →" if s.completed > 0 else "启动防线  →"
	hud.edit.disabled = s.state not in ["intermission","edit","prepare"]
	hud.edit.text = "完成编辑，恢复倒计时" if s.state == "edit" else "编辑布局  [E]"
	hud.pause.text = "继续战斗  [空格]" if paused else "暂停观察  [空格]"
	hud.log.text = "\n".join(s.log.slice(maxi(0,s.log.size()-3)))

# 切换当前建造蓝图，并取消待执行的群体移动。
func select_build(id: String):
	if mobile:
		if palette_suppress: return
		begin_draft("place",id)
		return
	selected = id
	touch_mode = "build"
	board.selected = id
	moving.clear()
	update_hud()

# 把地格点击转换成查看、建造、拆除或移动命令，并保存结果。
func on_cell_clicked(p: Vector2i,mouse_button: int):
	if mobile:
		if not draft.is_empty(): update_draft(p)
		elif sim.inside(p):
			focused_cell = p
			board.focus_cell = p
			refresh_tactical_panel()
		return
	if not sim.inside(p): return
	if mouse_button == MOUSE_BUTTON_LEFT and sim.s.buildings.has(sim.key(p)) and moving.is_empty():
		if sim.s.state == "intermission": sim.s.state = "edit"
		show_building(p)
		return
	if not sim.editable():
		if sim.s.buildings.has(sim.key(p)):
			var b: Dictionary = sim.s.buildings[sim.key(p)]
			toast("%s：累计伤害 %s，开火 %d 次" % [sim.defs[b.id].name,num(b.damage),b.shots])
		else: toast("战斗中防线已锁定，可暂停观察或投降")
		return
	if sim.s.state == "intermission": sim.s.state = "edit"
	if not moving.is_empty() and mouse_button == MOUSE_BUTTON_LEFT:
		var error = sim.move_group(moving,p-moving[0])
		toast("建筑已移动" if error == "" else error)
		moving.clear()
		board.selection.clear()
	elif mouse_button == MOUSE_BUTTON_RIGHT:
		if sim.remove(p): sound(330)
	else:
		var error = sim.place(selected,p)
		if error != "":
			toast(error)
			board.invalid_cell = p
			board.invalid_time = 3.0
		else: sound(880)
	save_run()
	update_hud()

# 显示单座建筑的伤害统计、地形加成和目标优先级。
func show_building(p: Vector2i):
	var b: Dictionary = sim.s.buildings[sim.key(p)]
	var body = modal(sim.defs[b.id].name+" / 作战配置",790)
	text(body,"累计伤害 %s  /  开火 %d 次" % [num(b.damage),b.shots],20,MINT)
	var terrain_id = sim.s.terrain.get(sim.key(p),"")
	if terrain_id != "": paragraph(body,"所在位置："+sim.rules.terrain[terrain_id].name,15,GOLD)
	if sim.defs[b.id].has("range"):
		text(body,"当前射程 %.1f 格" % sim.effective_range(b.id,p),16)
		paragraph(body,"主目标优先级决定每轮攻击选取的第一个敌人；范围与连锁效果仍按武器自身规则触发。")
		var row = hbox(body)
		for kind in ["core","strong","weak","fast"]:
			var names = {"core":"接近核心","strong":"最高生命","weak":"最低生命","fast":"最快移动"}
			var choice = button(row,names[kind]+(" ✓" if b.get("priority","core") == kind else ""),func(): sim.set_priority(p,kind); save_run(); show_building(p))
			choice.disabled = not sim.editable()
	paragraph(body,"战斗中只能查看，波间可修改目标优先级。",14,MUTED)
	button(body,"返回战场",close_modal,true)

# 只在空白且可编辑的防线上放置示例构筑；仍逐座检查预算和连通性。
func starter_layout():
	if not sim.editable():
		toast("只能在准备或休整时布阵")
		return
	if not sim.s.buildings.is_empty():
		toast("一键布阵仅用于空白防线")
		return
	var c = Vector2i(sim.s.width/2,sim.s.height/2)
	var offsets = [Vector2i(-3,-2),Vector2i(2,-3),Vector2i(3,2),Vector2i(-2,3),Vector2i(-3,1),Vector2i(1,3)]
	var types = ["rail","ember","rail","ember","frost","spike"]
	var built = 0
	for i in offsets.size():
		var id = types[i] if types[i] in chosen_loadout or types[i] == "spike" else chosen_loadout[i%6]
		if sim.place(id,c+offsets[i]) == "": built += 1
	sim.s.state = "edit"
	save_run()
	toast("已部署 %d 座建筑；可自行补充或修改后开战" % built)
	update_hud()

# 切换编辑和休整状态；编辑时停止自动开波倒计时。
func toggle_edit():
	if sim.s.state == "edit":
		sim.s.state = "intermission"
		countdown = 5
	elif sim.editable(): sim.s.state = "edit"
	save_run()
	update_hud()

# 先保存波前快照，再清空时间累积量并启动战斗。
func start_wave():
	if not draft.is_empty(): return
	if not sim.editable(): return
	close_modal()
	# 开战前记录检查点：战斗中退出会恢复到这里，未完成波次不发奖励。
	checkpoint = sim.snapshot()
	store.data.run = checkpoint.duplicate(true)
	store.save()
	elapsed = 0
	paused = false
	sim.start_wave()
	sound(420)
	if mobile: refresh_tactical_panel()
	update_hud()

# 处理失败结算或波间存档；根据挂机偏好领取奖励、购买补给。
func on_wave_end():
	countdown = 5
	if mobile: refresh_tactical_panel()
	sound(270 if sim.s.state == "ended" else 960)
	if sim.s.state == "ended":
		settled_amount = store.settle(sim.s)
		show_result()
		return
	save_run()
	if sim.s.state == "reward":
		if store.data.settings.auto == "manual": show_reward()
		else:
			var kind = "gold" if store.data.settings.auto == "gold" else store.data.settings.preference
			if kind not in ["power","haste","range","gold"]: kind = "gold"
			if kind != "gold" and store.data.settings.target != "all":
				kind = store.data.settings.target+":"+kind if store.data.settings.target in chosen_loadout else "gold"
			sim.claim_reward(kind)
			if store.data.settings.auto_buy:
				var item = int(store.data.settings.buy_item)
				if [280,360,450][item] <= store.data.settings.buy_budget: sim.buy(item)
			sim.close_shop()
			save_run()

# 战斗中保存波前检查点；其他阶段保存当前状态，避免存储半场战斗。
func save_run():
	if sim.s.is_empty() or sim.s.state == "ended": return
	store.data.run = checkpoint.duplicate(true) if sim.s.state == "battle" else sim.snapshot()
	if not store.save(): toast(store.error)

# 建立遮罩和弹窗面板，返回用于添加内容的容器。
func modal(title: String,width = 760) -> VBoxContainer:
	close_modal()
	overlay = Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	var shade = ColorRect.new()
	shade.color = Color(0.015,0.025,0.04,0.88)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(shade)
	if mobile:
		var outer = MarginContainer.new()
		outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		for side in ["left","right","top","bottom"]: outer.add_theme_constant_override("margin_"+side,16)
		overlay.add_child(outer)
		var panel = PanelContainer.new()
		outer.add_child(panel)
		var scroll = ScrollContainer.new()
		panel.add_child(scroll)
		var body = vbox(scroll)
		body.custom_minimum_size.x = minf(width,get_viewport_rect().size.x-70)
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text(body,title,26)
		return body
	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var panel = PanelContainer.new()
	panel.custom_minimum_size.x = width
	center.add_child(panel)
	var body = vbox(panel)
	text(body,title,28)
	spacer(body,4)
	return body

# 释放当前弹窗，并清空引用。
func close_modal():
	if overlay != null and is_instance_valid(overlay):
		remove_child(overlay)
		overlay.queue_free()
	overlay = null

# 提供普通怪、特殊怪路线筛选和入口定位。
func show_route_menu():
	var body = modal("敌人路线",720)
	paragraph(body,"预览与实战共用同一寻路规则。布局变化后即时更新；石墙被摧毁后路线可能变化。")
	paragraph(body,"地形：青色高台使炮台射程 +0.7；斜线通道不可建造；紫色裂隙每秒伤害 3、移动速度 ×0.85。地形不会改变最短路选择。",13,GOLD)
	var options = hbox(body)
	for i in range(-2,4):
		var labels = { -2:"下一波",-1:"全部",0:"北",1:"东",2:"南",3:"西" }
		button(options,labels[i],func(): board.route_filter=i; board.show_routes=true; close_modal())
	var types = hbox(body)
	button(types,"普通怪：四向最短路",func(): board.special_routes=false; board.show_routes=true; close_modal())
	button(types,"特殊怪：越过玩家建筑",func(): board.special_routes=true; board.show_routes=true; close_modal())
	paragraph(body,"跃迁虫越过玩家建筑但不能越过固定岩体。破障者使用同一路线，遇到石墙/栅栏时先破坏；炮台不会被攻击。",14,GOLD)
	for i in 4:
		var row = hbox(body)
		text(row,"%s入口   普通 %d 格 / 特殊 %d 格" % [["北","东","南","西"][i],sim.paths[0][i].size()-1,sim.paths[1][i].size()-1],16,Board.COLORS[i])
		button(row,"定位",func(): board.jump_to(i); close_modal())
	var bottom = hbox(body)
	button(bottom,"隐藏路线",func(): board.show_routes=false; close_modal())
	button(bottom,"返回战场",close_modal,true)

# 预览未来波次及敌人属性，并在允许的波间提供挑战报名。
func show_wave_details():
	var body = modal("波次情报",790)
	for w in range(int(sim.s.completed)+1,int(sim.s.completed)+4):
		var info = sim.wave_info(w)
		var names: Array = []
		for id in info.types: names.append(sim.rules.enemies[id].name)
		text(body,"WAVE %02d  ·  %s  ·  %d 个目标" % [w,info.title,info.count],20,MINT if w%15 else GOLD)
		paragraph(body,"、".join(names)+"  /  生命倍率 %.2f" % info.scale)
	text(body,"下一波详细编成",19,MINT)
	var upcoming = sim.wave_info(int(sim.s.wave)+1 if sim.s.state == "battle" else int(sim.s.completed)+1)
	var counts: Dictionary = {}
	for item in upcoming.queue: counts[item.type] = counts.get(item.type,0)+1
	for id in counts:
		var enemy: Dictionary = sim.rules.enemies[id]
		text(body,"%s ×%d   生命 %s   速度 %.2f   漏怪扣血 %d   护甲 %d%%" % [enemy.name,counts[id],num(enemy.hp*upcoming.scale),enemy.speed,enemy.leak,int(enemy.armor*100)],14,Color(enemy.color))
	spacer(body,8)
	paragraph(body,"挑战固定在每周期第 9 波，可在第 7～9 波开战前接受或取消。允许漏怪，存活即成功；成功立即获 65 金币，周期奖励提升 50%。挑战敌群按后续 10 波强度生成。")
	if sim.editable() and int(sim.s.completed)%15 in [6,7,8]:
		button(body,"取消本周期挑战" if sim.s.challenge else "接受第 %d 波挑战" % (int(sim.s.completed)/15*15+9),func(): sim.set_challenge(not sim.s.challenge); save_run(); show_wave_details(),true)
	else: text(body,"挑战默认跳过 · 第 7 波前开始开放报名",14,GOLD)
	button(body,"返回",close_modal)

# 展示金币、全体强化或指定炮台强化，领取后进入补给站。
func show_reward():
	var body = modal("周期突破  /  第 %d 波完成" % sim.s.completed,940)
	paragraph(body,"选择一项奖励。强化与金币互斥，领取后进入补给站。"+("  挑战成功加成已生效！" if sim.s.challenge_bonus else ""))
	var target_row = hbox(body)
	text(target_row,"强化作用目标",14,MUTED)
	var target_choice = OptionButton.new()
	var target_ids: Array = ["all"]
	target_ids.append_array(chosen_loadout)
	for id in target_ids: target_choice.add_item("全部炮台" if id == "all" else sim.defs[id].name)
	var target = str(store.data.settings.target)
	if target not in target_ids: target = "all"
	target_choice.select(target_ids.find(target))
	target_choice.item_selected.connect(func(i): store.data.settings.target=target_ids[i]; store.save(); show_reward())
	target_row.add_child(target_choice)
	text(target_row,"单炮台强化增幅更高；全体强化覆盖全部武器",13,MUTED)
	var row = hbox(body)
	for kind in ["power","haste","range"]:
		var growth_key = kind if target == "all" else target+":"+kind
		var box = card(row)
		box.get_parent().custom_minimum_size.x = 218
		text(box,{"power":"火力协议","haste":"超频协议","range":"感知协议"}[kind],22,MINT)
		text(box,"等级 %d → %d" % [sim.s.growth.get(growth_key,0),sim.s.growth.get(growth_key,0)+(2 if sim.s.challenge_bonus else 1)],15)
		text(box,"%.3f× → %.3f×" % [sim.reward_multiplier(kind,target),sim.reward_multiplier(kind,target,2 if sim.s.challenge_bonus else 1)],16,GOLD)
		paragraph(box,"递减增长，无等级上限。" if kind != "haste" else "达到表现频率限制后，额外收益转为等效伤害。",13)
		button(box,"选择强化",func(): sim.claim_reward(growth_key); save_run(); show_run_shop(),true)
	var gold = card(row)
	gold.get_parent().custom_minimum_size.x = 218
	text(gold,"战争红利",22,GOLD)
	text(gold,"+ %s 金币" % num(sim.reward_gold()),24)
	paragraph(gold,"本局可以消费，剩余带回用于永久培养。",13)
	button(gold,"领取金币",func(): sim.claim_reward("gold"); save_run(); show_run_shop())

# 显示本局金币与补给库存，购买后保存并刷新页面。
func show_run_shop():
	var body = modal("战地补给站",780)
	text(body,"本局收入 %s  −  消费 %s  =  可用 %s" % [num(sim.s.income),num(sim.s.spent),num(sim.s.income-sim.s.spent)],17,GOLD)
	paragraph(body,"只使用本局赚取的金币。库存每周期刷新；离开后继续推进。")
	for i in 3:
		var row = hbox(body)
		var label = text(row,["核心修复   +35 生命","工程物资   +120 建造预算","火力注入   火力协议 +1 级"][i],18)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var b = button(row,"%d 金币" % [280,360,450][i],func():
			if not sim.buy(i): toast("金币不足、已售罄或核心无需修复")
			save_run()
			show_run_shop())
		b.disabled = sim.s.shop_stock[i] <= 0
	button(body,"完成补给，继续出征  →",func(): sim.close_shop(); countdown=5; save_run(); close_modal(),true)

# 暂停战斗并显示继续、保存退出、设置和投降入口。
func show_pause():
	paused = true
	var body = modal("指挥菜单",580)
	paragraph(body,"战斗暂停也无法编辑建筑。保存退出会保留波前状态，本波未结算变化回滚。")
	button(body,"继续",func(): paused=false; close_modal(),true)
	button(body,"设置与自动偏好",show_settings)
	button(body,"战报统计",show_battle_report)
	button(body,"保存并返回主菜单",func(): save_run(); show_menu())
	button(body,"投降 / 结束出征",confirm_surrender)

# 显示结束出征确认框，确认后结算已获得的收益。
func confirm_surrender():
	var body = modal("结束本次出征？",580)
	paragraph(body,"最高已完成 %d 波；未完成波不发奖励。可带走 %d 金币。" % [sim.s.completed,sim.s.income-sim.s.spent])
	button(body,"确认结束并结算",func(): sim.finish("主动撤离" if sim.editable() else "主动投降"); settled_amount=store.settle(sim.s); show_result(),true)
	button(body,"继续出征",func(): paused=false; close_modal())

# 显示已完成波数、带回金币和本地纪录状态。
func show_result():
	var body = modal("核心失守" if sim.s.hp <= 0 else "出征结束",730)
	text(body,"最高完成   %d 波" % sim.s.completed,38,MINT)
	text(body,"带回 %s 金币（含首次里程碑奖励）" % num(settled_amount),22,GOLD)
	paragraph(body,"战区：%s  ·  种子：%d\n击杀 %d  /  漏怪 %d  /  挑战成功 %d\n纪录仅保存在本机。" % [sim.rules.maps[sim.s.map].name,sim.s.seed,sim.s.kills,sim.s.leaks,sim.s.challenges_won])
	var row = hbox(body)
	button(row,"同种子重新出征",func(): begin_run(int(sim.s.seed)),true)
	button(row,"返回指挥中心",show_menu)
	button(row,"查看战报",show_battle_report)

# 按累计伤害排列建筑，并展示最近一波漏怪和障碍损毁。
func show_battle_report():
	var body = modal("防线战报",780)
	var rows: Array = []
	for k in sim.s.buildings:
		var b: Dictionary = sim.s.buildings[k]
		if sim.defs[b.id].has("damage"): rows.append({"name":sim.defs[b.id].name,"damage":b.damage,"shots":b.shots,"pos":k})
	rows.sort_custom(func(a,b): return a.damage>b.damage)
	for row in rows.slice(0,10):
		text(body,"%s  [%s]    伤害 %s  /  开火 %d%s" % [row.name,row.pos,num(row.damage),row.shots,"  ·  尚未开火" if row.shots == 0 else ""],16)
	if sim.report.has("leaks"):
		var leaks: Array = []
		for id in sim.report.leaks: leaks.append("%s ×%d" % [sim.rules.enemies[id].name,sim.report.leaks[id]])
		paragraph(body,"最近波漏怪："+("无" if leaks.is_empty() else "、".join(leaks))+"\n障碍损毁：%d" % sim.report.destroyed)
	button(body,"返回",show_result if sim.s.state == "ended" else show_pause)

# 显示永久研究和炮台解锁，修改只在新出征快照中生效。
func show_meta_shop():
	screen = "research"
	clear_page()
	var root = vbox(margin_root(70,35,70,44))
	page_heading(root,"永久研究室","局外培养在新出征时形成快照；不会改变已保存出征。")
	text(root,"可用金币   %s" % num(store.data.coins),26,GOLD)
	var global_row = hbox(root)
	var level = int(store.data.meta.get("power",0))
	text(global_row,"基础火力 Lv.%d  /  所有武器每级 +9%% 基础伤害" % level,19,MINT)
	button(global_row,"研究  %d 金币" % (120+level*85),func(): purchase_meta("power",120+level*85))
	var grid_node = GridContainer.new()
	grid_node.columns = 2 if mobile else 4
	grid_node.add_theme_constant_override("h_separation",14)
	grid_node.add_theme_constant_override("v_separation",14)
	root.add_child(grid_node)
	for i in 8:
		var d = sim.rules.towers[i]
		var box = card(grid_node)
		box.get_parent().custom_minimum_size.x = 290
		text(box,d.name,22,Color(d.color))
		text(box,d.role,14,MUTED)
		if d.id not in store.data.unlocked:
			button(box,"解锁  %d 金币" % d.unlock,func():
				if store.data.coins >= d.unlock:
					store.data.coins-=d.unlock
					store.data.unlocked.append(d.id)
					store.save()
					show_meta_shop()
				else: toast("金币不足"))
		else:
			var lv = int(store.data.meta.get(d.id,0))
			text(box,"专精 Lv.%d  /  每级 +7%%" % lv,14)
			button(box,"研究  %d 金币" % (90+lv*65),func(): purchase_meta(d.id,90+lv*65))
			button(box,"进阶分支 / 模块",func(): show_modules(d.id))
	paragraph(root,"未消费的出征金币与首次每 15 波里程碑奖励用于永久研究。进阶分支与模块在新出征生效，切换已解锁配置免费。",14,MUTED)

# 购买或切换炮台分支与模块，已解锁的配置可免费切换。
func show_modules(id: String):
	var body = modal(sim.defs[id].name+" / 技术改造",780)
	paragraph(body,"每种炮台可装配一个进阶分支与一个模块。培养效果在出征开始时快照，已有出征不会改变。")
	for slot in ["branch","module"]:
		text(body,"进阶分支" if slot == "branch" else "功能模块",20,MINT)
		var row = hbox(body)
		var options = ["impact","rapid"] if slot == "branch" else ["amplifier","scope"]
		for option in options:
			var unlock_key = id+"_owned_"+option
			var cost = 380 if slot == "branch" else 260
			var owned = store.data.meta.get(unlock_key,false)
			var active = store.data.meta.get(id+"_"+slot,"") == option
			var names = {"impact":"重击分支  伤害 ×1.30","rapid":"速射分支  攻速 ×1.25","amplifier":"增幅模块  伤害 ×1.15","scope":"观测模块  射程 ×1.18"}
			button(row,names[option]+("  ✓" if active else ("  装配" if owned else "  %d 金币" % cost)),func():
				if not owned:
					if store.data.coins < cost: toast("金币不足"); return
					store.data.coins -= cost
					store.data.meta[unlock_key] = true
				store.data.meta[id+"_"+slot] = option
				store.save()
				show_modules(id))
	button(body,"返回研究室",func(): close_modal(); show_meta_shop(),true)

# 检查局外金币，购买一级永久研究后保存。
func purchase_meta(id: String,cost: int):
	if store.data.coins < cost:
		toast("金币不足，出征可获取金币")
		return
	store.data.coins -= cost
	store.data.meta[id] = int(store.data.meta.get(id,0))+1
	store.save()
	show_meta_shop()

# 按地图筛选本地纪录；相同波数采用并列名次，仅保存在本机。
func show_records():
	screen = "records"
	clear_page()
	var root = vbox(margin_root(80,40,80,50))
	page_heading(root,"远征纪录","本地成绩按地图尺寸分别记录。最高完成波数计分，同分并列。")
	var tabs = hbox(root)
	for i in 5:
		var m = sim.rules.maps[i]
		button(tabs,"%d × %d" % [m.width,m.height],func(): chosen_map=i; show_records())
	var box = card(root)
	text(box,"本地档案  /  "+sim.rules.maps[chosen_map].name,23,MINT)
	var records = store.data.records.filter(func(r): return int(r.map)==chosen_map)
	records.sort_custom(func(a,b): return a.wave>b.wave)
	if records.is_empty(): paragraph(box,"尚无出征纪录。部署防线，留下第一份战报。")
	var previous = -1
	var rank = 0
	for i in mini(records.size(),9):
		var r: Dictionary = records[i]
		if int(r.wave) != previous: rank=i+1
		previous = int(r.wave)
		text(box,"#%02d    %d 波     种子 %d     金币 %s     %s" % [rank,r.wave,r.seed,num(r.coins),r.date.substr(0,10)],17)
	spacer(root,15)

# 配置音量、特效、自动奖励、自动购买和障碍重建偏好。
func show_settings():
	var body = modal("设置与挂机偏好",720)
	var vol = hbox(body)
	text(vol,"提示音音量",17)
	var slider = HSlider.new()
	slider.min_value = 0
	slider.max_value = 1
	slider.step = 0.05
	slider.value = store.data.settings.volume
	slider.custom_minimum_size.x = 360
	slider.value_changed.connect(func(v): store.data.settings.volume=v; sound())
	vol.add_child(slider)
	for setting in ["effects","numbers"]:
		var toggle = CheckButton.new()
		toggle.text = "战斗特效" if setting == "effects" else "伤害数字"
		toggle.button_pressed = store.data.settings[setting]
		toggle.toggled.connect(func(value):
			store.data.settings[setting] = value
			if board != null:
				board.effects = store.data.settings.effects
				board.damage_numbers = store.data.settings.numbers)
		body.add_child(toggle)
	var pref_row = hbox(body)
	text(pref_row,"自动强化优先级",16)
	var pref = OptionButton.new()
	for name in ["火力","超频","射程"]: pref.add_item(name)
	pref.select(["power","haste","range"].find(store.data.settings.preference))
	pref.item_selected.connect(func(i): store.data.settings.preference=["power","haste","range"][i])
	pref_row.add_child(pref)
	var target_row = hbox(body)
	text(target_row,"优先强化炮台",16)
	var target_choice = OptionButton.new()
	var ids: Array = ["all"]
	ids.append_array(chosen_loadout)
	for id in ids: target_choice.add_item("全体" if id == "all" else sim.defs[id].name)
	target_choice.select(maxi(0,ids.find(store.data.settings.target)))
	target_choice.item_selected.connect(func(i): store.data.settings.target=ids[i])
	target_row.add_child(target_choice)
	paragraph(body,"自动强化优先选择指定炮台和属性；该炮台未携带时改取金币。",13)
	var buy = CheckButton.new()
	buy.text = "启用每周期自动购买（默认关闭）"
	buy.button_pressed = store.data.settings.auto_buy
	buy.toggled.connect(func(v): store.data.settings.auto_buy=v)
	body.add_child(buy)
	var buy_row = hbox(body)
	text(buy_row,"消费上限",15)
	var budget = SpinBox.new()
	budget.min_value = 0
	budget.max_value = 10000
	budget.step = 10
	budget.value = store.data.settings.buy_budget
	budget.value_changed.connect(func(v): store.data.settings.buy_budget=int(v))
	buy_row.add_child(budget)
	var item = OptionButton.new()
	for name in ["核心修复 280","建造预算 360","火力强化 450"]: item.add_item(name)
	item.select(int(store.data.settings.buy_item))
	item.item_selected.connect(func(i): store.data.settings.buy_item=i)
	buy_row.add_child(item)
	if screen == "game":
		var rebuild = CheckButton.new()
		rebuild.text = "预算足够时自动重建被破坏的障碍"
		rebuild.button_pressed = sim.s.auto_rebuild
		rebuild.toggled.connect(func(v): sim.s.auto_rebuild=v)
		body.add_child(rebuild)
	if not mobile: paragraph(body,"操作：1～6 选择炮台；左键建造 / 右键拆除；Shift 框选，M 移动，Delete 拆除选中；滚轮缩放，中键拖动；C 回核心，R 路线，G 网格，E 编辑，空格暂停/开战，F11 全屏。",14)
	paragraph(body,"波间倒计时使用实际时间；自动奖励开启后跳过商店，自动购买只买所选品类一件且受预算限制。关闭游戏不生成离线收益。",14,GOLD)
	button(body,"保存设置",func(): store.save(); save_run(); close_modal(); paused=false,true)

# 显示短暂的底部提示，不阻塞战斗。
func toast(message: String):
	if toast_label == null or not is_instance_valid(toast_label): return
	toast_label.text = message
	toast_time = 4.5
	toast_label.visible = true

# 将大数缩写为 k、M、B 或科学计数法，避免撑破界面。
func num(value) -> String:
	var n = float(value)
	if n >= 1e12: return "%.2e" % n
	if n >= 1e9: return "%.2fB" % (n/1e9)
	if n >= 1e6: return "%.2fM" % (n/1e6)
	if n >= 10000: return "%.1fk" % (n/1000)
	return str(int(n))

# 自动运行固定演示并保存截图，只供开发打包使用。
func capture_demo():
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png("res://build/menu.png")
	begin_run(104729)
	starter_layout()
	for w in 8:
		sim.start_wave()
		for i in 6000:
			sim.step()
			if sim.s.state != "battle": break
	for item in [["arc",Vector2i(10,5)],["mortar",Vector2i(5,10)]]:
		sim.place(item[0],item[1])
	start_wave()
	await get_tree().create_timer(3.0).timeout
	paused = true
	update_hud()
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://build/game.png")
	await get_tree().create_timer(0.3).timeout
	quit_game()

# 使用独立存档验证导出程序能够开始出征并保存。
func release_smoke():
	store.path = "user://release_smoke.json"
	store.data.run = {}
	begin_run(99523)
	starter_layout()
	save_run()
	var restored = Storage.new()
	restored.path = store.path
	restored.load_profile()
	if restored.data.run.get("seed",0) != 99523 or restored.data.run.get("buildings",{}).size() < 4:
		push_error("RELEASE STORAGE SMOKE FAILED: "+store.error)
		get_tree().quit(1)
		return
	print("RELEASE STORAGE SMOKE PASS ",ProjectSettings.globalize_path(store.path))
	get_tree().quit()

# 手机主菜单使用两列大按钮，避免桌面菜单在横屏手机上过高。
func show_menu_mobile():
	screen = "menu"
	clear_page()
	var root = vbox(margin_root())
	text(root,"LAST CORE  /  ANDROID",18,MINT)
	text(root,"最后核心",44)
	paragraph(root,"没有终点。只有下一道防线。",20)
	var grid_node = GridContainer.new()
	grid_node.columns = 2
	grid_node.add_theme_constant_override("h_separation",16)
	root.add_child(grid_node)
	if not store.data.run.is_empty(): button(grid_node,"继续出征 →",resume_run,true)
	button(grid_node,"部署新防线 →",show_map_select,true)
	button(grid_node,"永久研究 / 蓝图库",show_meta_shop)
	button(grid_node,"远征纪录",show_records)
	button(grid_node,"设置与挂机偏好",show_settings)
	button(grid_node,"退出游戏",show_mobile_exit)
	text(root,"指挥官资产  %s 金币" % num(store.data.coins),20,GOLD)
	paragraph(root,"拖放预览 · 确认部署 · 随时暂停
纯离线游玩，自动保存；切到后台暂停。",18,MUTED)

func show_mobile_exit():
	var body = modal("退出游戏",600)
	paragraph(body,"当前进度会保存，战斗中退出恢复到本波开始前。")
	button(body,"保存并退出",func(): save_run(); quit_game(),true)
	button(body,"返回游戏",close_modal)

# 战场顶栏与蓝图条紧凑显示，全图默认适配剩余区域。
func compact_button(parent: Node,title: String,action: Callable,accent=false) -> Button:
	var b = button(parent,title,action,accent)
	b.custom_minimum_size.y = 36
	b.add_theme_font_size_override("font_size",15)
	for state in ["normal","hover","pressed","disabled"]:
		var box = b.get_theme_stylebox(state).duplicate()
		box.content_margin_top = 5
		box.content_margin_bottom = 5
		box.content_margin_left = 8
		box.content_margin_right = 8
		b.add_theme_stylebox_override(state,box)
	return b

func small_text(parent: Node,value: String,color=MUTED) -> Label:
	var label = paragraph(parent,value,15,color)
	label.add_theme_font_size_override("font_size",15)
	return label

func show_game_mobile():
	screen = "game"
	clear_page()
	moving.clear()
	inspect_panel_open = false
	touch_mode = "inspect"
	var outer = MarginContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]: outer.add_theme_constant_override("margin_"+side,6)
	page.add_child(outer)
	toast_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	toast_label.offset_top = 42
	toast_label.offset_bottom = 66
	toast_label.add_theme_color_override("font_shadow_color",Color.BLACK)
	toast_label.add_theme_constant_override("shadow_offset_x",1)
	toast_label.add_theme_constant_override("shadow_offset_y",1)
	var root = vbox(outer)
	root.add_theme_constant_override("separation",4)
	var top = hbox(root)
	top.add_theme_constant_override("separation",5)
	hud["summary"] = small_text(top,"",MINT)
	hud.summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud["pause"] = compact_button(top,"暂停",func(): paused=not paused; update_hud())
	for n in [0.5,1.0,2.0]:
		hud["speed"+str(n)] = compact_button(top,str(n)+"×",func(): speed=n; update_hud())
	hud["start"] = compact_button(top,"开战",mobile_advance,true)
	compact_button(top,"−",func(): board.zoom_by(1/1.5))
	compact_button(top,"＋",func(): board.zoom_by(1.5))
	compact_button(top,"全图",func(): board.home())
	compact_button(top,"菜单",show_pause)
	var middle = hbox(root)
	middle.add_theme_constant_override("separation",0)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tactical_toggle = compact_button(middle,"详情",func(): inspect_panel_open=true; refresh_tactical_panel())
	tactical_toggle.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var panel = PanelContainer.new()
	tactical_panel = panel
	panel.custom_minimum_size.x = 206
	panel.add_theme_stylebox_override("panel",style(Color(0.05,0.10,0.14,0.76),Color(0.3,0.7,0.65,0.3),6))
	middle.add_child(panel)
	var panel_scroll = ScrollContainer.new()
	panel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(panel_scroll)
	panel_body = vbox(panel_scroll)
	panel_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_body.add_theme_constant_override("separation",7)
	board = Board.new()
	board.sim = sim
	board.touch_enabled = true
	board.selected = selected
	board.effects = store.data.settings.effects
	board.damage_numbers = store.data.settings.numbers
	board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_child(board)
	board.cell_clicked.connect(on_cell_clicked)
	board.preview_changed.connect(update_draft)
	var scroll = ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 54
	root.add_child(scroll)
	var row = hbox(scroll)
	row.add_theme_constant_override("separation",5)
	var ids = chosen_loadout.duplicate()
	ids.append_array(["wall","fence","spike","slow"])
	for id in ids:
		var d = sim.defs[id]
		var b = compact_button(row,"%s\n%d" % [d.name,d.cost],func(): select_build(id))
		b.add_theme_color_override("font_color",Color(d.color))
		b.gui_input.connect(func(event): blueprint_input(event,id,b))
	refresh_tactical_panel()
	update_hud()

# 支持从底栏直接拖出蓝图；松手只确定预览位置，不提交部署。
func blueprint_input(event,id: String,control: Control):
	if event is InputEventMouse and event.device == -1: return
	if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		if event.pressed:
			palette_start = control.global_position+event.position
			palette_id = id
			palette_drag = false
			palette_suppress = false
		else:
			if palette_drag:
				palette_suppress = true
				get_tree().create_timer(0.15).timeout.connect(func(): palette_suppress=false)
			palette_id = ""

# 拖出蓝图后通过视口输入继续追踪，即使手指已离开原按钮。
# 横向手势保留给蓝图栏滚动；向上拖出才开始部署。
func _input(event):
	if not mobile or screen != "game" or palette_id == "" or overlay != null: return
	if event is InputEventMouse and event.device == -1: return
	if event is InputEventScreenDrag or (event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		var delta_pos = event.position-palette_start
		if not palette_drag and delta_pos.y < -12 and absf(delta_pos.y) > absf(delta_pos.x):
			begin_draft("place",palette_id)
			palette_drag = not draft.is_empty()
		if palette_drag:
			update_draft(board.cell_at(event.position-board.global_position))
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		if not event.pressed and palette_drag:
			palette_suppress = true
			palette_id = ""
			palette_drag = false
			get_tree().create_timer(0.15).timeout.connect(func(): palette_suppress=false)
			get_viewport().set_input_as_handled()

func mobile_advance():
	if not draft.is_empty(): return
	if sim.s.state == "reward": show_reward()
	elif sim.s.state == "shop": show_run_shop()
	elif sim.s.state == "ended": show_result()
	elif sim.editable(): start_wave()
	refresh_tactical_panel()
	update_hud()

func update_mobile_hud():
	if screen != "game" or not hud.has("summary"): return
	var s = sim.s
	hud.summary.text = "波 %d · 核心 %d · 预算 %s" % [s.wave,s.hp,num(s.budget)]
	hud.pause.text = "继续" if paused else "暂停"
	var names = {"prepare":"开战","edit":"下一波","battle":"交战中","intermission":"开战 %.0fs" % maxf(countdown,0),"reward":"奖励","shop":"补给","ended":"结算"}
	hud.start.text = names[s.state]
	hud.start.disabled = s.state == "battle" or not draft.is_empty()
	for n in [0.5,1.0,2.0]:
		hud["speed"+str(n)].text = ("• " if speed == n else "")+str(n)+"×"
	if hud.has("tower_stats") and is_instance_valid(hud.tower_stats) and sim.s.buildings.has(sim.key(focused_cell)):
		var b = sim.s.buildings[sim.key(focused_cell)]
		hud.tower_stats.text = "累计伤害 %s\n开火 %d 次" % [num(b.damage),b.shots]

func begin_draft(kind: String,id: String,source=Vector2i(-1,-1)):
	if not sim.editable():
		toast("波间才能部署；战斗中可暂停查看")
		return
	# 编辑模式冻结波间倒计时，确认/取消后由玩家主动开战。
	sim.s.state = "edit"
	selected = id
	draft = {"kind":kind,"id":id,"source":source,"cell":Vector2i(-1,-1)}
	board.preview_id = id
	board.preview_source = source
	board.preview_cell = Vector2i(-1,-1)
	board.preview_active = kind != "remove"
	board.preview_trail.clear()
	board.focus_cell = Vector2i(-1,-1)
	draft_error = "请在战场轻点或拖动，选择位置"
	refresh_tactical_panel()
	if kind == "remove": update_draft(source)
	update_hud()

# 使用独立模拟器检查预算、地形和路径连通性，不改动真实防线。
func update_draft(p: Vector2i):
	if draft.is_empty(): return
	if draft.cell == p: return
	draft.cell = p
	board.preview_cell = p
	if sim.inside(p):
		board.preview_trail.append(p)
		if board.preview_trail.size() > 8: board.preview_trail.pop_front()
	if not sim.inside(p): draft_error = "请选择地图内的地格"
	elif draft.kind == "remove": draft_error = "" if sim.s.buildings.has(sim.key(p)) else "此处没有建筑"
	else:
		draft_error = sim.deployment_error(draft.kind,draft.id,p,draft.source)
	board.preview_valid = draft_error == ""
	# 拖动只更新文字和按钮状态，保留原有控件，避免重新排版。
	if hud.has("draft_position"):
		hud.draft_position.text = "位置 (%d, %d)" % [p.x+1,p.y+1] if sim.inside(p) else "尚未选择位置"
		hud.draft_status.text = draft_error if draft_error != "" else "位置有效，确认后生效"
		hud.draft_status.add_theme_color_override("font_color",MINT if draft_error == "" else Color("f08da1"))
		hud.draft_confirm.disabled = draft_error != ""
		if hud.has("draft_range"): hud.draft_range.text = "射程 %.1f 格" % sim.effective_range(draft.id,p)


func confirm_draft():
	if draft.is_empty() or draft_error != "" or not sim.editable(): return
	var p: Vector2i = draft.cell
	var error = ""
	if draft.kind == "place": error = sim.place(draft.id,p)
	elif draft.kind == "move": error = sim.move_group([draft.source],p-draft.source)
	elif not sim.remove(p): error = "无法拆除"
	if error != "":
		draft_error = error
		refresh_tactical_panel()
		return
	cancel_draft(false)
	focused_cell = p
	board.focus_cell = p
	sound(880)
	save_run()
	refresh_tactical_panel()
	update_hud()

func cancel_draft(refresh_panel=true):
	draft.clear()
	focused_cell = Vector2i(-1,-1)
	inspect_panel_open = false
	board.preview_active = false
	board.preview_cell = Vector2i(-1,-1)
	board.preview_trail.clear()
	board.focus_cell = focused_cell
	if refresh_panel:
		refresh_tactical_panel()
		update_hud()

func refresh_tactical_panel():
	if not mobile or not is_instance_valid(panel_body): return
	var expanded = not draft.is_empty() or sim.s.buildings.has(sim.key(focused_cell)) or inspect_panel_open
	tactical_panel.visible = expanded
	tactical_toggle.visible = not expanded
	for key in ["tower_stats","draft_position","draft_status","draft_confirm","draft_range"]: hud.erase(key)
	for child in panel_body.get_children():
		panel_body.remove_child(child)
		child.queue_free()
	var building = sim.s.buildings.get(sim.key(focused_cell),{})
	var id = draft.id if not draft.is_empty() else building.get("id","")
	if id == "":
		compact_button(panel_body,"收起面板",func(): inspect_panel_open=false; refresh_tactical_panel())
		small_text(panel_body,"战场指挥",MINT)
		small_text(panel_body,"蓝图拖入战场或轻点选中，再选择地格。确认后才扣除预算。")
		small_text(panel_body,"选择炮台可查看射程、伤害和目标优先级。")
		small_text(panel_body,"波间可布阵；编辑后手动开战。暂停可随时使用。")
		small_text(panel_body,"＋/− 或双指缩放\n放大后单指平移\n全图时固定视角")
		compact_button(panel_body,"波次情报",show_wave_details)
		compact_button(panel_body,"作战设置",show_mobile_operations)
		return
	var d = sim.defs[id]
	small_text(panel_body,d.name,Color(d.color))
	small_text(panel_body,d.role)
	if d.has("range"):
		var p: Vector2i = draft.cell if not draft.is_empty() else focused_cell
		small_text(panel_body,"射程 %.1f 格 · 基础伤害 %s\n攻击间隔 %.2f 秒" % [sim.effective_range(id,p),num(d.damage),d.cooldown],MINT)
	else: small_text(panel_body,"耐久 %d" % d.hp,MINT)
	if not draft.is_empty():
		var verbs = {"place":"放置","move":"移动","remove":"拆除"}
		if d.has("range"): hud["draft_range"] = small_text(panel_body,"射程 %.1f 格" % sim.effective_range(id,draft.cell),MINT)
		small_text(panel_body,"待确认"+verbs[draft.kind]+(" · 费用 %d" % d.cost if draft.kind == "place" else ""),GOLD)
		hud["draft_position"] = small_text(panel_body,"位置 (%d, %d)" % [draft.cell.x+1,draft.cell.y+1] if sim.inside(draft.cell) else "尚未选择位置")
		hud["draft_status"] = small_text(panel_body,draft_error if draft_error != "" else "位置有效，确认后生效",Color("f08da1") if draft_error != "" else MINT)
		var confirm = compact_button(panel_body,"✓ 确认"+verbs[draft.kind],confirm_draft,true)
		hud["draft_confirm"] = confirm
		confirm.disabled = draft_error != ""
		compact_button(panel_body,"× 取消",cancel_draft)
		return
	hud["tower_stats"] = small_text(panel_body,"累计伤害 %s\n开火 %d 次" % [num(building.damage),building.shots])
	var terrain_id = sim.s.terrain.get(sim.key(focused_cell),"")
	if terrain_id != "": small_text(panel_body,sim.rules.terrain[terrain_id].name,GOLD)
	if d.has("range"):
		var choices = GridContainer.new()
		choices.columns = 2
		panel_body.add_child(choices)
		for kind in ["core","strong","weak","fast"]:
			var names = {"core":"近核心","strong":"高生命","weak":"低生命","fast":"最快"}
			var b = compact_button(choices,names[kind]+("✓" if building.get("priority","core") == kind else ""),func(): sim.set_priority(focused_cell,kind); save_run(); refresh_tactical_panel())
			b.disabled = not sim.editable()
	var row = hbox(panel_body)
	for kind in ["move","remove"]:
		var b = compact_button(row,"移动" if kind == "move" else "拆除",func(): begin_draft(kind,id,focused_cell))
		b.disabled = not sim.editable()
	small_text(panel_body,"战斗中只可查看" if not sim.editable() else "波间可调整目标和位置")
	compact_button(panel_body,"收起详情",func(): focused_cell=Vector2i(-1,-1); board.focus_cell=focused_cell; inspect_panel_open=false; refresh_tactical_panel())

func show_mobile_operations():
	var body = modal("作战设置",700)
	paragraph(body,"本局 %d 波，击杀 %d。倍速与暂停可直接在战场顶栏操作。" % [sim.s.completed,sim.s.kills])
	button(body,"波次情报 / 挑战",show_wave_details)
	button(body,"自动奖励与购买设置",show_settings)
	button(body,"返回战场",close_modal,true)

# 安卓战区选择使用固定紧凑卡片，所有选择按钮都在一屏内。
func mobile_page_root(title: String,back: Callable) -> VBoxContainer:
	clear_page()
	var margin = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]: margin.add_theme_constant_override("margin_"+side,12)
	page.add_child(margin)
	var root = vbox(margin)
	root.add_theme_constant_override("separation",8)
	var header = hbox(root)
	compact_button(header,"← 返回",back)
	text(header,title,23,MINT)
	return root

func show_maps_mobile():
	screen = "maps"
	var root = mobile_page_root("选择战区",show_menu)
	small_text(root,"五种战区 · 独立纪录 · 出征期间地形固定")
	var row = hbox(root)
	row.add_theme_constant_override("separation",8)
	for i in 5:
		var d = sim.rules.maps[i]
		var box = card(row)
		box.get_parent().size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.get_parent().size_flags_stretch_ratio = 1
		small_text(box,"0%d  /  战区" % (i+1),MINT)
		text(box,d.name,19)
		text(box,"%d × %d" % [d.width,d.height],22)
		small_text(box,["紧凑防线","交叉火力","纵深布局","分层防守","广阔边境"][i])
		small_text(box,"预算 %d\n障碍上限 %d" % [d.budget,d.walls],GOLD)
		compact_button(box,"选择 →",func(): chosen_map=i; show_loadout(),true)
	small_text(root,"每波最多三个进攻方向；每 15 波领取奖励。放大地图后可拖动观察。")
	if not store.data.run.is_empty(): small_text(root,"已有未结束出征：开始新出征前会结算旧出征的已保存进度。",GOLD)

func show_loadout_mobile():
	screen = "loadout"
	var root = mobile_page_root("出征蓝图 · "+sim.rules.maps[chosen_map].name,show_map_select)
	small_text(root,"携带六种炮台；障碍和陷阱不占蓝图槽。")
	var grid_node = GridContainer.new()
	grid_node.columns = 4
	root.add_child(grid_node)
	for i in 8:
		var d = sim.rules.towers[i]
		var box = card(grid_node)
		box.get_parent().size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_theme_constant_override("separation",4)
		small_text(box,d.name+" · "+d.role,Color(d.color))
		small_text(box,"预算 %d · 射程 %.1f" % [d.cost,d.range])
		var unlocked = d.id in store.data.unlocked
		var active = d.id in chosen_loadout
		var b = compact_button(box,"已携带 ✓" if active else ("加入蓝图" if unlocked else "研究解锁"),func():
			if d.id in chosen_loadout: chosen_loadout.erase(d.id)
			elif chosen_loadout.size() < 6: chosen_loadout.append(d.id)
			show_loadout())
		b.disabled = not unlocked
	var row = hbox(root)
	small_text(row,"地图种子（选填）").custom_minimum_size.x = 140
	var seed_input = LineEdit.new()
	seed_input.placeholder_text = "留空随机"
	seed_input.custom_minimum_size = Vector2(175,36)
	row.add_child(seed_input)
	small_text(row,"已携带 %d / 6" % chosen_loadout.size(),GOLD).custom_minimum_size.x = 120
	var start = compact_button(row,"开始出征 →",func(): begin_run(seed_input.text.to_int() if seed_input.text.is_valid_int() else int(Time.get_unix_time_from_system())%2000000000),true)
	start.disabled = chosen_loadout.size() != 6
