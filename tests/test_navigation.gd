extends SceneTree
# 数字寻路与独立 BFS 对照，覆盖岩体缓存失效和建筑变化。
const Sim=preload('res://scripts/simulation.gd')
var failures=[]
var checks=0
func _init(): run.call_deferred()
func reference(sim,special):
 var field={}
 var queue=sim.core_cells()
 for p in queue: field[sim.key(p)]=0
 var head=0
 while head<queue.size():
  var p=queue[head];head+=1
  for dir in sim.DIRS:
   var next=p+dir
   if not sim.blocked(next,special) and not field.has(sim.key(next)):
    field[sim.key(next)]=field[sim.key(p)]+1
    queue.append(next)
 return field
func verify(sim,label):
 for special in [false,true]:
  checks+=1
  if reference(sim,special)!=sim.fields[1 if special else 0]: failures.append(label+str(special))
func run():
 var sim=Sim.new()
 var loadout=['rail','ember','mortar','arc','lance','frost']
 for map_id in 5:
  for seed_value in [104729,71237]:
   sim.new_run(map_id,seed_value,{},loadout)
   verify(sim,'initial')
   for i in range(1,4):
    var p=Vector2i(i,1)
    var before=sim.snapshot()
    var preview=sim.deployment_error('place','wall',p,Vector2i(-1,-1))
    checks+=1
    if before!=sim.snapshot(): failures.append('preview mutated state')
    var result=sim.place('wall',p)
    checks+=1
    if (preview=='')!=(result==''): failures.append('preview validity')
    verify(sim,'placed')
   sim.remove(Vector2i(1,1));verify(sim,'removed')
 print('NAVIGATION ',checks,' checks: ',failures)
 quit(0 if failures.is_empty() else 1)
