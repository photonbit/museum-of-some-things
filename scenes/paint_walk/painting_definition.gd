extends Resource
class_name PaintingDefinition

## PaintingDefinition
##
## Lightweight resource that groups together all configuration
## needed to build a "painting world" using PaintingWorldLoader:
##   - The painting image (Texture2D)
##   - The GeoJSON path describing areas + walls
##   - The pixel→meter scale (optional override)
##   - Optional default material map
##   - Optional explicit world size when not using image size
##
## This allows multiple (image, GeoJSON) pairs to be defined as
## assets and selected at runtime, so the same loader node can
## "warp" into different paintings.

@export_group("Painting Assets")

## The texture of the painting (floor image).
@export var image : Texture2D

## The GeoJSON file that describes areas + walls for this painting.
@export_file("*.geojson") var geojson_path : String


@export_group("Scale & Mapping")

## Optional override for the conversion from pixels to meters.
##
## If > 0, this value takes precedence over any meters_per_pixel or
## pixels_per_meter values found in the GeoJSON top-level properties.
## If == 0, PaintingWorldLoader will fall back to the GeoJSON values
## (or its own default_meters_per_pixel export).
@export var meters_per_pixel_override : float = 0.0

## If true, PaintingWorldLoader will derive world_width/world_height
## from the image dimensions and the chosen meters_per_pixel value.
@export var use_image_size : bool = true

## Explicit world size used when use_image_size is false. This is
## mostly intended for debug / normalized-coordinate workflows.
@export var world_width : float = 5.0
@export var world_height : float = 5.0


@export_group("Materials & Presets")

## Default material map for this painting (material_type -> Material).
##
## Any entries here will typically be copied into the
## PaintingWorldLoader.material_map when this definition is applied.
@export var material_map : Dictionary = {}
