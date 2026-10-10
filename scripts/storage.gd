extends RefCounted
const SCHEMA = 1
var path = "user://commander_local.json"
var error = ""
var data: Dictionary = {"schema":SCHEMA,"coins":0,"meta":{"power":0},"unlocked":["rail","ember","mortar","arc","lance","frost"],"records":[],"milestones":{},"settled":[],"run":{},"settings":{"volume":0.35,"effects":true,"numbers":true,"auto":"manual","preference":"power","auto_buy":false,"buy_budget":0,"buy_item":0}}

func _init():
	if "--test" in OS.get_cmdline_user_args(): path = "res://build/test_profile.json"
	if "--capture" in OS.get_cmdline_user_args():
		path = "res://build/capture_profile.json"
	else: load_profile()
	if not data.settings.has("target"): data.settings.target = "all"

func load_profile():
	if not FileAccess.file_exists(path): return
	var parser = JSON.new()
	var parsed = parser.data if parser.parse(FileAccess.get_file_as_string(path)) == OK else null
	if not valid(parsed):
		parsed = null
		if FileAccess.file_exists(path+".bak") and parser.parse(FileAccess.get_file_as_string(path+".bak")) == OK: parsed = parser.data
		if not valid(parsed):
			error = "存档损坏：保留原文件，未覆盖。"
			return
		error = "已从备份恢复存档。"
	for k in data:
		if parsed.has(k): data[k] = parsed[k]
	var defaults = {"volume":0.35,"effects":true,"numbers":true,"auto":"manual","preference":"power","auto_buy":false,"buy_budget":0,"buy_item":0}
	for k in defaults:
		if not data.settings.has(k): data.settings[k] = defaults[k]

func valid(v) -> bool:
	return v is Dictionary and v.get("schema",0) == SCHEMA and v.get("coins",-1) >= 0 and v.get("run") is Dictionary

func save() -> bool:
	if error.begins_with("存档损坏"): return false
	var file = FileAccess.open(path+".tmp",FileAccess.WRITE)
	if file == null:
		error = "无法写入存档："+str(FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(data))
	file.flush()
	file.close()
	var absolute = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path): DirAccess.copy_absolute(absolute,absolute+".bak")
	var result = DirAccess.rename_absolute(absolute+".tmp",absolute)
	if result != OK: error = "存档替换失败："+str(result)
	return result == OK

func settle(s: Dictionary) -> int:
	if s.run_id in data.settled: return 0
	var amount = maxi(0,int(s.income)-int(s.spent))
	var map_key = str(int(s.map))
	var old = int(data.milestones.get(map_key,0))
	var milestone = int(s.completed)/15
	var bonus = maxi(0,milestone-old)*80
	data.milestones[map_key] = maxi(old,milestone)
	data.coins += amount+bonus
	data.settled.append(s.run_id)
	data.records.append({"map":s.map,"wave":s.completed,"seed":s.seed,"version":s.version,"coins":amount,"bonus":bonus,"loadout":s.loadout,"meta":s.meta,"date":Time.get_datetime_string_from_system(),"verified":false})
	if data.records.size() > 500: data.records.pop_front()
	data.run = {}
	save()
	return amount+bonus
