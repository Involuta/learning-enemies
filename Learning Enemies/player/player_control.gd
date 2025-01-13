extends CharacterBody3D

var using_controller = false # only affects camera motion

# Get the gravity from the project settings to be synced with RigidBody nodes.
var default_gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var gravity = default_gravity
const WALK_SPEED := 8
const DODGE_SPEED := 10
const DODGE_DURATION_SECS := .5
const DODGE_COOLDOWN_SECS := .1
const JUMP_SPEED := 14.0
const MAX_JUMP_CHARGE_SECS := .5
# Seconds it takes for Player to decelerate to 0 speed when not walking
const WALK_DECEL_SECS := .25

var walk_input := Vector2.ZERO
var moving_right := true # Did the player last try to walk right?
var grounded_speed := 0
var can_dodge := true
var is_dodging := false

var mouse_camera_sensitivity := .001
var joystick_camera_sensitivity := .1
var camera_pitch_limit_deg := 90
var camera_twist_input := .0
var camera_pitch_input := .0
var locked_on := false
var lock_on_target = null

var look_angle := 0.0
var look_angle2 := 0.0
var max_cam_dist := 6.0 # dist btwn player and camera when camera's not colliding with geometry; player can modify this in-game

var RESHOOT_SECS := 1.0
var can_shoot := true
var shoot_queued := false
var next_buff_index := 0
var shoot_self_damage := 18.0

@onready var physical_collider := $CollisionShape3D
@onready var camera_twist_pivot := $CameraTwistPivot
@onready var camera_pitch_pivot := $CameraTwistPivot/CameraPitchPivot
@onready var camera := $CameraTwistPivot/CameraPitchPivot/CameraVisualObject
@onready var armature := $MeshInstance3D#$PlayerAnims/Armature
#@onready var anim_tree := $AnimationTree
@onready var hurtbox := $Hurtbox

@onready var root := $/root
var level : Node3D
var target: Node3D
#var ui: Control

const LERP_VAL := .15 # The rate at which lerp funcs change; used for body mvmt animations

func _ready():
	level = root.find_child("Level", true, false)
	#ui = root.find_child("UIRoot")
	
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta):
	# Dodge logic
	if Input.is_action_just_pressed("Dodge") and can_dodge:
		#anim_tree.set("parameters/StateMachine/conditions/just_dodged", true)
		dodge()
	else:
		pass
		#anim_tree.set("parameters/StateMachine/conditions/just_dodged", false)
	if Input.is_action_just_pressed("Jump") and is_on_floor():
		velocity.y = JUMP_SPEED
		
	if is_dodging:
		grounded_speed = DODGE_SPEED
	else:
		grounded_speed = WALK_SPEED
	
	# Player movement
	if not is_on_floor():
		velocity.y -= gravity * delta
	
	walk_input = Input.get_vector("WalkLeft", "WalkRight", "WalkForward", "WalkBackward")
	if walk_input.x != 0:
		moving_right = walk_input.x > 0
	var mvmt_dir = Vector3(walk_input.x, 0, walk_input.y)
	var oriented_mvmt_dir = (camera_twist_pivot.basis * mvmt_dir).normalized()
	if oriented_mvmt_dir:
		velocity.x = lerp(velocity.x, oriented_mvmt_dir.x * grounded_speed, LERP_VAL)
		velocity.z = lerp(velocity.z, oriented_mvmt_dir.z * grounded_speed, LERP_VAL)
		if is_on_floor():
			armature.rotation.y = lerp_angle(armature.rotation.y, atan2(velocity.x, velocity.z), LERP_VAL)
		else:
			armature.rotation.y = lerp_angle(armature.rotation.y, atan2(velocity.x, velocity.z), LERP_VAL / 5)
	else:
		velocity.x = lerp(velocity.x, 0.0, LERP_VAL)
		velocity.z = lerp(velocity.z, 0.0, LERP_VAL)
	move_and_slide()
	
	# Shoot
	if Input.is_action_just_pressed("Shoot"):
		if can_shoot:
			shoot()
		elif not shoot_queued:
			start_reshoot_timer()
	
	# Set look angle
	look_angle = camera_twist_pivot.basis.get_euler().y
	
	# Camera movement/orientation; ui_cancel means esc
	if Input.is_action_just_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	# Lock on logic; if target no longer exists, lock off
	if !lock_on_target:
		lock_off()
	if using_controller:
		camera_twist_input = Input.get_axis("LookRight", "LookLeft") * joystick_camera_sensitivity
		camera_pitch_input = Input.get_axis("LookUp", "LookDown") * joystick_camera_sensitivity
	if locked_on:
		camera_twist_pivot.look_at(lock_on_target.global_position + 2*Vector3.DOWN)
	else:
		camera_twist_pivot.rotate_y(camera_twist_input)
	# While locked on, you can look up and down, but not left and right
	camera_pitch_pivot.rotate_x(camera_pitch_input)
	camera_pitch_pivot.rotation.x = clamp(
		camera_pitch_pivot.rotation.x,
		deg_to_rad(-camera_pitch_limit_deg),
		deg_to_rad(camera_pitch_limit_deg))
	# These 2 lines prevent the camera from continuing to move in the last direction the mouse was moved in
	camera_twist_input = 0
	camera_pitch_input = 0
	
	# Send updates to background camera
	Globals.camera_updated.emit(camera_twist_pivot.rotation + camera_pitch_pivot.rotation)
	
	# Camera positioning based on level geometry
	place_camera()
	
	if Input.is_action_just_pressed("UseItem"):
		pass
		#anim_tree.set("parameters/StateMachine/conditions/use_item", true)
	else:
		pass
		#anim_tree.set("parameters/StateMachine/conditions/use_item", false)
	
	# Animation tree parameters
	var vel2D = Vector2(velocity.x, velocity.z)
	var move_blend_space := Vector2(vel2D.length(), 0)
	#anim_tree.set("parameters/StateMachine/GroundBlendSpace/blend_position", move_blend_space)
	#anim_tree.set("parameters/StateMachine/AerialBlendSpace/blend_position", Vector3.UP*velocity.y)

func _unhandled_input(event: InputEvent) -> void:
	if not using_controller:
		if event is InputEventMouseMotion:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				camera_twist_input = -event.relative.x * mouse_camera_sensitivity
				camera_pitch_input = -event.relative.y * mouse_camera_sensitivity

func place_camera():
	var space_state := get_world_3d().direct_space_state
	var cam_dir_basis = camera_twist_pivot.transform.basis * camera_pitch_pivot.transform.basis
	var cam_dir_vec = cam_dir_basis * Vector3.FORWARD
	var query = PhysicsRayQueryParameters3D.create(global_position, global_position - (max_cam_dist * cam_dir_vec))
	query.collision_mask = Globals.make_mask([Globals.ARENA_COL_LAYER])
	var result = space_state.intersect_ray(query)
	if result:
		camera.position = Vector3.ZERO
		# Make the camera move slightly closer to Player after going to the raycast hit to prevent the camera from seeing below the floor
		camera.global_position = result.position + .2 * result.position.direction_to(global_position)
	else:
		camera.position = Vector3.BACK * max_cam_dist

func lock_on(node):
	locked_on = true
	lock_on_target = node

func lock_off():
	locked_on = false

func dodge():
	can_dodge = false
	is_dodging = true
	set_collision_mask_value(Globals.ENEMY_COL_LAYER, false)
	await get_tree().create_timer(DODGE_DURATION_SECS).timeout
	is_dodging = false
	set_collision_mask_value(Globals.ENEMY_COL_LAYER, true)
	await get_tree().create_timer(DODGE_COOLDOWN_SECS).timeout
	can_dodge = true

func shoot():
	pass

func start_reshoot_timer():
	shoot_queued = true
	await get_tree().create_timer(RESHOOT_SECS).timeout
	shoot_queued = false
