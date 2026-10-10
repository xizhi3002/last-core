extends SceneTree
const Storage = preload("res://scripts/storage.gd")
const Sim = preload("res://scripts/simulation.gd")
func _init(): run.call_deferred()
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
