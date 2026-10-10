extends Control
const Simulation = preload("res://scripts/simulation.gd")
const Storage = preload("res://scripts/storage.gd")
const Board = preload("res://scripts/board.gd")
var sim = Simulation.new()
var store = Storage.new()
var board
var page: Control
var overlay: Control
var hud: Dictionary = {}
var screen = "menu"
var chosen_map = 0
var chosen_loadout: Array = ["rail","ember","mortar","arc","lance","frost"]
var selected = "rail"
var speed = 1
var paused = false
var elapsed = 0.0
var countdown = 5.0
var refresh = 0.0
var toast_label: Label
var toast_time = 0.0
var moving: Array = []
var checkpoint: Dictionary = {}
var settled_amount = 0
var anim = 0.0
var audio_player: AudioStreamPlayer
var audio_buffer
var audio_phase = 0.0
var beep_left = 0
var beep_frequency = 440.0
var font: SystemFont
const MINT = Color("6ce5c5")
const MUTED = Color("8597a9")
const GOLD = Color("ebc683")

func _ready():
	get_tree().auto_accept_quit = false
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI","Microsoft YaHei","Noto Sans CJK SC","Arial"])
	var t = Theme.new()
	t.default_font = font
	t.default_font_size = 15
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

func _exit_tree():
	audio_buffer = null
	if is_instance_valid(audio_player): audio_player.stop()

func sound(freq = 660.0):
	beep_left = 1600
	beep_frequency = freq

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

func _process(delta):
	anim += delta
	fill_audio()
	if screen != "game": queue_redraw()
	if toast_label != null and is_instance_valid(toast_label):
		toast_time -= delta
		toast_label.visible = toast_time > 0
	if screen != "game" or sim.s.is_empty(): return
	if sim.s.state == "battle" and not paused:
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

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_run()
		quit_game()

func quit_game():
	audio_buffer = null
	if is_instance_valid(audio_player): audio_player.stop()
	await get_tree().create_timer(0.15).timeout
	get_tree().quit()

func _unhandled_key_input(event):
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_ESCAPE:
		if screen == "game" and sim.s.state in ["reward","shop","ended"]: return
		if overlay != null: close_modal()
		elif screen == "game": show_pause()
		else: show_menu()
		return
	if screen != "game" or overlay != null: return
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

func clear_page():
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

func text(parent: Node,value: String,sz = 16,color = Color("dbe8ef")) -> Label:
	var label = Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size",sz)
	label.add_theme_color_override("font_color",color)
	parent.add_child(label)
	return label

func paragraph(parent: Node,value: String,sz = 15,color = MUTED) -> Label:
	var label = text(parent,value,sz,color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func button(parent: Node,value: String,fn: Callable,primary = false) -> Button:
	var b = Button.new()
	b.text = value
	b.custom_minimum_size.y = 38
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if primary:
		b.add_theme_stylebox_override("normal",style(Color("6ce5c5"),Color("6ce5c5"),7))
		b.add_theme_color_override("font_color",Color("0c2b30"))
	b.pressed.connect(func(): sound(); fn.call())
	parent.add_child(b)
	return b

func vbox(parent: Node) -> VBoxContainer:
	var v = VBoxContainer.new()
	parent.add_child(v)
	return v

func hbox(parent: Node) -> HBoxContainer:
	var h = HBoxContainer.new()
	parent.add_child(h)
	return h

func card(parent: Node) -> VBoxContainer:
	var panel = PanelContainer.new()
	parent.add_child(panel)
	return vbox(panel)

func spacer(parent: Node,height = 12):
	var c = Control.new()
	c.custom_minimum_size.y = height
	parent.add_child(c)

func margin_root(left = 36,top = 28,right = 36,bottom = 28) -> MarginContainer:
	var m = MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left",left)
	m.add_theme_constant_override("margin_top",top)
	m.add_theme_constant_override("margin_right",right)
	m.add_theme_constant_override("margin_bottom",bottom)
	page.add_child(m)
	return m

func show_menu():
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
	button(menu,"远征纪录  /  排行榜",show_records)
	var row = hbox(menu)
	button(row,"设置",show_settings).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button(row,"退出",quit_game).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer(root,22)
	text(root,"指挥官资产   %s  金币" % num(store.data.coins),17,GOLD)
	var fill2 = Control.new()
	fill2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(fill2)
	text(root,"01  建造防线     /     02  抵御虫群     /     03  无限进化",14,MUTED)
	text(root,"本地开发版 0.1.0    •    GODOT 4.5.2    •    正式 Steam 服务未配置",12,Color("546e80"))

func page_heading(root: Node,title: String,subtitle: String):
	var row = hbox(root)
	button(row,"← 返回",show_menu)
	text(row,title,28)
	paragraph(root,subtitle)
	spacer(root,10)

func show_map_select():
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

func show_loadout():
	screen = "loadout"
	clear_page()
	var root = vbox(margin_root(80,40,80,48))
	page_heading(root,"出征蓝图","携带六种炮台。障碍和陷阱不占蓝图槽，建造消耗独立预算。")
	text(root,sim.rules.maps[chosen_map].name+"  /  六槽配置",24,MINT)
	var grid_node = GridContainer.new()
	grid_node.columns = 4
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

func begin_run(seed_value: int):
	if not store.data.run.is_empty(): store.settle(store.data.run)
	sim = Simulation.new()
	sim.new_run(chosen_map,seed_value,store.data.meta,chosen_loadout)
	paused = false
	speed = 1
	selected = chosen_loadout[0]
	checkpoint = sim.snapshot()
	save_run()
	show_game()

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

func show_game():
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

func update_hud():
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

func select_build(id: String):
	selected = id
	board.selected = id
	moving.clear()
	update_hud()

func on_cell_clicked(p: Vector2i,mouse_button: int):
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

func toggle_edit():
	if sim.s.state == "edit":
		sim.s.state = "intermission"
		countdown = 5
	elif sim.editable(): sim.s.state = "edit"
	save_run()
	update_hud()

func start_wave():
	if not sim.editable(): return
	close_modal()
	checkpoint = sim.snapshot()
	store.data.run = checkpoint.duplicate(true)
	store.save()
	elapsed = 0
	paused = false
	sim.start_wave()
	sound(420)
	update_hud()

func on_wave_end():
	countdown = 5
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

func save_run():
	if sim.s.is_empty() or sim.s.state == "ended": return
	store.data.run = checkpoint.duplicate(true) if sim.s.state == "battle" else sim.snapshot()
	if not store.save(): toast(store.error)

func modal(title: String,width = 760) -> VBoxContainer:
	close_modal()
	overlay = Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	var shade = ColorRect.new()
	shade.color = Color(0.015,0.025,0.04,0.88)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(shade)
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

func close_modal():
	if overlay != null and is_instance_valid(overlay):
		remove_child(overlay)
		overlay.queue_free()
	overlay = null

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

func show_pause():
	paused = true
	var body = modal("指挥菜单",580)
	paragraph(body,"战斗暂停也无法编辑建筑。保存退出会保留波前状态，本波未结算变化回滚。")
	button(body,"继续",func(): paused=false; close_modal(),true)
	button(body,"设置与自动偏好",show_settings)
	button(body,"战报统计",show_battle_report)
	button(body,"保存并返回主菜单",func(): save_run(); show_menu())
	button(body,"投降 / 结束出征",confirm_surrender)

func confirm_surrender():
	var body = modal("结束本次出征？",580)
	paragraph(body,"最高已完成 %d 波；未完成波不发奖励。可带走 %d 金币。" % [sim.s.completed,sim.s.income-sim.s.spent])
	button(body,"确认结束并结算",func(): sim.finish("主动撤离" if sim.editable() else "主动投降"); settled_amount=store.settle(sim.s); show_result(),true)
	button(body,"继续出征",func(): paused=false; close_modal())

func show_result():
	var body = modal("核心失守" if sim.s.hp <= 0 else "出征结束",730)
	text(body,"最高完成   %d 波" % sim.s.completed,38,MINT)
	text(body,"带回 %s 金币（含首次里程碑奖励）" % num(settled_amount),22,GOLD)
	paragraph(body,"战区：%s  ·  种子：%d\n击杀 %d  /  漏怪 %d  /  挑战成功 %d\n本地未验证纪录；不会提交到正式 Steam 排行榜。" % [sim.rules.maps[sim.s.map].name,sim.s.seed,sim.s.kills,sim.s.leaks,sim.s.challenges_won])
	var row = hbox(body)
	button(row,"同种子重新出征",func(): begin_run(int(sim.s.seed)),true)
	button(row,"返回指挥中心",show_menu)
	button(row,"查看战报",show_battle_report)

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
	grid_node.columns = 4
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

func purchase_meta(id: String,cost: int):
	if store.data.coins < cost:
		toast("金币不足，出征可获取金币")
		return
	store.data.coins -= cost
	store.data.meta[id] = int(store.data.meta.get(id,0))+1
	store.save()
	show_meta_shop()

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
	text(root,"Steam 正式排行榜  ·  联网未配置",22,GOLD)
	paragraph(root,"全球 / 好友 / 附近排名需要本游戏 AppID、Steamworks 绑定和可信成绩服务。当前版本保留本地游玩；纯离线记录不会冒充已验证成绩。",16)
	paragraph(root,"五个长期榜单，不设赛季。服务端接口、同一模拟器回放校验入口与部署说明随源码交付。",14)

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
	paragraph(body,"操作：1～6 选择炮台；左键建造 / 右键拆除；Shift 框选，M 移动，Delete 拆除选中；滚轮缩放，中键拖动；C 回核心，R 路线，G 网格，E 编辑，空格暂停/开战，F11 全屏。",14)
	paragraph(body,"波间倒计时使用实际时间；自动奖励开启后跳过商店，自动购买只买所选品类一件且受预算限制。关闭游戏不生成离线收益。",14,GOLD)
	button(body,"保存设置",func(): store.save(); save_run(); close_modal(); paused=false,true)

func toast(message: String):
	if toast_label == null or not is_instance_valid(toast_label): return
	toast_label.text = message
	toast_time = 4.5
	toast_label.visible = true

func num(value) -> String:
	var n = float(value)
	if n >= 1e12: return "%.2e" % n
	if n >= 1e9: return "%.2fB" % (n/1e9)
	if n >= 1e6: return "%.2fM" % (n/1e6)
	if n >= 10000: return "%.1fk" % (n/1000)
	return str(int(n))

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
