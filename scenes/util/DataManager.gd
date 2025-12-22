extends Node

signal loaded_image(url: String, image: Image)

@onready var COMMON_HEADERS = [ "accept: image/png, image/jpeg; charset=utf-8" ]
@onready var _in_flight = {}
@onready var _xr = Util.is_xr()

var TEXTURE_QUEUE = "Textures"
var TEXTURE_FRAME_PACING = 6
var _fs_lock = Mutex.new()
var _texture_load_thread_pool_size = 5
var _texture_load_thread_pool = []

# Safety cap for very large source images. Many phone photos are 8K+ on one
# side and will easily exceed GPU texture limits or cause OOM on XR/mobile.
# Images larger than this will be downscaled preserving aspect ratio.
const MAX_TEXTURE_SIZE := 3072
const DOWNSCALE_INTERPOLATION := Image.INTERPOLATE_LANCZOS

# Called when the node enters the scene tree for the first time.
func _ready():
  WorkQueue.setup_queue(TEXTURE_QUEUE, TEXTURE_FRAME_PACING)

  if not Util.is_web():
    var cache_dir = CacheControl.cache_dir
    var dir = DirAccess.open(cache_dir)
    if not dir:
      DirAccess.make_dir_recursive_absolute(cache_dir)
      if OS.is_debug_build():
        print("cache directory created at '%s'" + cache_dir)

  if Util.is_using_threads():
    for _i in range(_texture_load_thread_pool_size):
      var thread = Thread.new()
      thread.start(_texture_load_thread_loop)
      _texture_load_thread_pool.append(thread)

func _exit_tree():
  WorkQueue.set_quitting()
  for thread in _texture_load_thread_pool:
    thread.wait_to_finish()

func _texture_load_thread_loop():
  while not WorkQueue.get_quitting():
    _texture_load_item()

func _process(delta: float) -> void:
  if not Util.is_using_threads():
    _texture_load_item()

func _texture_load_item():
  var item = WorkQueue.process_queue(TEXTURE_QUEUE)
  if not item:
    return

  match item.type:
    "request":
        # First, try loading as a Godot resource (remapped to .ctex in exports).
        # This allows Web exports to use imported textures without bundling the original files.
        if item.url.begins_with("res://") or item.url.begins_with("user://"):
          var tex = load(item.url)
          if tex is Texture2D:
            _emit_image(item.url, tex, item.ctx)
            return

        var data = _read_url(item.url)

        if data:
          _load_image(item.url, data, item.ctx)
        else:
          # Local file support (no HTTP). Read bytes directly from res:// or user://
          if item.url.begins_with("res://") or item.url.begins_with("user://"):
            var f = FileAccess.open(item.url, FileAccess.READ)
            if f:
              var bytes = f.get_buffer(f.get_length())
              f.close()
              _load_image(item.url, bytes, item.ctx)
              return
            else:
              push_error("failed to open local image ", item.url)

          var request_url = item.url
          request_url += ('&' if '?' in request_url else '?') + "origin=*"

          var handle_result = func(result):
            if result[0] != OK:
              push_error("failed to fetch image ", result[1], " ", item.url)
            else:
              data = result[3]
              _write_url(item.url, data)
              _load_image(item.url, data, item.ctx)

          if Util.is_web():
            RequestSync.request_async(request_url, COMMON_HEADERS).completed.connect(handle_result)
          else:
            handle_result.call(RequestSync.request(request_url, COMMON_HEADERS))

    "load":
      var data = item.data

      var fmt = _detect_image_type(data)
      var image = Image.new()
      var loaded = false
      if fmt == "PNG":
        loaded = image.load_png_from_buffer(data) == OK
      elif fmt == "JPEG":
        loaded = image.load_jpg_from_buffer(data) == OK
      elif fmt == "SVG":
        loaded = image.load_svg_from_buffer(data) == OK
      elif fmt == "WebP":
        loaded = image.load_webp_from_buffer(data) == OK
      else:
        # Fallback by file extension if header detection failed
        var lower_url = str(item.url).to_lower()
        if lower_url.ends_with(".jpg") or lower_url.ends_with(".jpeg"):
          loaded = image.load_jpg_from_buffer(data) == OK
          fmt = "JPEG" if loaded else fmt
        elif lower_url.ends_with(".png"):
          loaded = image.load_png_from_buffer(data) == OK
          fmt = "PNG" if loaded else fmt
        elif lower_url.ends_with(".webp"):
          loaded = image.load_webp_from_buffer(data) == OK
          fmt = "WebP" if loaded else fmt
        elif lower_url.ends_with(".svg"):
          loaded = image.load_svg_from_buffer(data) == OK
          fmt = "SVG" if loaded else fmt

      if not loaded:
        push_error("[DataManager] Unknown/unsupported image format: " + str(item.url))
        return

      if image.get_width() == 0 or image.get_height() == 0:
        push_error("[DataManager] Decoded image has zero size: " + str(item.url))
        return

      # Log and downscale oversized images to avoid GPU/memory issues
      var w = image.get_width()
      var h = image.get_height()
      var max_dim = maxi(w, h)
      if OS.is_debug_build():
        print("[DataManager] Loaded ", fmt, " ", w, "x", h, " from ", item.url)
      if max_dim > MAX_TEXTURE_SIZE:
        var scale = float(MAX_TEXTURE_SIZE) / float(max_dim)
        var new_w = int(floor(float(w) * scale))
        var new_h = int(floor(float(h) * scale))
        new_w = max(new_w, 1)
        new_h = max(new_h, 1)
        if OS.is_debug_build():
          print("[DataManager] Downscaling to ", new_w, "x", new_h, " (limit ", MAX_TEXTURE_SIZE, ") for ", item.url)
        image.resize(new_w, new_h, DOWNSCALE_INTERPOLATION)

      _generate_mipmaps(item.url, image, item.ctx)

    "generate_mipmaps":
      var image = item.image
      image.generate_mipmaps()
      _create_and_emit_texture(item.url, image, item.ctx)

    "create_and_emit_texture":
      var texture = ImageTexture.create_from_image(item.image)
      _emit_image(item.url, texture, item.ctx)

func _get_hash(input: String) -> String:
  var context = HashingContext.new()
  context.start(HashingContext.HASH_SHA256)
  context.update(input.to_utf8_buffer())
  var hash_result = context.finish()
  return hash_result.hex_encode()

func _detect_image_type(data: PackedByteArray) -> String:
  if data.size() < 8:
    return "Unknown"  # Insufficient data to determine type

  # Convert to hexadecimal strings for easy comparison
  var header = data.slice(0, 8)
  var hex_header = ""
  for byte in header:
    hex_header += ("%02x" % byte).to_lower()

  # Check PNG signature
  if hex_header.begins_with("89504e470d0a1a0a"):
    return "PNG"

  # Check JPEG signature
  if hex_header.begins_with("ffd8ff"):
    return "JPEG"

  # Check WebP signature (RIFF and WEBP)
  if hex_header.begins_with("52494646"):  # "RIFF"
    if data.size() >= 12:
      var riff_type = data.slice(8, 12).get_string_from_ascii()
      if riff_type == "WEBP":
        return "WebP"

  # Check SVG (look for '<?xml' or '<svg')
  if data.size() >= 5:
    var xml_start = data.slice(0, 5).get_string_from_utf8()
    if xml_start.begins_with("<?xml") or xml_start.begins_with("<svg"):
      return "SVG"
  return "Unknown"

func _write_url(url: String, data: PackedByteArray) -> void:
  if Util.is_web():
    return
  _fs_lock.lock()
  var filename = _get_hash(url)
  var f = FileAccess.open(CacheControl.cache_dir + filename, FileAccess.WRITE)
  if f:
    f.store_buffer(data)
    f.close()
  else:
    push_error("failed to write file ", url)
  _fs_lock.unlock()

func _read_url(url: String):
  if Util.is_web():
    return null
  _fs_lock.lock()
  var filename = _get_hash(url)
  var file_path = CacheControl.cache_dir + filename
  var f = FileAccess.open(file_path, FileAccess.READ)
  if f:
    var data = f.get_buffer(f.get_length())
    f.close()
    _fs_lock.unlock()
    return data
  else:
    _fs_lock.unlock()
    return null

func _url_exists(url: String):
  if Util.is_web():
    return false
  _fs_lock.lock()
  var filename = _get_hash(url)
  var res = FileAccess.file_exists(CacheControl.cache_dir + filename)
  _fs_lock.unlock()
  return res

func load_json_data(url: String):
  var data = _read_url(url)
  if data:
    var json = data.get_string_from_utf8()
    return JSON.parse_string(json)
  else:
    return null

func save_json_data(url: String, json: Dictionary):
  if Util.is_web():
    return
  var data = JSON.stringify(json).to_utf8_buffer()
  _write_url(url, data)

func _emit_image(url, texture, ctx):
  if texture == null:
    return
  call_deferred("emit_signal", "loaded_image", url, texture, ctx)

func request_image(url, ctx=null):
  WorkQueue.add_item(TEXTURE_QUEUE, {
    "type": "request",
    "url": url,
    "ctx": ctx
  })

func _load_image(url, data, ctx=null):
  WorkQueue.add_item(TEXTURE_QUEUE, {
    "type": "load",
    "url": url,
    "data": data,
    "ctx": ctx,
  }, null, true)

func _generate_mipmaps(url, image, ctx=null):
  WorkQueue.add_item(TEXTURE_QUEUE, {
    "type": "generate_mipmaps",
    "url": url,
    "image": image,
    "ctx": ctx,
  }, null, true)

func _create_and_emit_texture(url, image, ctx=null):
  WorkQueue.add_item(TEXTURE_QUEUE, {
    "type": "create_and_emit_texture",
    "url": url,
    "image": image,
    "ctx": ctx,
  }, null, true)
