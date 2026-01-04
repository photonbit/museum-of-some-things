extends CharacterBody3D

var gravity = -30
var crouch_move_speed = 4
var mouse_sensitivity = 0.002
var joy_sensitivity = 0.025
var joy_deadzone = 0.05
@export var jump_impulse = 13

var starting_height
var crouching_height
var crouch_time = 0.4
var crouch_speed
var _enabled = false

var _joy_right_x = JOY_AXIS_RIGHT_X
var _joy_right_y = JOY_AXIS_RIGHT_Y

@onready var camera = get_node("Pivot/Camera3D")

@export var smooth_movement = false
@export var dampening = 0.01
@export var max_speed_walk = 5
@export var max_speed_dash = 10
@export var max_speed = max_speed_walk

# Tiptoe (inverse duck) parameters
@export var tiptoe_offset := 0.25 # meters above standing eye height
@export var tiptoe_time := 0.25   # seconds to reach full tiptoe
var tiptoe_height := 0.0
var tiptoe_speed := 0.0

var _invert_y = false
var _mouse_sensitivity_factor = 1.0

func _ready():
  GlobalMenuEvents.set_invert_y.connect(_set_invert_y)
  GlobalMenuEvents.set_mouse_sensitivity.connect(_set_mouse_sensitivity)
  GlobalMenuEvents.set_joypad_deadzone.connect(_set_joy_deadzone)

  starting_height = $Pivot.get_position().y
  crouching_height = starting_height / 3
  crouch_speed = (starting_height - crouching_height) / crouch_time
  tiptoe_height = starting_height + tiptoe_offset
  tiptoe_speed = (tiptoe_height - starting_height) / max(tiptoe_time, 0.001)

func _set_invert_y(enabled):
  _invert_y = enabled

func _set_mouse_sensitivity(factor):
  _mouse_sensitivity_factor = factor

func _set_joy_deadzone(value):
  joy_deadzone = value

func pause():
  _enabled = false

func start():
  _enabled = true

func get_input_dir():
  var input_dir = Vector3()
  if Input.is_action_pressed("move_forward"):
    input_dir -= global_transform.basis.z
  if Input.is_action_pressed("move_back"):
    input_dir += global_transform.basis.z
  if Input.is_action_pressed("strafe_left"):
    input_dir -= global_transform.basis.x
  if Input.is_action_pressed("strafe_right"):
    input_dir += global_transform.basis.x
  return input_dir.normalized()

var camera_v = Vector2.ZERO
func _unhandled_input(event):
  if not _enabled:
    return

  var is_mouse = event is InputEventMouseMotion
  if is_mouse and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
    var delta_x = -event.relative.x * mouse_sensitivity * _mouse_sensitivity_factor
    var delta_y = -event.relative.y * mouse_sensitivity * _mouse_sensitivity_factor * (-1 if _invert_y else 1)

    if not smooth_movement:
      rotate_y(delta_x)
      $Pivot.rotate_x(delta_y)
      $Pivot.rotation.x = clamp($Pivot.rotation.x, -1.2, 1.2)
    else:
      camera_v += Vector2(
        clamp(delta_y, -dampening, dampening),
        clamp(delta_x, -dampening, dampening)
      )

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta):
  if not _enabled:
    return

  velocity.y += gravity * delta

  # Movement speed should depend on inputs, not current height.
  # If crouch is held, always move at crouch speed. Otherwise, allow dash.
  var crouching: bool = Input.is_action_pressed("crouch")
  if Input.is_action_pressed("dash") and not crouching:
    max_speed = max_speed_dash
  else:
    max_speed = max_speed_walk

  var speed = crouch_move_speed if crouching else max_speed
  var input = Input.get_vector("strafe_left", "strafe_right", "move_forward", "move_back")
  var desired_velocity = transform.basis * Vector3(input.x, 0, input.y) * speed

  velocity.x = desired_velocity.x
  velocity.z = desired_velocity.z
  set_up_direction(Vector3.UP)
  set_floor_stop_on_slope_enabled(true)
  move_and_slide()

  #var delta_vec = Input.get_vector("camera_left", "camera_right", "camera_up", "camera_down")
  var delta_vec = Vector2(-Input.get_joy_axis(0, _joy_right_x), -Input.get_joy_axis(0, _joy_right_y))
  if delta_vec.length() > joy_deadzone:
    rotate_y(delta_vec.x * joy_sensitivity)
    $Pivot.rotate_x(delta_vec.y * joy_sensitivity)
    $Pivot.rotation.x = clamp($Pivot.rotation.x, -1.2, 1.2)

  if smooth_movement:
    rotate_y(camera_v.y)
    $Pivot.rotate_x(camera_v.x)
    $Pivot.rotation.x = clamp($Pivot.rotation.x, -1.2, 1.2)
    camera_v *= 0.95

  $FootstepPlayer.set_on_floor(is_on_floor())

  if Input.is_action_pressed("jump") and is_on_floor():
    velocity.y = jump_impulse
    pass

  # Height adjustment logic (crouch on CTRL, tiptoe on ALT)
  # Priority: crouch overrides tiptoe if both are held.
  # Use local position and move_toward to avoid oscillation/jitter.
  var pivot_pos: Vector3 = $Pivot.position
  var target_y: float = starting_height
  if Input.is_action_pressed("crouch"):
    target_y = crouching_height
  elif Input.is_action_pressed("tiptoe"):
    target_y = tiptoe_height

  var current_y: float = pivot_pos.y
  var epsilon := 0.001
  if abs(current_y - target_y) > epsilon:
    var dir_up := target_y > current_y
    var height_speed: float = tiptoe_speed if dir_up else crouch_speed
    pivot_pos.y = move_toward(current_y, target_y, height_speed * delta)
    $Pivot.position = pivot_pos

  if Input.is_action_pressed("interact"):
    var collider = $Pivot/Camera3D/RayCast3D.get_collider()
    if collider and collider.has_method("interact"):
      collider.interact()
