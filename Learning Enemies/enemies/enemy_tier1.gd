extends CharacterBody3D

@export var entity_name := "EnemyTier1"

enum {
	WALK_TO,
	ATTACK
}
var behav_state = WALK_TO

@export var follow_speed := 5.0
@export var target_distance := 3.0
@export var follow_turn_speed := .15
@export var attack_turn_speed := .5

var aiming_at_target := true

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var rng := RandomNumberGenerator.new()
@onready var nav_agent = $NavigationAgent3D
@onready var anim_tree = $AnimationTree
@onready var visual_mesh = $VisualMesh
@onready var root = $/root/Level

var target : Node3D
var walk_dest : Vector3

var anim_tree_exists := true

func _ready():
	target = root.find_child("Player")
	walk_dest = target.global_position + 5*Vector3.RIGHT
	#add_to_group("lockonables")
	if not find_child("AnimationTree", false, false):
		anim_tree_exists = false
	else:
		anim_tree.active = true

func _physics_process(delta):
	if not is_on_floor():
		print(walk_dest)
		velocity.y -= gravity * delta
	match(behav_state):
		WALK_TO:
			walk_to_pos_frame(walk_dest)
		ATTACK:
			attack_frame()
			
	if global_position.y < -100:
		queue_free()
		
	if anim_tree_exists:
		anim_tree.set("parameters/StateMachine/WalkSpace/blend_position", nav_agent.velocity.length())

func lerp_look_at_target(turn_speed):
	var vec3_to_target := global_position.direction_to(walk_dest)
	global_rotation.y = lerp_angle(global_rotation.y, PI + atan2(vec3_to_target.x, vec3_to_target.z), turn_speed)

func lerp_look_at_walk_dir(turn_speed):
	global_rotation.y = lerp_angle(global_rotation.y, PI + atan2(velocity.x, velocity.z), turn_speed)

func _on_navigation_agent_3d_target_reached():
	pass

func _on_navigation_agent_3d_velocity_computed(safe_velocity):
	if behav_state == WALK_TO:
		if is_on_floor():
			# This line accelerates the agent rather than setting its velocity to its desired velocity directly, preventing it from getting caught on corners
			velocity = velocity.move_toward(safe_velocity, .25)
		else:
			# If the enemy is in the air, don't use navigation agent at all
			var move_dir = global_position.direction_to(target.global_position)
			velocity.x = follow_speed * move_dir.x
			velocity.z = follow_speed * move_dir.z
	move_and_slide()

func walk_to_pos_frame(pos):
	lerp_look_at_walk_dir(follow_turn_speed)
	global_rotation.x = 0
	global_rotation.z = 0
	nav_agent.set_target_position(pos)
	var next_position = nav_agent.get_next_path_position()
	var new_velocity = (next_position - global_position).normalized() * follow_speed
	
	# Sets new wanted velocity, not actual velocity. Wanted velocity is used to compute new safe velocity
	nav_agent.velocity = new_velocity
	
	# If player isn't in sight, reduce target distance to a very small number
	if can_see_target():
		nav_agent.target_desired_distance = target_distance
	else:
		nav_agent.target_desired_distance = .1

func start_attack():
	behav_state = ATTACK
	aiming_at_target = true
	choose_attack()

func end_attack():
	if anim_tree_exists:
		anim_tree.set("parameters/StateMachine/conditions/overhead", false)
		anim_tree.set("parameters/StateMachine/conditions/sweep", false)
	behav_state = WALK_TO

func choose_attack():
	pass

func attack_frame():
	nav_agent.velocity.x = 0
	nav_agent.velocity.z = 0
	velocity.x = 0
	velocity.z = 0
	if aiming_at_target:
		lerp_look_at_target(attack_turn_speed)
		global_rotation.x = 0
		global_rotation.z = 0
	
func stop_aiming_at_target():
	aiming_at_target = false

func can_see_target():
	var space_state := get_world_3d().direct_space_state
	var sight_dir := global_position.direction_to(target.global_position)
	var query = PhysicsRayQueryParameters3D.create(global_position, global_position + nav_agent.neighbor_distance * sight_dir)
	query.collision_mask = Globals.make_mask([Globals.ARENA_COL_LAYER, Globals.PLAYER_PHYSICAL_COL_LAYER])
	query.collide_with_areas = true
	var result = space_state.intersect_ray(query)
	if not result:
		return true
	if result.collider.collision_layer == Globals.ARENA_COL_LAYER:
		return false
	else:
		return true
