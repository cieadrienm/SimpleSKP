import Foundation

public let simpleSKPToolDefinitions: [[String: Any]] = [
    [
        "name": "simpleskp_state",
        "description": "Returns the current state of SimpleSKP: active .skp file path & version, model dimensions in metres, geometry statistics (faces, edges, components, materials), camera pose (position, target, yaw, pitch, distance, FOV, focal length mm, exposure EV, perspective/parallel), scenes, layers, rendering style, lighting mode (sun/point), SSAO, backdrop, and OSC/API ports.",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
        "name": "simpleskp_help",
        "description": "Returns the full HTTP /v1 API, MCP tool reference, OSCQuery & OSC address map for OSCScore, and Bonjour service names.",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
        "name": "simpleskp_open",
        "description": "Opens a SketchUp (.skp) file from disk in SimpleSKP and waits until its 3D scene is ready.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Path to a .skp file on disk"],
            ],
            "required": ["path"],
        ],
    ],
    [
        "name": "simpleskp_camera",
        "description": "Reads or updates the 3D camera in SimpleSKP: eye position (X, Y, Z in metres), target (TX, TY, TZ), orientation (yaw -180..180 deg, pitch -89..89 deg), orbit distance, vertical field of view (fov 10..120 deg), 35mm equivalent focal length (focalLengthMM 5..135 mm), HDR exposure (-3..+3 EV), projection (perspective true/false), standardView ('iso', 'top', 'bottom', 'front', 'back', 'left', 'right'), or action ('reset', 'zoom_extents', 'level', 'eye_height', 'center').",
        "inputSchema": [
            "type": "object",
            "properties": [
                "position": [
                    "type": "array",
                    "items": ["type": "number"],
                    "description": "Camera eye [x, y, z] in metres (Z up)",
                ],
                "x": ["type": "number", "description": "Camera X coordinate in metres"],
                "y": ["type": "number", "description": "Camera Y coordinate in metres"],
                "z": ["type": "number", "description": "Camera Z height in metres"],
                "target": [
                    "type": "array",
                    "items": ["type": "number"],
                    "description": "Point [tx, ty, tz] in metres for the camera to look at",
                ],
                "yaw": ["type": "number", "description": "Camera azimuth/yaw in degrees (-180..180)"],
                "pitch": ["type": "number", "description": "Camera elevation/pitch in degrees (-89..89)"],
                "distance": ["type": "number", "description": "Distance to orbit target in metres"],
                "fov": ["type": "number", "description": "Vertical field of view in degrees (10..120, default 35)"],
                "focalLengthMM": ["type": "number", "description": "35mm full-frame equivalent focal length in mm (e.g. 14, 24, 35, 50, 85)"],
                "exposure": ["type": "number", "description": "Camera HDR exposure offset in EV (-3.0..3.0, default -0.62)"],
                "perspective": ["type": "boolean", "description": "True for perspective projection, false for parallel/orthographic"],
                "orthoScale": ["type": "number", "description": "Half-height in metres when in parallel projection"],
                "speedScale": ["type": "number", "description": "Keyboard/fly movement speed multiplier (0.1..16)"],
                "standardView": [
                    "type": "string",
                    "enum": ["iso", "top", "bottom", "front", "back", "left", "right"],
                    "description": "Frame model from a standard view",
                ],
                "action": [
                    "type": "string",
                    "enum": ["reset", "zoom_extents", "level", "eye_height", "center"],
                    "description": "Quick camera action",
                ],
                "eyeHeight": ["type": "number", "description": "Eye height above floor in metres when action='eye_height' (default 1.70)"],
            ],
        ],
    ],
    [
        "name": "simpleskp_scene",
        "description": "Selects a saved SketchUp scene by 0-based index, by scene name, or steps to 'next' / 'prev'.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "index": ["type": "integer", "description": "0-based scene index"],
                "name": ["type": "string", "description": "Scene name (case-insensitive)"],
                "action": ["type": "string", "enum": ["next", "prev"], "description": "Step to next or previous scene"],
                "slow": ["type": "boolean", "description": "True for a 10x slower camera transition (3.5 s instead of 0.35 s, equivalent to holding Shift)"],
            ],
        ],
    ],
    [
        "name": "simpleskp_layers",
        "description": "Controls SketchUp layer visibility: show/hide all layers ('all': true/false), solo a layer ('solo': index or name), or set/toggle a specific layer ('index' or 'name', optional 'visible': true/false).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "all": ["type": "boolean", "description": "Show all layers (true) or hide all layers (false)"],
                "solo": ["type": "string", "description": "Layer name or index to isolate"],
                "index": ["type": "integer", "description": "0-based layer index"],
                "name": ["type": "string", "description": "Layer name"],
                "visible": ["type": "boolean", "description": "Explicit visibility state"],
            ],
        ],
    ],
    [
        "name": "simpleskp_rendering",
        "description": "Updates 3D rendering, lighting, sun, point light, ambient light, SSAO, or backdrop settings in SimpleSKP.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "style": ["type": "string", "enum": ["textured", "clay", "xray", "wireframe"]],
                "edges": ["type": "boolean", "description": "Show or hide vector edges"],
                "grid": ["type": "boolean", "description": "Show or hide ground grid and XYZ axes"],
                "shadows": ["type": "boolean", "description": "Enable or disable sun cast shadows"],
                "ssao": ["type": "number", "description": "Ambient occlusion strength (0.0..2.0, 0 disables)"],
                "ambientIntensity": ["type": "number", "description": "Ambient light intensity (0.0..2.0, default 1.0; 0 = pitch black when lights are at 0%)"],
                "lightingMode": ["type": "string", "enum": ["sun", "point"]],
                "sunAzimuth": ["type": "number", "description": "Sun azimuth in degrees (-180..180)"],
                "sunElevation": ["type": "number", "description": "Sun elevation in degrees (8..85)"],
                "sunIntensity": ["type": "number", "description": "Sun directional light intensity (0.0..3.0, default 1.0)"],
                "lightPosition": [
                    "type": "array",
                    "items": ["type": "number"],
                    "description": "Active point light position [x, y, z] in metres",
                ],
                "lightIntensity": ["type": "number", "description": "Active point light intensity (0.0..3.0)"],
                "lightGizmo": ["type": "boolean", "description": "Show or hide 3D point light gizmo"],
                "backdropStyle": ["type": "string", "enum": ["architecturalSky", "studioDark", "warmPaper", "customColor"]],
                "backdropColor": [
                    "type": "array",
                    "items": ["type": "number"],
                    "description": "Custom backdrop sRGB color [r, g, b] in 0..1",
                ],
            ],
        ],
    ],
    [
        "name": "simpleskp_snapshot",
        "description": "Captures the current 3D viewport of SimpleSKP as a PNG image (default) or exports a 100% vector PDF when format='pdf'.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "format": ["type": "string", "enum": ["png", "pdf"], "description": "Output format: 'png' (inline image) or 'pdf' (vector PDF)"],
                "path": ["type": "string", "description": "Optional file path where to write the vector PDF when format='pdf'"],
                "width": ["type": "number", "description": "Optional page width in points for PDF export (default 1190 = A3 landscape)"],
                "height": ["type": "number", "description": "Optional page height in points for PDF export (default 842 = A3 landscape)"],
            ],
        ],
    ],
]
