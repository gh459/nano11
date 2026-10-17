## 2025-02-23 - Array Vector Filtering vs Pipeline Filtering in PowerShell

**Learning:** Direct array vector filtering in PowerShell (`$array -notlike $pattern` / `$array -like $pattern`) is ~4.8x–190x faster than pipeline filtering (`$array | Where-Object { $_ -notlike $pattern }`) because it avoids pipeline object wrapping and cmdlet invocation overhead. When array length can drop to 1 or 0, always wrap in `@(...)` (`@($array -notlike $p1 -notlike $p2)`) to ensure array return type safety.
**Action:** Use native array vector filtering `@($array -like $pattern)` or `@($array -notlike $pattern)` for array pattern matching in PowerShell scripts instead of pipeline `Where-Object` blocks.
