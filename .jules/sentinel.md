## 2026-10-17 - Partial Directory Prefix Matching Boundary Bypass
**Vulnerability:** Path boundary checks using `[string]::StartsWith($baseDir)` without a trailing separator allow boundary bypass when adjacent directories share prefix names (e.g., `C:\scratch_evil` matching `C:\scratch`).
**Learning:** Checking directory containment using raw string prefixes without `DirectorySeparatorChar` or exact equality check allows path traversal and unauthorized deletion/extraction across adjacent workspaces.
**Prevention:** Always append `[System.IO.Path]::DirectorySeparatorChar` or `\` to base directories before invoking `.StartsWith()` or explicitly handle `$target -ieq $base`.
