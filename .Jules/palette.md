# Palette's Journal - UX & Accessibility Learnings

## 2025-05-18 - WinForms Form Ergonomics and Screen Reader Accessibility in PowerShell
**Learning:** In PowerShell-based WinForms GUI applications, forms often omit `$form.AcceptButton` and `$form.CancelButton` mappings and control `AccessibleName`/`AccessibleDescription` properties, rendering primary dialog actions unreachable via standard keyboard keys (`Enter`/`Esc`) and invisible to screen readers like Windows Narrator.
**Action:** Always bind `$form.AcceptButton = $primaryBtn` and `$form.CancelButton = $cancelBtn` alongside `AccessibleName`, `AccessibleDescription`, and `ToolTip` properties when constructing WinForms dialogs in PowerShell scripts.
