extends Node3D

## PaintingWorldLoader
##
## This helper node reads a GeoJSON file describing a "painting world"
## (areas + walls in a local 2D coordinate system) and instantiates
## simple meshes + collision shapes in 3D.
##
## Supported schema (v1 JSON-FG inspired only):
##   properties.featureType in { "ImagePlan", "Region", "Wall" }
##   - ImagePlan carries image metadata { asset.href?, image.widthPx/heightPx?, metersPerPixel? }
##   - Region uses Polygon geometry; Wall uses LineString geometry; both can reference imagePlan by id
##
## Coordinates are expected to be in a painting-local 2D space and are
## mapped into world XZ.
##
## By default this script assumes coordinacontinue_pressedtes are in *image pixel
## units* (0..image_width_px, 0..image_height_px). It will attempt to:
##   - Read the image path and an optional meters_per_pixel or
##     pixels_per_meter value from the GeoJSON top-level properties.
##   - Load the image to discover its pixel size.
##   - Derive world_width/world_height from (pixels * meters_per_pixel)
##
## If the image information is missing, the loader falls back to
## interpreting coordinates as normalized 0..1 and uses the exported
## world_width/world_height values.
##
## This script is meant as a starting point that you can attach to a
## Node3D inside an existing zone scene.

@export var painting_definition : PaintingDefinition

@export_file("*.geojson") var geojson_path : String

## Width/height of the painting in world units (meters).
## These values are only used in the fallback/debug path when
## `use_image_size` is false *or* when you deliberately provide
## normalized 0..1 coordinates instead of pixel coordinates.
@export var world_width : float = 5.0
@export var world_height : float = 5.0

## Y level of the base painting plane (usually the floor)
@export var base_height : float = 0.0

## Default conversion from pixels to meters when not specified in
## GeoJSON (e.g. 1000 px per meter => 0.001 m/px)
@export var default_meters_per_pixel : float = 0.05

## If true, and if the GeoJSON provides an image path that can be
## loaded, the script will compute world_width/world_height from the
## image pixel size and the pixels->meters ratio.
@export var use_image_size : bool = true

## If true, loader will print verbose information while building
@export var debug_logging : bool = true

## If true, the loader will automatically build the world in _ready()
## using the current painting_definition / geojson_path configuration.
## Set this to false if you want to control when the world is built
## from code (for example from a scene controller that reacts to
## staging user_data when "warping" into a painting).
@export var auto_build_on_ready : bool = true

## Optional material overrides per logical material_type in the GeoJSON
## For example: { "paper": some_material, "wood": another_material }
@export var material_map : Dictionary = {}

## Parent nodes for spawned geometry; if null they default to self
@export var areas_parent_path : NodePath
@export var walls_parent_path : NodePath

var _areas_parent : Node3D
var _walls_parent : Node3D

var _meters_per_pixel : float
var _image_width_px : int = 0
var _image_height_px : int = 0

## v1 ImagePlan registry built from the FeatureCollection on load.
## Keys are plan ids (Feature.id or properties.id if present).
## Values are Dictionary with keys:
##   width_px:int, height_px:int, meters_per_pixel:float, href:String, axis:String
var _image_plans : Dictionary = {}
var _default_plan_id : Variant = null
var _painting_texture : Texture2D = null


func _ready() -> void:
    # Resolve parents for spawned geometry
    _areas_parent = _resolve_parent(areas_parent_path)
    _walls_parent = _resolve_parent(walls_parent_path)

    # Default ratio before reading GeoJSON or applying a definition
    _meters_per_pixel = default_meters_per_pixel

    # If a PaintingDefinition resource is provided, apply it first so
    # it can override geojson_path, scale, materials, and world size.
    if painting_definition:
        _apply_painting_definition(painting_definition)

    if auto_build_on_ready:
        _build_world()


## Public method to (re)build the world based on the current
## painting_definition / geojson_path configuration.
##
## This can be called from other scripts (for example a scene
## controller that receives a PaintingDefinition via staging
## user_data when warping into a painting scene).
func _build_world() -> void:
    if geojson_path == "":
        if debug_logging:
            push_warning("PaintingWorldLoader: geojson_path is empty, nothing to load")
        return

    # Clear any previously generated geometry so we can rebuild
    _clear_generated_geometry()

    var features_data := _load_geojson(geojson_path)
    if features_data.is_empty():
        if debug_logging:
            push_warning("PaintingWorldLoader: no features loaded from %s" % geojson_path)
        return

    _build_from_features(features_data)


## Helper to clear previously generated geometry under the configured
## areas and walls parents.
func _clear_generated_geometry() -> void:
    if _areas_parent:
        for child in _areas_parent.get_children():
            # Avoid deleting ourselves if parent happens to be this node
            if child != self:
                child.queue_free()

    if _walls_parent:
        for child in _walls_parent.get_children():
            if child != self:
                child.queue_free()


## Apply configuration from a PaintingDefinition resource.
##
## This allows multiple (image, GeoJSON) pairs to be defined as
## assets and chosen at edit-time or run-time. The definition can
## override the GeoJSON path, meters_per_pixel, world size behaviour,
## and default material map.
func _apply_painting_definition(def: PaintingDefinition) -> void:
    # GeoJSON path from definition, if provided
    if def.geojson_path != "":
        geojson_path = def.geojson_path

    # Scaling override, if specified (> 0 takes precedence)
    if def.meters_per_pixel_override > 0.0:
        _meters_per_pixel = def.meters_per_pixel_override
        default_meters_per_pixel = def.meters_per_pixel_override

    # Whether to derive world size from image dimensions
    use_image_size = def.use_image_size

    # When not using image size, honour explicit world size from def
    if not def.use_image_size:
        world_width = def.world_width
        world_height = def.world_height

    # Copy material map from definition, if any
    if def.material_map.size() > 0:
        material_map = def.material_map.duplicate(true)

    # Keep a reference to the image texture to texture areas later
    if def.image and (def.image is Texture2D):
        _painting_texture = def.image

    # If we already have an image on the definition and a scale value,
    # we can pre-compute world size here. _load_geojson() may still
    # override this later if the GeoJSON provides its own scale.
    if def.image and use_image_size and _meters_per_pixel > 0.0:
        _image_width_px = def.image.get_width()
        _image_height_px = def.image.get_height()
        if _image_width_px > 0 and _image_height_px > 0:
            world_width = float(_image_width_px) * _meters_per_pixel
            world_height = float(_image_height_px) * _meters_per_pixel

    if debug_logging:
        print("PaintingWorldLoader: applied PaintingDefinition for", def.geojson_path)


func _resolve_parent(path: NodePath) -> Node3D:
    if path == NodePath(""):
        return self
    var n := get_node_or_null(path)
    if n == null:
        push_warning("PaintingWorldLoader: parent path '%s' not found, using self" % path)
        return self
    if not (n is Node3D):
        push_warning("PaintingWorldLoader: parent path '%s' is not a Node3D, using self" % path)
        return self
    return n


## Loads and parses a GeoJSON FeatureCollection.
## Returns an array of per-feature dictionaries with keys:
##   type, geometry, properties
func _load_geojson(path: String) -> Array:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        push_error("PaintingWorldLoader: failed to open GeoJSON '%s'" % path)
        return []

    var text := file.get_as_text()
    file.close()

    var parse = JSON.parse_string(text)
    if typeof(parse) != TYPE_DICTIONARY:
        push_error("PaintingWorldLoader: GeoJSON root is not a dictionary in '%s'" % path)
        return []

    var root : Dictionary = parse
    if root.get("type", "") != "FeatureCollection":
        push_error("PaintingWorldLoader: GeoJSON root type is not FeatureCollection in '%s'" % path)
        return []

    # v1 schema: image size/scale is described by ImagePlan features.
    # Reset legacy caches; per-feature plan will provide sizing as needed.
    _image_width_px = 0
    _image_height_px = 0

    var features = root.get("features", [])
    if typeof(features) != TYPE_ARRAY:
        push_error("PaintingWorldLoader: GeoJSON 'features' is not an array in '%s'" % path)
        return []

    return features


func _build_from_features(features: Array) -> void:
    _collect_image_plans(features)
    for feature in features:
        if typeof(feature) != TYPE_DICTIONARY:
            continue

        # Guard against nulls coming from GeoJSON (e.g., ImagePlan has geometry = null)
        var props_any = feature.get("properties")
        var properties: Dictionary = props_any if typeof(props_any) == TYPE_DICTIONARY else {}
        var geom_any = feature.get("geometry")
        var geometry: Dictionary = geom_any if typeof(geom_any) == TYPE_DICTIONARY else {}
        var feature_type := str(properties.get("featureType", ""))
        var geom_type := str(geometry.get("type", ""))

        if feature_type == "Region" and geom_type == "Polygon":
            _build_area(feature)
        elif feature_type == "Wall" and geom_type == "LineString":
            _build_wall(feature)
        elif feature_type == "ImagePlan":
            # Already registered; nothing to instantiate
            pass
        else:
            if debug_logging:
                push_warning("PaintingWorldLoader: skipping unsupported featureType='%s', geometry.type='%s'" % [feature_type, geom_type])


## Build a flat mesh + collider for an area polygon

func _build_area(feature: Dictionary) -> void:
    var geometry_any = feature.get("geometry")
    var geometry: Dictionary = geometry_any if typeof(geometry_any) == TYPE_DICTIONARY else {}
    var props_any = feature.get("properties")
    var properties: Dictionary = props_any if typeof(props_any) == TYPE_DICTIONARY else {}
    var coords_raw = geometry.get("coordinates", [])

    if typeof(coords_raw) != TYPE_ARRAY or coords_raw.is_empty():
        if debug_logging:
            push_warning("PaintingWorldLoader: area feature missing coordinates")
        return

    # GeoJSON polygon: coordinates is an array of linear rings; take the first ring as outer boundary
    var ring = coords_raw[0]
    if typeof(ring) != TYPE_ARRAY or len(ring) < 3:
        if debug_logging:
            push_warning("PaintingWorldLoader: area feature has invalid ring")
        return

    # Resolve ImagePlan context (v1)
    var plan := _resolve_plan_for_feature(properties)
    var vertices : PackedVector3Array = PackedVector3Array()
    for p in ring:
        if typeof(p) == TYPE_ARRAY and len(p) >= 2:
            var u = float(p[0])
            var v = float(p[1])
            var world_pos := _painting_to_world(u, v, plan)
            vertices.append(world_pos)

    if len(vertices) < 3:
        return

    # Height from v1 surface.baseHeight (optional)
    var height_offset := 0.0
    var surface: Dictionary = properties.get("surface", {})
    if typeof(surface) == TYPE_DICTIONARY:
        height_offset = float(surface.get("baseHeight", 0.0))
    for i in range(len(vertices)):
        var vtx := vertices[i]
        vtx.y = base_height + height_offset
        vertices[i] = vtx

    # Triangulate polygon in 2D (u,v) space using Godot's Geometry2D
    var uvs : PackedVector2Array = PackedVector2Array()
    var width_px := 0
    var height_px := 0
    if typeof(plan) == TYPE_DICTIONARY and plan.size() > 0:
        width_px = int(plan.get("width_px", 0))
        height_px = int(plan.get("height_px", 0))
    for p in ring:
        if typeof(p) == TYPE_ARRAY and len(p) >= 2:
            var pu = float(p[0])
            var pv = float(p[1])
            if width_px > 0 and height_px > 0:
                # Pixel coordinates: convert to 0..1 UV space based on image size
                uvs.append(Vector2(
                    pu / float(width_px),
                    pv / float(height_px)
                ))
            else:
                # Fallback: assume coordinates already in 0..1
                uvs.append(Vector2(pu, pv))

    var indices : PackedInt32Array = Geometry2D.triangulate_polygon(uvs)
    if indices.is_empty():
        if debug_logging:
            push_warning("PaintingWorldLoader: failed to triangulate area polygon")
        return

    # Build mesh
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)

    for i in range(indices.size()):
        var vi : int = indices[i]
        if vi < 0 or vi >= len(vertices):
            continue
        st.set_uv(uvs[vi])
        st.add_vertex(vertices[vi])

    # Ensure normals exist for proper lighting
    st.generate_normals()

    var mesh := st.commit()
    if mesh == null:
        return

    var mesh_instance := MeshInstance3D.new()
    mesh_instance.mesh = mesh

    # Simple material selection (v1) — prefer explicit map; otherwise use painting texture if available
    var applied_material := false
    var _mat_name := ""
    var mat_dict: Dictionary = properties.get("material", {})
    if typeof(mat_dict) == TYPE_DICTIONARY:
        _mat_name = str(mat_dict.get("name", ""))
    if _mat_name != "" and material_map.has(_mat_name):
        var mat = material_map[_mat_name]
        if mat is Material:
            mesh_instance.set_surface_override_material(0, mat)
            applied_material = true

    if not applied_material and _painting_texture:
        var std := StandardMaterial3D.new()
        std.albedo_texture = _painting_texture
        std.roughness = 1.0
        std.metallic = 0.0
        std.cull_mode = BaseMaterial3D.CULL_DISABLED
        mesh_instance.set_surface_override_material(0, std)

    _areas_parent.add_child(mesh_instance)

    # Collision: build a trimesh shape from the committed mesh for robust static collisions
    var shape := mesh.create_trimesh_shape()
    var collider := StaticBody3D.new()
    var col_shape := CollisionShape3D.new()
    col_shape.shape = shape
    collider.add_child(col_shape)
    _areas_parent.add_child(collider)

    # Optional region sound override: if properties.sound is provided, create an Area3D
    # to detect player entry and trigger ambience override for this painting region.
    var region_sound := ""
    if typeof(properties) == TYPE_DICTIONARY:
        if properties.has("sound"):
            region_sound = str(properties.get("sound", "")).strip_edges()
    if region_sound != "":
        var area := Area3D.new()
        var area_shape := CollisionShape3D.new()
        # Duplicate the mesh collider shape for the area trigger
        area_shape.shape = shape
        area.add_child(area_shape)
        # Make the area slightly above the surface to ensure overlap
        area.transform = collider.transform
        _areas_parent.add_child(area)
        # Connect body_entered to trigger override when the player enters
        area.body_entered.connect(_on_region_area_entered.bind(region_sound))

    if debug_logging:
        print("PaintingWorldLoader: built area with", vertices.size(), "vertices")


func _on_region_area_entered(body: Node, sound_rel: String) -> void:
    # Only react to player entering the region
    if not body or not body.is_in_group("Player"):
        return
    var ac = _find_ambience_controller()
    if ac and ac.has_method("play_override_from_content_path"):
        if OS.is_debug_build():
            print("PaintingWorldLoader: region entered, playing sound=", sound_rel)
        ac.call("play_override_from_content_path", sound_rel, true, 0.5)

func _find_ambience_controller() -> Node:
    # Try to find AmbienceController instance in the current scene
    var root = get_tree().current_scene
    if root:
        var n = root.get_node_or_null("AmbienceController")
        if n:
            return n
    # Fallback: deep search
    return get_tree().root.find_child("AmbienceController", true, false)


## Build a continuous wall mesh along a LineString by sweeping a
## rectangle (thickness x height) along the polyline.

# Helper: add a quad (two triangles) to a SurfaceTool with UVs
func _st_add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2, uv_d: Vector2, flip: bool=false) -> void:
    if not flip:
        st.set_uv(uv_a); st.add_vertex(a)
        st.set_uv(uv_b); st.add_vertex(b)
        st.set_uv(uv_c); st.add_vertex(c)
        st.set_uv(uv_a); st.add_vertex(a)
        st.set_uv(uv_c); st.add_vertex(c)
        st.set_uv(uv_d); st.add_vertex(d)
    else:
        st.set_uv(uv_a); st.add_vertex(a)
        st.set_uv(uv_c); st.add_vertex(c)
        st.set_uv(uv_b); st.add_vertex(b)
        st.set_uv(uv_a); st.add_vertex(a)
        st.set_uv(uv_d); st.add_vertex(d)
        st.set_uv(uv_c); st.add_vertex(c)

func _build_wall(feature: Dictionary) -> void:
    var geometry_any = feature.get("geometry")
    var geometry: Dictionary = geometry_any if typeof(geometry_any) == TYPE_DICTIONARY else {}
    var props_any = feature.get("properties")
    var properties: Dictionary = props_any if typeof(props_any) == TYPE_DICTIONARY else {}
    var coords = geometry.get("coordinates", [])
    if typeof(coords) != TYPE_ARRAY or len(coords) < 2:
        if debug_logging:
            push_warning("PaintingWorldLoader: wall feature missing coordinates")
        return

    # v1 wall model
    var height: float = 1.0
    var thickness: float = 1.0
    var wall_model: Dictionary = properties.get("wall", {})
    if typeof(wall_model) == TYPE_DICTIONARY:
        height = float(wall_model.get("height", height))
        thickness = float(wall_model.get("thickness", thickness))

    if thickness <= 0.0 or height <= 0.0:
        return

    # Vertical offset should match the same logic used for areas.
    var height_offset: float = 0.0
    var surface_dict: Dictionary = properties.get("surface", {})
    if typeof(surface_dict) == TYPE_DICTIONARY:
        height_offset += float(surface_dict.get("baseHeight", 0.0))
    if typeof(wall_model) == TYPE_DICTIONARY:
        height_offset += float(wall_model.get("baseHeight", 0.0))

    var plan := _resolve_plan_for_feature(properties)

    # Convert polyline (u,v) into world-space points (XZ) at base height
    var path: PackedVector3Array = PackedVector3Array()
    for p in coords:
        if typeof(p) == TYPE_ARRAY and len(p) >= 2:
            var u = float(p[0])
            var v = float(p[1])
            var wpos := _painting_to_world(u, v, plan)
            wpos.y = base_height + height_offset
            path.append(wpos)

    if path.size() < 2:
        return

    # Precompute cumulative length for UVs and tangents for normals
    var cum_len: PackedFloat32Array = PackedFloat32Array()
    cum_len.resize(path.size())
    cum_len[0] = 0.0
    var total_len: float = 0.0
    for i in range(1, path.size()):
        var seg = path[i] - path[i - 1]
        seg.y = 0.0
        var seg_len = seg.length()
        total_len += seg_len
        cum_len[i] = total_len

    # Compute per-point horizontal normals (XZ) using averaged tangents
    var normals: Array = [] # Array<Vector3>
    normals.resize(path.size())
    for i in range(path.size()):
        var tangent := Vector3.ZERO
        if i == 0:
            tangent = (path[1] - path[0])
        elif i == path.size() - 1:
            tangent = (path[i] - path[i - 1])
        else:
            tangent = (path[i + 1] - path[i - 1]) * 0.5
        tangent.y = 0.0
        var tlen = tangent.length()
        if tlen > 0.0:
            tangent /= tlen
        else:
            tangent = Vector3(1, 0, 0)
        # Left normal (rotate +90 degrees around Y): (-z, 0, x)
        var n := Vector3(-tangent.z, 0.0, tangent.x).normalized()
        normals[i] = n

    var half_t: float = thickness * 0.5

    # Build mesh via SurfaceTool: triangles only (no indices) so we can use vertices for collision faces
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)

    # Side panels (left and right)
    for i in range(path.size() - 1):
        var s0: float = (cum_len[i] / max(total_len, 0.0001))
        var s1: float = (cum_len[i + 1] / max(total_len, 0.0001))

        var n0: Vector3 = normals[i]
        var n1: Vector3 = normals[i + 1]

        var bl0 := path[i] + n0 * half_t
        var br0 := path[i] - n0 * half_t
        var bl1 := path[i + 1] + n1 * half_t
        var br1 := path[i + 1] - n1 * half_t

        var tl0 := bl0 + Vector3.UP * height
        var tr0 := br0 + Vector3.UP * height
        var tl1 := bl1 + Vector3.UP * height
        var tr1 := br1 + Vector3.UP * height

        # Left side (outward normal approx +n)
        _st_add_quad(st, bl0, bl1, tl1, tl0, Vector2(s0, 0.0), Vector2(s1, 0.0), Vector2(s1, 1.0), Vector2(s0, 1.0), false)
        # Right side (outward normal approx -n)
        _st_add_quad(st, br0, tr0, tr1, br1, Vector2(s0, 0.0), Vector2(s0, 1.0), Vector2(s1, 1.0), Vector2(s1, 0.0), false)

        # Top cap between left and right (front faces up when viewed from above)
        _st_add_quad(st, tl0, tl1, tr1, tr0, Vector2(s0, 0.0), Vector2(s1, 0.0), Vector2(s1, 1.0), Vector2(s0, 1.0), false)
        # Duplicate the top cap with reversed winding so the top is double-sided for rendering
        # and provides upward-facing triangles for collision even if normals flip.
        _st_add_quad(st, tl0, tl1, tr1, tr0, Vector2(s0, 0.0), Vector2(s1, 0.0), Vector2(s1, 1.0), Vector2(s0, 1.0), true)
        # Bottom cap (optional underside)
        _st_add_quad(st, br0, br1, bl1, bl0, Vector2(s0, 0.0), Vector2(s1, 0.0), Vector2(s1, 1.0), Vector2(s0, 1.0), false)

        # End caps will be added at loop boundaries below

        # For the very first segment, add start cap
        if i == 0:
            var s_bl0 := bl0
            var s_br0 := br0
            var s_tl0 := tl0
            var s_tr0 := tr0
            # Cap facing backward along -tangent; choose winding so normal points outward
            _st_add_quad(st, s_bl0, s_tl0, s_tr0, s_br0, Vector2(0,0), Vector2(0,1), Vector2(1,1), Vector2(1,0), false)
        # For the last segment, add end cap
        if i == path.size() - 2:
            var e_bl1 := bl1
            var e_br1 := br1
            var e_tl1 := tl1
            var e_tr1 := tr1
            _st_add_quad(st, e_br1, e_tr1, e_tl1, e_bl1, Vector2(0,0), Vector2(0,1), Vector2(1,1), Vector2(1,0), false)

    # Finalize mesh
    st.generate_normals()
    var mesh := st.commit()
    if mesh == null:
        return

    var mesh_instance := MeshInstance3D.new()
    mesh_instance.mesh = mesh

    # Apply material override if provided by properties -> material_map
    var _mat_name := ""
    var mat_dict: Dictionary = properties.get("material", {})
    if typeof(mat_dict) == TYPE_DICTIONARY:
        _mat_name = str(mat_dict.get("name", ""))
    if _mat_name != "" and material_map.has(_mat_name):
        var mat = material_map[_mat_name]
        if mat is Material:
            mesh_instance.set_surface_override_material(0, mat)
    else:
        # Fallback material: neutral, double-sided to ensure the top is visible
        var std := StandardMaterial3D.new()
        std.roughness = 1.0
        std.metallic = 0.0
        std.cull_mode = BaseMaterial3D.CULL_DISABLED
        mesh_instance.set_surface_override_material(0, std)

    _walls_parent.add_child(mesh_instance)

    # Collision: concave trimesh shape built from the entire mesh
    var collider := StaticBody3D.new()
    var shape := mesh.create_trimesh_shape()
    var col_shape := CollisionShape3D.new()
    col_shape.shape = shape
    collider.add_child(col_shape)
    _walls_parent.add_child(collider)

    if debug_logging:
        print("PaintingWorldLoader: built polyline wall with points=", path.size(), " length=", total_len, " h=", height, " t=", thickness)


## Map painting-local coordinates (u,v) to world XZ plane.
##
## If the image size is known (we successfully loaded it from the
## GeoJSON properties), u/v are interpreted as pixel coordinates in
## that image, with (0,0) at the top-left of the painting. In that
## case we convert pixels to meters using _meters_per_pixel and center
## the painting around (0, base_height, 0).
##
## If the image size is not known, we fall back to interpreting u/v as
## normalized 0..1 values and use world_width/world_height directly.

func _painting_to_world(u: float, v: float, plan: Dictionary = {}) -> Vector3:
    var width_px := 0
    var height_px := 0
    var mpp := default_meters_per_pixel
    if typeof(plan) == TYPE_DICTIONARY and plan.size() > 0:
        width_px = int(plan.get("width_px", 0))
        height_px = int(plan.get("height_px", 0))
        var mpp_override := float(plan.get("meters_per_pixel", 0.0))
        if mpp_override > 0.0:
            mpp = mpp_override
    if width_px > 0 and height_px > 0:
        # Pixel-based coordinates
        var cx := float(width_px) * 0.5
        var cz := float(height_px) * 0.5
        var x := (u - cx) * mpp
        var z := (v - cz) * mpp
        return Vector3(x, base_height, z)
    else:
        # Fallback: normalized coordinates 0..1 using explicit
        # world_width/world_height. This path is only reachable when
        # use_image_size is false or when the caller intentionally
        # provides normalized data (e.g. for debug/test scenes).
        var x_f := (u - 0.5) * world_width
        var z_f := (v - 0.5) * world_height
        return Vector3(x_f, base_height, z_f)


## Build registry of ImagePlan features (v1 schema)
func _collect_image_plans(features: Array) -> void:
    _image_plans.clear()
    _default_plan_id = null
    for f in features:
        if typeof(f) != TYPE_DICTIONARY:
            continue
        var props : Dictionary = f.get("properties", {})
        var ft := str(props.get("featureType", ""))
        if ft != "ImagePlan":
            continue
        var plan_id = f.get("id", props.get("id", null))
        if plan_id == null:
            # Internal id (only usable as default when there's a single plan)
            plan_id = "__implicit_plan__"
        var meters_per_pixel := default_meters_per_pixel
        if props.has("metersPerPixel"):
            meters_per_pixel = float(props.get("metersPerPixel"))

        var width_px := 0
        var height_px := 0
        var image_obj = props.get("image", {})
        if typeof(image_obj) == TYPE_DICTIONARY:
            width_px = int(image_obj.get("widthPx", 0))
            height_px = int(image_obj.get("heightPx", 0))

        var href := ""
        var asset = props.get("asset", {})
        if typeof(asset) == TYPE_DICTIONARY:
            href = str(asset.get("href", ""))
        # Resolve relative asset paths against the GeoJSON directory
        if href != "" and not (href.begins_with("res://") or href.begins_with("user://") or href.begins_with("http://") or href.begins_with("https://")):
            if geojson_path != "":
                var base_dir := geojson_path.get_base_dir()
                href = base_dir + "/" + href
        if (width_px <= 0 or height_px <= 0) and href != "":
            var tex = load(href)
            if tex is Texture2D:
                width_px = tex.get_width()
                height_px = tex.get_height()
                # Store as default painting texture if not provided via definition
                if _painting_texture == null:
                    _painting_texture = tex

        var axis := str(props.get("axisConvention", "IMAGE_PX_UV"))
        _image_plans[plan_id] = {
            "width_px": width_px,
            "height_px": height_px,
            "meters_per_pixel": meters_per_pixel,
            "href": href,
            "axis": axis,
        }

    # Choose a default plan and set world size if appropriate
    if _image_plans.size() == 1:
        _default_plan_id = _image_plans.keys()[0]
        if use_image_size:
            var d: Dictionary = _image_plans[_default_plan_id]
            var wpx := int(d.get("width_px", 0))
            var hpx := int(d.get("height_px", 0))
            var mpp := float(d.get("meters_per_pixel", default_meters_per_pixel))
            if wpx > 0 and hpx > 0 and mpp > 0.0:
                world_width = float(wpx) * mpp
                world_height = float(hpx) * mpp


## Resolve ImagePlan context for a Region/Wall feature (v1). If none
## can be resolved and legacy globals are also empty, returns {}.
func _resolve_plan_for_feature(props: Dictionary) -> Dictionary:
    var plan_id = props.get("imagePlan", null)
    if plan_id != null and _image_plans.has(plan_id):
        return _image_plans[plan_id]
    if _default_plan_id != null and _image_plans.has(_default_plan_id):
        return _image_plans[_default_plan_id]
    # As a last resort, return empty -> normalized 0..1 path will be used
    if debug_logging:
        push_warning("PaintingWorldLoader: no ImagePlan resolved for feature; using normalized coordinates fallback")
    return {}
