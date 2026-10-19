## 2025-05-18 - Path Boundary Validation Traversal Bypass
**Vulnerability:** String-based path boundary validation using `$path.StartsWith($basePath)` allows partial directory name matching bypasses (e.g. `C:\workspace_evil` matching `C:\workspace`).
**Learning:** `StartsWith()` on path strings requires an explicit trailing path separator (`+ '\'`) or exact path comparison (`-eq` or `-ine`) to ensure directory boundaries are strictly enforced.
**Prevention:** Always append a path separator (`[System.IO.Path]::DirectorySeparatorChar` or `\`) to base directories before performing `.StartsWith()` prefix checks.
