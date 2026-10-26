# PDF module — FROZEN

Status: **frozen and verified** (build 88). This module is the product's main
acquisition hook and must not regress.

Rules for any future work:

1. Do not edit files in this folder unless the owner explicitly asks for a PDF change.
2. Do not move files out of this folder without updating this note.
3. Every change here requires its own build and a manual check of: scanner,
   camera, signature drawing, image extraction, saving to Files, OCR search.
4. Unrelated features belong outside `Modules/PDFModule`.
