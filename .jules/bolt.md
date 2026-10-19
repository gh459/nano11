## 2026-10-19 - PowerShell Array Vector Filtering vs Pipeline Overhead

**Learning:** In PowerShell, pipeline object filtering (`$array | Where-Object { ... }`) incurs significant object-wrapping and pipeline processing overhead when filtering large collections of string patterns (e.g. AppX and DISM package pattern lists). Direct array vector comparison filtering (`$array -notlike $pattern`) evaluates natively in .NET, and comparison operators can be directly chained (`$array -notlike $p1 -notlike $p2`). Enclosing in `@(...)` guarantees array return safety when 0 or 1 item matches, delivering ~4-7x speedup over `Where-Object`.

**Action:** Prefer direct array vector comparison filtering `@($array -notlike $p1 -notlike $p2)` over `$array | Where-Object { ... }` in PowerShell script hot paths for array exclusions.
