# HTTP helpers: CORS headers, static file serving
function cors_headers()
    return [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "Content-Type"
    ]
end

# Handle CORS preflight requests
function handle_cors(req)
    if HTTP.method(req) == "OPTIONS"
        return HTTP.Response(200, cors_headers())
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Shared growth curve fitting using the KinBiont.jl new API

# Serve a file under the static/ directory.
# Returns nothing if the path is outside static/ (caller should 404).
const STATIC_DIR = joinpath(@__DIR__, "..", "static")
const MIME_TYPES = Dict(
    ".js"   => "application/javascript",
    ".css"  => "text/css",
    ".html" => "text/html",
    ".svg"  => "image/svg+xml",
    ".png"  => "image/png",
    ".ico"  => "image/x-icon",
)

function serve_static(req)::Union{HTTP.Response,Nothing}
    path = HTTP.URI(req.target).path
    startswith(path, "/static/") || return nothing
    # Strip leading slash so joinpath doesn't treat it as absolute
    rel = path[2:end]   # e.g. "static/js/api.js"
    file_path = normpath(joinpath(@__DIR__, "..", rel))
    # Security: ensure resolved path is inside STATIC_DIR
    startswith(file_path, realpath(STATIC_DIR)) || return HTTP.Response(403, "Forbidden")
    isfile(file_path) || return HTTP.Response(404, "Not found")
    ext  = lowercase(splitext(file_path)[2])
    mime = get(MIME_TYPES, ext, "application/octet-stream")
    return HTTP.Response(200, ["Content-Type" => mime], read(file_path))
end
