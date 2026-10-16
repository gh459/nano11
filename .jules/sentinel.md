## 2026-10-16 - Path Traversal in Embedded Fallback Extractor
**Vulnerability:** The embedded fallback script `ExtractUnattend.ps1` extracted file nodes from unattend XML files without sanitizing target paths for path traversal (`..`).
**Learning:** Security boundary checks implemented in main build-time extraction functions were omitted in embedded runtime helper scripts generated as inline strings.
**Prevention:** Whenever path traversal validation is added to main build scripts, ensure all embedded string templates and fallback helper scripts performing file I/O replicate identical validation checks.
