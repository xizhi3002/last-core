extends SceneTree
# 磁盘存档测试：使用 build 下的独立文件检查结算、重复领取和备份恢复。
const Storage = preload("res://scripts/storage.gd")
const Sim = preload("res://scripts/simulation.gd")
# 延迟执行测试，使场景树和预加载资源先完成初始化。
func _init(): run.call_deferred()
# 执行本文件的验证流程，输出结果后结束进程。
func run():
	var st = Storage.new()
	st.path = "res://build/transaction-test.json"
	st.error = ""
	st.data.coins = 0
	st.data.settled = []
	st.data.milestones = {}
	st.data.records = []
	var sim = Sim.new()
	sim.new_run(0,31,{"power":0},["rail","ember","mortar","arc","lance","frost"])
	sim.s.completed = 15
	sim.s.income = 500
	sim.s.spent = 100
	sim.finish("test")
	var got = st.settle(sim.s)
	assert(got == 480,"settlement + one milestone")
	assert(st.settle(sim.s) == 0,"idempotent settlement")
	assert(st.data.coins == 480,"balance once only")
	var restored = Storage.new()
	restored.path = st.path
	restored.load_profile()
	assert(restored.data.coins == 480,"disk persistence")
	assert(restored.data.run.is_empty(),"ended run removed")
	assert(restored.settle(sim.s) == 0,"idempotency survives reload")
	sim.s.run_id += "-new"
	assert(restored.settle(sim.s) == 400,"milestone cannot repeat")
	assert(restored.save(),"atomic replacement saves")
	var backup_before = JSON.parse_string(FileAccess.get_file_as_string(st.path+".bak"))
	var broken = FileAccess.open(st.path,FileAccess.WRITE)
	broken.store_string("{broken")
	broken.close()
	var recovered = Storage.new()
	recovered.path = st.path
	recovered.load_profile()
	assert(recovered.data.coins == backup_before.coins,"backup recovery")
	print("STORAGE PASS: 10 transactional persistence checks")
	quit()
